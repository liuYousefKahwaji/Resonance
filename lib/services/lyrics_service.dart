import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:resonance/models/lyrics.dart';
import 'package:resonance/services/lyrics_parser.dart';

class LyricsLookupException implements Exception {
  const LyricsLookupException(this.message, {this.retryAt});
  final String message;
  final DateTime? retryAt;
  @override
  String toString() => message;
}

class LyricsService {
  static const _cacheVersion = 5;
  static const _fallbackCacheDuration = Duration(hours: 12);
  static const _requestTimeout = Duration(seconds: 5);
  static const _lrclibRequestGap = Duration(milliseconds: 300);
  static const _lrclibUserAgent = 'Resonance/4.1.0 (https://github.com/liuYousefKahwaji/Resonance)';
  static final Map<String, LyricsDocument> _memory = {};
  static final Map<String, Future<LyricsDocument?>> _inFlight = {};
  static Future<void> _lrclibQueue = Future.value();
  static DateTime? _lastLrclibRequest;
  static DateTime? _lrclibRetryAt;

  @visibleForTesting
  static void resetLrclibBackoff() => _lrclibRetryAt = null;

  const LyricsService({this.lrclibClientFactory, this.lrclibTimeout = _requestTimeout});
  @visibleForTesting
  final HttpClient Function()? lrclibClientFactory;
  final Duration lrclibTimeout;
  HttpClient _lrclibClient() => lrclibClientFactory?.call() ?? (HttpClient()..connectionTimeout = lrclibTimeout);
  static String searchQueryForTrack(String title, String artist) {
    final metadata = _lookupMetadata(title, artist);
    // Many YouTube uploads put the real artist in "Artist - Song" while
    // reporting an unrelated uploader as artist. Manual search is broad and
    // explicitly selected, so avoid adding that uploader to an already named song.
    if (metadata.title.contains(' - ')) return metadata.title.replaceAll(' - ', ' ').trim();
    return [metadata.artist, metadata.title].where((e) => e.isNotEmpty).join(' ');
  }

  Future<LyricsDocument?> fetch({
    required String trackId,
    required String title,
    required String artist,
    String album = '',
    Duration? duration,
    bool forceRefresh = false,
  }) async {
    final key = _key(trackId, title, artist, album, duration);
    if (forceRefresh) {
      _memory.remove(key);
      await _deleteCache(key);
    } else {
      final cached = _memory[key];
      if (cached != null) return cached;
      final running = _inFlight[key];
      if (running != null) return running;
    }

    final future = _fetchUncached(
      key: key,
      trackId: trackId,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    );
    _inFlight[key] = future;
    try {
      final result = await future;
      if (result != null && (result.timingQuality == LyricTimingQuality.word || result.instrumental)) {
        _memory[key] = result;
      }
      return result;
    } finally {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }
  }

  Future<void> prefetch({
    required String trackId,
    required String title,
    required String artist,
    String album = '',
    Duration? duration,
  }) async {
    await fetch(trackId: trackId, title: title, artist: artist, album: album, duration: duration);
  }

  Future<LyricsDocument?> _fetchUncached({
    required String key,
    required String trackId,
    required String title,
    required String artist,
    required String album,
    required Duration? duration,
  }) async {
    final cached = await _readCache(key, refreshFallback: true);
    if (cached != null) return cached;

    final previousKey = _key(trackId, title, artist, album, duration, version: 4);
    final chosen = await _readCache('chosen_$key') ?? await _readCache('chosen_$previousKey');
    if (chosen != null) return chosen;
    final sidecar = await _readSidecar(trackId);
    if (sidecar != null && !sidecar.isEmpty) return _store(key, sidecar);

    final metadata = _lookupMetadata(title, artist);
    final selectedId =
        await _readManualSelection(key) ??
        await _readManualSelection(previousKey) ??
        await _readManualSelection(_key(trackId, title, artist, album, duration, version: 3));
    if (selectedId != null) {
      final selected = await _fetchLrclibById(selectedId);
      if (selected != null) return _store(key, selected);
    }
    final sources = [
      ..._wordSources(metadata.title, metadata.artist, album, duration),
      _fetchLrclib(title: metadata.title, artist: metadata.artist, album: album.trim(), duration: duration),
    ];
    // A slower provider must not hold up a real word-timed result.
    final wordResult = Completer<LyricsDocument>();
    final allResults = Future.wait(
      sources.map((source) async {
        final document = await source;
        if (document != null &&
            !document.isEmpty &&
            document.timingQuality == LyricTimingQuality.word &&
            !wordResult.isCompleted) {
          wordResult.complete(document);
        }
        return document;
      }),
    );
    final document = await Future.any<LyricsDocument?>([
      wordResult.future,
      allResults.then(
        (results) => results.nonNulls.where((result) => !result.isEmpty || result.instrumental).firstOrNull,
      ),
    ]);
    return document == null ? null : _store(key, document);
  }

  List<Future<LyricsDocument?>> _wordSources(String title, String artist, String album, Duration? duration) => [
    _fetchBetterLyrics(title: title, artist: artist, album: album, duration: duration),
    _fetchAmll(title: title, artist: artist),
    _fetchBetterLyrics(title: title, artist: artist, album: album, duration: duration, qq: true),
  ];

  Future<LyricsDocument?> _readSidecar(String trackId) async {
    if (trackId.startsWith('http://') || trackId.startsWith('https://')) return null;
    final extension = p.extension(trackId);
    final base = extension.isEmpty ? trackId : trackId.substring(0, trackId.length - extension.length);
    for (final candidate in ['$base.ttml', '$base.TTML', '$base.lrc', '$base.LRC', '$base.txt']) {
      final file = File(candidate);
      if (!await file.exists()) continue;
      final text = await file.readAsString();
      final lower = candidate.toLowerCase();
      if (lower.endsWith('.ttml')) return LyricsParser.parseTtml(text, source: 'Local TTML');
      return lower.endsWith('.lrc')
          ? LyricsParser.parseLrc(text, source: 'Local LRC')
          : LyricsParser.parsePlain(text, source: 'Local lyrics');
    }
    return null;
  }

  Future<LyricsDocument?> _fetchBetterLyrics({
    required String title,
    required String artist,
    required String album,
    Duration? duration,
    bool qq = false,
  }) async {
    if (title.isEmpty || artist.isEmpty) return null;
    final query = <String, String>{'s': title, 'a': artist, if (album.trim().isNotEmpty) 'al': album.trim()};
    if (duration != null && duration.inSeconds > 0) query['d'] = '${duration.inSeconds}';
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final response =
          await (await client
                  .getUrl(Uri.https('api.betterlyrics.org', qq ? '/qq/getLyrics' : '/getLyrics', query))
                  .timeout(_requestTimeout))
              .close()
              .timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(_requestTimeout);
        return null;
      }
      final payload =
          jsonDecode(await utf8.decoder.bind(response).join().timeout(_requestTimeout)) as Map<String, dynamic>;
      final score = (payload['score'] as num?)?.toDouble();
      final ttml = payload[qq ? 'lyrics' : 'ttml']?.toString() ?? '';
      if (ttml.isEmpty || (score != null && score < 65)) return null;
      final document = qq
          ? LyricsParser.parseQrc(ttml, source: 'QQ Music', title: title, artist: artist)
          : LyricsParser.parseTtml(ttml, source: 'Better Lyrics');
      return document.timingQuality == LyricTimingQuality.word ? document : null;
    } catch (error) {
      debugPrint('Better Lyrics lookup failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<LyricsDocument?> _fetchAmll({required String title, required String artist}) async {
    if (title.isEmpty) return null;
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client
          .postUrl(Uri.https('amlldb.bikonoo.com', '/api/search-lyrics'))
          .timeout(_requestTimeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.userAgentHeader, 'Resonance/2.7.0');
      request.add(utf8.encode(jsonEncode({'query': title, 'type': 'title'})));
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(_requestTimeout);
        return null;
      }
      final decoded = jsonDecode(await utf8.decoder.bind(response).join().timeout(_requestTimeout));
      if (decoded is! List) return null;
      final candidates = decoded.whereType<Map>().map((item) => Map<String, dynamic>.from(item));
      final candidate = _bestAmllCandidate(candidates, title: title, artist: artist);
      final file = candidate?['file']?.toString();
      if (file == null || !RegExp(r'^[A-Za-z0-9._-]+\.ttml$').hasMatch(file)) return null;
      final rawResponse =
          await (await client
                  .getUrl(Uri.https('amlldb.bikonoo.com', '/raw-lyrics/${Uri.encodeComponent(file)}'))
                  .timeout(_requestTimeout))
              .close()
              .timeout(_requestTimeout);
      if (rawResponse.statusCode != HttpStatus.ok) {
        await rawResponse.drain<void>().timeout(_requestTimeout);
        return null;
      }
      final document = LyricsParser.parseTtml(
        await utf8.decoder.bind(rawResponse).join().timeout(_requestTimeout),
        source: 'AMLL',
      );
      return document.timingQuality == LyricTimingQuality.word ? document : null;
    } catch (error) {
      debugPrint('AMLL lookup failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<LyricsDocument?> _fetchLrclib({
    required String title,
    required String artist,
    required String album,
    Duration? duration,
  }) async {
    if (title.isEmpty) return null;
    final client = _lrclibClient();
    try {
      final exactQuery = <String, String>{'track_name': title};
      if (artist.isNotEmpty) exactQuery['artist_name'] = artist;
      if (album.isNotEmpty) exactQuery['album_name'] = album;
      if (duration != null && duration.inSeconds > 0) exactQuery['duration'] = '${duration.inSeconds}';
      final exact = await _getLrclibJson(client, Uri.https('lrclib.net', '/api/get', exactQuery));
      if (exact is Map) {
        final document = _lrclibDocument(Map<String, dynamic>.from(exact));
        if (document != null) return document;
      }

      // Match the LRCLIB website's broad search without accepting a different
      // recording: preserve server order and take the first result within
      // three seconds of the duration reported by the player.
      final query = [artist, title].where((part) => part.isNotEmpty).join(' ');
      final found = await _getLrclibJson(client, Uri.https('lrclib.net', '/api/search', {'q': query}));
      if (found is List) {
        final rawCandidates = found.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
        final candidate = selectAutomaticLrclibCandidate(rawCandidates.map(LrclibCandidate.fromJson), duration);
        if (candidate != null) {
          final raw = rawCandidates.firstWhere((item) => (item['id'] as num?)?.toInt() == candidate.id);
          return _lrclibDocument(raw);
        }
      }

      // Last-resort lookup: some LRCLIB records have missing or inconsistent
      // artist metadata and therefore never appear for "artist + title".
      // Search only the cleaned song title, then let the audio duration act as
      // the identity check. This deliberately runs after every richer lookup.
      if (artist.isNotEmpty && duration != null && duration.inMilliseconds > 0) {
        final titleOnly = await _getLrclibJson(client, Uri.https('lrclib.net', '/api/search', {'q': title}));
        if (titleOnly is List) {
          final rawCandidates = titleOnly.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
          final candidate = selectTitleOnlyLrclibCandidate(rawCandidates.map(LrclibCandidate.fromJson), duration);
          if (candidate != null) {
            final raw = rawCandidates.firstWhere((item) => (item['id'] as num?)?.toInt() == candidate.id);
            return _lrclibDocument(raw, source: 'LRCLIB · title fallback');
          }
        }
      }
    } catch (error) {
      debugPrint('LRCLIB lookup failed: $error');
    } finally {
      client.close(force: true);
    }
    return null;
  }

  Future<List<LrclibCandidate>> searchLrclibCandidates(String query) async {
    final cleaned = query.trim();
    if (cleaned.isEmpty) return const [];
    final client = _lrclibClient();
    try {
      final params = {'q': cleaned};
      final found = await _getLrclibJson(client, Uri.https('lrclib.net', '/api/search', params));
      if (found is! List) return const [];
      return compute(_parseSearchResults, found);
    } catch (error) {
      debugPrint('LRCLIB candidate search failed: $error');
      if (error is LyricsLookupException) rethrow;
      throw const LyricsLookupException('Could not reach LRCLIB. Check your connection and try again.');
    } finally {
      client.close(force: true);
    }
  }

  static List<LrclibCandidate> _parseSearchResults(List<dynamic> found) {
    final candidates = <LrclibCandidate>[];
    for (final item in found.whereType<Map>()) {
      final raw = Map<String, dynamic>.from(item);
      final document = _lrclibDocument(raw);
      if (document == null) continue;
      final candidate = LrclibCandidate.fromJson(raw, document: document);
      if (candidate.id > 0) candidates.add(candidate);
    }
    return candidates;
  }

  Future<List<LrclibCandidate>> searchCandidates(
    String query, {
    required String title,
    required String artist,
    required String album,
    required Duration? duration,
  }) async {
    final metadata = _lookupMetadata(title, artist);
    final parts = query.split(' - ');
    final lookup = parts.length == 2
        ? (title: parts[1].trim(), artist: parts[0].trim())
        : query == searchQueryForTrack(title, artist)
        ? _manualWordLookup(metadata)
        : null;
    final alternative = lookup == null
        ? Future.value(<LyricsDocument?>[])
        : Future.wait(_wordSources(lookup.title, lookup.artist, album, duration));
    List<LrclibCandidate> candidates = [];
    LyricsLookupException? error;
    try {
      candidates = await searchLrclibCandidates(query);
    } on LyricsLookupException catch (failure) {
      error = failure;
    }
    final rich = (await alternative).nonNulls.where((document) => document.timingQuality == LyricTimingQuality.word);
    final results = [
      ...candidates,
      for (final (index, document) in rich.indexed)
        LrclibCandidate(
          id: -index - 1,
          trackName: lookup!.title,
          artistName: lookup.artist,
          albumName: '',
          duration: Duration.zero,
          instrumental: false,
          hasSyncedLyrics: true,
          hasPlainLyrics: false,
          hasWordSync: true,
          document: document,
        ),
    ];
    if (results.isEmpty && error != null) throw error;
    return results;
  }

  ({String title, String artist}) _manualWordLookup(({String title, String artist}) metadata) {
    final separator = metadata.title.indexOf(' - ');
    if (separator < 0) return metadata;
    return (title: metadata.title.substring(separator + 3), artist: metadata.title.substring(0, separator));
  }

  Future<LyricsDocument?> selectLrclibCandidate({
    required String trackId,
    required String title,
    required String artist,
    String album = '',
    required Duration? duration,
    required LrclibCandidate candidate,
  }) async {
    final document = candidate.document ?? await _fetchLrclibById(candidate.id);
    if (document == null) return null;
    final key = _key(trackId, title, artist, album, duration);
    if (candidate.id <= 0) {
      await _store('chosen_$key', document);
    } else {
      await _writeManualSelection(key, candidate.id);
      await _deleteCache('chosen_$key');
      final previousKey = _key(trackId, title, artist, album, duration, version: 4);
      await _deleteCache('chosen_$previousKey');
    }
    _memory[key] = document;
    return _store(key, document);
  }

  Future<LyricsDocument?> _fetchLrclibById(int id) async {
    if (id <= 0) return null;
    final client = _lrclibClient();
    try {
      final found = await _getLrclibJson(client, Uri.https('lrclib.net', '/api/get/$id'));
      return found is Map ? _lrclibDocument(Map<String, dynamic>.from(found)) : null;
    } catch (error) {
      debugPrint('LRCLIB selected lyric lookup failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<dynamic> _getLrclibJson(HttpClient client, Uri uri) => _performLrclibRequest(client, uri);

  // Serialize start times, not whole responses: a stalled automatic lookup
  // must not hold every subsequent manual search behind it.
  Future<void> _lrclibSlot() {
    final slot = _lrclibQueue.catchError((_) {}).then((_) async {
      void checkBackoff() {
        final retryAt = _lrclibRetryAt;
        if (retryAt != null && DateTime.now().isBefore(retryAt)) {
          throw LyricsLookupException('LRCLIB is temporarily unavailable. Please try again later.', retryAt: retryAt);
        }
      }

      checkBackoff();
      final last = _lastLrclibRequest;
      if (last != null) {
        final wait = _lrclibRequestGap - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait > _lrclibRequestGap ? _lrclibRequestGap : wait);
      }
      checkBackoff();
      _lastLrclibRequest = DateTime.now();
    });
    _lrclibQueue = slot;
    return slot;
  }

  Future<dynamic> _performLrclibRequest(HttpClient client, Uri uri) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      await _lrclibSlot();
      final request = await client.getUrl(uri).timeout(lrclibTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, _lrclibUserAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(lrclibTimeout);
      final status = response.statusCode;
      if (status == 429 || status == 503 || status == 502 || status == 504) {
        final hint = response.headers.value(HttpHeaders.retryAfterHeader);
        var delay = const Duration(seconds: 1);
        final seconds = int.tryParse(hint ?? '');
        if (seconds != null && seconds >= 0) {
          delay = Duration(seconds: seconds);
        } else if (hint != null) {
          try {
            final remaining = HttpDate.parse(hint).difference(DateTime.now());
            if (remaining > Duration.zero) delay = remaining;
          } catch (_) {
            /* A malformed hint uses a short bounded retry. */
          }
        }
        final retryAt = DateTime.now().add(delay);
        if (_lrclibRetryAt == null || retryAt.isAfter(_lrclibRetryAt!)) _lrclibRetryAt = retryAt;
        await response.drain<void>().timeout(lrclibTimeout);
        if (attempt == 0 && delay <= const Duration(seconds: 3)) {
          await Future<void>.delayed(delay);
          continue;
        }
        throw LyricsLookupException(
          status == 429 || status == 503
              ? 'LRCLIB is busy. Try again in a moment.'
              : 'LRCLIB is temporarily unavailable. Please try again later.',
          retryAt: _lrclibRetryAt,
        );
      }
      if (status == 404) {
        await response.drain<void>().timeout(lrclibTimeout);
        return null;
      }
      if (status != 200) {
        await response.drain<void>().timeout(lrclibTimeout);
        throw LyricsLookupException(
          status == 429 || status >= 500
              ? 'LRCLIB is busy. Try again in a moment.'
              : 'Could not reach LRCLIB. Check your connection and try again.',
        );
      }
      return jsonDecode(await utf8.decoder.bind(response).join().timeout(lrclibTimeout));
    }
    return null;
  }

  static LyricsDocument? _lrclibDocument(Map<String, dynamic> json, {String source = 'LRCLIB'}) {
    if (json['instrumental'] == true) {
      return LyricsDocument(lines: [], timingQuality: LyricTimingQuality.plain, source: source, instrumental: true);
    }
    final lyricsfile = json['lyricsfile'];
    LyricsDocument? structured;
    if (lyricsfile is String && lyricsfile.isNotEmpty) {
      try {
        final parsed = LyricsParser.parseLyricsfile(lyricsfile, source: source);
        if (parsed.timingQuality == LyricTimingQuality.word && !parsed.isEmpty) return parsed;
        if (!parsed.isEmpty) structured = parsed;
      } catch (_) {
        /* Older or invalid Lyricsfile entries still have legacy text. */
      }
    }
    final synced = json['syncedLyrics']?.toString().trim() ?? '';
    if (synced.isNotEmpty) return LyricsParser.parseLrc(synced, source: source);
    if (structured != null) return structured;
    final plain = json['plainLyrics']?.toString().trim() ?? '';
    return plain.isEmpty ? null : LyricsParser.parsePlain(plain, source: source);
  }

  Map<String, dynamic>? _bestAmllCandidate(
    Iterable<Map<String, dynamic>> candidates, {
    required String title,
    required String artist,
  }) {
    final wantedTitle = _normalized(title);
    final wantedArtist = _normalized(_cleanArtist(artist));
    Map<String, dynamic>? best;
    var bestScore = -1;
    for (final candidate in candidates) {
      final titles = <String>{
        if (candidate['title'] != null) candidate['title'].toString(),
        for (final value in candidate['titles'] as List? ?? const []) value.toString(),
      };
      if (!titles.any((value) => _normalized(value) == wantedTitle)) continue;
      final artists = <String>{
        if (candidate['artist'] != null) candidate['artist'].toString(),
        for (final value in candidate['artists'] as List? ?? const []) value.toString(),
      };
      final artistMatches =
          wantedArtist.isEmpty ||
          artists.any((value) {
            final candidateArtist = _normalized(value);
            return candidateArtist == wantedArtist ||
                (candidateArtist.isNotEmpty && wantedArtist.contains(candidateArtist)) ||
                (wantedArtist.isNotEmpty && candidateArtist.contains(wantedArtist));
          });
      if (!artistMatches) continue;
      final score = (candidate['score'] as num?)?.toInt() ?? 0;
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  Future<LyricsDocument?> _readCache(String key, {bool refreshFallback = false}) async {
    try {
      final file = await _cacheFile(key);
      if (!await file.exists()) return null;
      final document = LyricsDocument.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      if (refreshFallback &&
          document.source.startsWith('LRCLIB') &&
          document.timingQuality != LyricTimingQuality.word &&
          !document.instrumental &&
          DateTime.now().difference(await file.lastModified()) >= _fallbackCacheDuration) {
        return null;
      }
      return document.isEmpty && !document.instrumental ? null : document;
    } catch (_) {
      return null;
    }
  }

  Future<LyricsDocument> _store(String key, LyricsDocument document) async {
    try {
      final file = await _cacheFile(key);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(document.toJson()), flush: true);
    } catch (error) {
      debugPrint('Lyrics cache write failed: $error');
    }
    return document;
  }

  Future<void> _deleteCache(String key) async {
    try {
      final file = await _cacheFile(key);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('Lyrics cache reset failed: $error');
    }
  }

  Future<int?> _readManualSelection(String key) async {
    try {
      final file = await _selectionFile(key);
      if (!await file.exists()) return null;
      return int.tryParse((await file.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeManualSelection(String key, int id) async {
    final file = await _selectionFile(key);
    await file.parent.create(recursive: true);
    await file.writeAsString('$id', flush: true);
  }

  Future<File> _cacheFile(String key) async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'lyrics', '$key.json'));
  }

  Future<File> _selectionFile(String key) async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'lyrics', 'selection_$key.txt'));
  }

  static String _key(
    String trackId,
    String title,
    String artist,
    String album,
    Duration? duration, {
    int version = _cacheVersion,
  }) => sha256
      .convert(
        utf8.encode('$version\u0000$trackId\u0000$title\u0000$artist\u0000$album\u0000${duration?.inSeconds ?? 0}'),
      )
      .toString();

  static ({String title, String artist}) _lookupMetadata(String rawTitle, String rawArtist) {
    var title = _cleanTitle(rawTitle);
    var artist = _cleanArtist(rawArtist);
    final suffix = title.lastIndexOf(' - ');
    if (artist.isNotEmpty && suffix > 0 && _normalized(title.substring(suffix + 3)) == _normalized(artist)) {
      title = title.substring(0, suffix).trim();
    }
    final separator = title.indexOf(' - ');
    if (separator > 0) {
      final prefix = _cleanArtist(title.substring(0, separator));
      if (artist.isEmpty || _normalized(artist).contains(_normalized(prefix))) {
        artist = prefix;
        title = title.substring(separator + 3).trim();
      }
    }
    return (title: title, artist: artist);
  }

  static String _cleanTitle(String title) => title
      .replaceAll(RegExp(r'\s*[\[(](official|lyrics?|audio|video|visuali[sz]er).*?[\])]', caseSensitive: false), '')
      .trim();

  static String _cleanArtist(String artist) {
    final cleaned = artist
        .replaceAll(RegExp(r'\s*-\s*topic\s*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'vevo\s*$', caseSensitive: false), '')
        .trim();
    return {'unknown', 'youtube'}.contains(cleaned.toLowerCase()) ? '' : cleaned;
  }

  static String _normalized(String value) =>
      value.toLowerCase().replaceAll('&', 'and').replaceAll(RegExp(r'''[\s\-_.!,?'"`()\[\]{}:;/\\]+'''), '');
}

@visibleForTesting
LrclibCandidate? selectAutomaticLrclibCandidate(Iterable<LrclibCandidate> candidates, Duration? targetDuration) {
  if (targetDuration == null || targetDuration.inMilliseconds <= 0) return null;
  for (final candidate in candidates) {
    if (!candidate.hasLyrics || candidate.duration.inMilliseconds <= 0) continue;
    final difference = (candidate.duration.inMilliseconds - targetDuration.inMilliseconds).abs();
    if (difference <= const Duration(seconds: 3).inMilliseconds) return candidate;
  }
  return null;
}

@visibleForTesting
LrclibCandidate? selectTitleOnlyLrclibCandidate(Iterable<LrclibCandidate> candidates, Duration? targetDuration) {
  if (targetDuration == null || targetDuration.inMilliseconds <= 0) return null;
  LrclibCandidate? best;
  int? bestDifference;
  for (final candidate in candidates) {
    if (!candidate.hasLyrics || candidate.duration.inMilliseconds <= 0) continue;
    final difference = (candidate.duration.inMilliseconds - targetDuration.inMilliseconds).abs();
    if (difference <= const Duration(seconds: 2).inMilliseconds &&
        (bestDifference == null || difference < bestDifference)) {
      best = candidate;
      bestDifference = difference;
      if (difference == 0) break;
    }
  }
  return best;
}
