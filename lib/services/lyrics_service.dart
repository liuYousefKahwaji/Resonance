import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:resonance/models/lyrics.dart';
import 'package:resonance/services/lyrics_parser.dart';

class LyricsService {
  static const _cacheVersion = 3;
  static const _requestTimeout = Duration(seconds: 5);
  static const _lrclibRequestGap = Duration(milliseconds: 300);
  static const _lrclibUserAgent = 'Resonance/2.8.0 (https://github.com/liuYousefKahwaji/Resonance)';
  static final Map<String, LyricsDocument> _memory = {};
  static final Map<String, Future<LyricsDocument?>> _inFlight = {};
  static Future<void> _lrclibQueue = Future.value();
  static DateTime? _lastLrclibRequest;

  const LyricsService();

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
      if (result != null) _memory[key] = result;
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
    final cached = await _readCache(key);
    if (cached != null) return cached;

    final sidecar = await _readSidecar(trackId);
    if (sidecar != null && !sidecar.isEmpty) return _store(key, sidecar);

    final metadata = _lookupMetadata(title, artist);
    final selectedId = await _readManualSelection(key);
    if (selectedId != null) {
      final selected = await _fetchLrclibById(selectedId);
      if (selected != null) return _store(key, selected);
    }
    // Start network sources together, but preserve the quality order when
    // selecting the result. LRCLIB can finish while a rich provider is being
    // checked instead of adding its latency afterward.
    final betterLyrics = _fetchBetterLyrics(title: metadata.title, artist: metadata.artist, duration: duration);
    final amll = _fetchAmll(title: metadata.title, artist: metadata.artist);
    final lrclib = _fetchLrclib(
      title: metadata.title,
      artist: metadata.artist,
      album: album.trim(),
      duration: duration,
    );

    for (final source in [betterLyrics, amll, lrclib]) {
      final document = await source;
      if (document != null && (document.instrumental || !document.isEmpty)) return _store(key, document);
    }
    return null;
  }

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
    Duration? duration,
  }) async {
    if (title.isEmpty || artist.isEmpty) return null;
    final query = <String, String>{'s': title, 'a': artist};
    if (duration != null && duration.inSeconds > 0) query['d'] = '${duration.inSeconds}';
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final response = await (await client.getUrl(
        Uri.https('lyrics-api.boidu.dev', '/getLyrics', query),
      )).close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final payload = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
      final score = (payload['score'] as num?)?.toDouble();
      final ttml = payload['ttml']?.toString() ?? '';
      if (ttml.isEmpty || (score != null && score < 65)) return null;
      final document = LyricsParser.parseTtml(ttml, source: 'Better Lyrics');
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
      final request = await client.postUrl(Uri.https('amlldb.bikonoo.com', '/api/search-lyrics'));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.userAgentHeader, 'Resonance/2.7.0');
      request.add(utf8.encode(jsonEncode({'query': title, 'type': 'title'})));
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final decoded = jsonDecode(await utf8.decoder.bind(response).join());
      if (decoded is! List) return null;
      final candidates = decoded.whereType<Map>().map((item) => Map<String, dynamic>.from(item));
      final candidate = _bestAmllCandidate(candidates, title: title, artist: artist);
      final file = candidate?['file']?.toString();
      if (file == null || !RegExp(r'^[A-Za-z0-9._-]+\.ttml$').hasMatch(file)) return null;
      final rawResponse = await (await client.getUrl(
        Uri.https('amlldb.bikonoo.com', '/raw-lyrics/${Uri.encodeComponent(file)}'),
      )).close().timeout(_requestTimeout);
      if (rawResponse.statusCode != HttpStatus.ok) {
        await rawResponse.drain<void>();
        return null;
      }
      final document = LyricsParser.parseTtml(await utf8.decoder.bind(rawResponse).join(), source: 'AMLL');
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
    final client = HttpClient()..connectionTimeout = _requestTimeout;
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
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final found = await _getLrclibJson(client, Uri.https('lrclib.net', '/api/search', {'q': cleaned}));
      if (found is! List) return const [];
      return found
          .whereType<Map>()
          .map((item) => LrclibCandidate.fromJson(Map<String, dynamic>.from(item)))
          .where((candidate) => candidate.id > 0 && candidate.hasLyrics)
          .toList(growable: false);
    } catch (error) {
      debugPrint('LRCLIB candidate search failed: $error');
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  Future<LyricsDocument?> selectLrclibCandidate({
    required String trackId,
    required String title,
    required String artist,
    String album = '',
    required Duration? duration,
    required LrclibCandidate candidate,
  }) async {
    final document = await _fetchLrclibById(candidate.id);
    if (document == null) return null;
    final key = _key(trackId, title, artist, album, duration);
    await _writeManualSelection(key, candidate.id);
    _memory[key] = document;
    return _store(key, document);
  }

  Future<LyricsDocument?> _fetchLrclibById(int id) async {
    if (id <= 0) return null;
    final client = HttpClient()..connectionTimeout = _requestTimeout;
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

  Future<dynamic> _getLrclibJson(HttpClient client, Uri uri) {
    final completer = Completer<dynamic>();
    _lrclibQueue = _lrclibQueue.catchError((_) {}).then((_) async {
      try {
        final previous = _lastLrclibRequest;
        if (previous != null) {
          final remaining = _lrclibRequestGap - DateTime.now().difference(previous);
          if (!remaining.isNegative) await Future<void>.delayed(remaining);
        }
        completer.complete(await _performLrclibRequest(client, uri));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<dynamic> _performLrclibRequest(HttpClient client, Uri uri) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      _lastLrclibRequest = DateTime.now();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _lrclibUserAgent);
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode == HttpStatus.tooManyRequests && attempt == 0) {
        final retrySeconds = int.tryParse(response.headers.value(HttpHeaders.retryAfterHeader) ?? '') ?? 1;
        await response.drain<void>();
        await Future<void>.delayed(Duration(seconds: retrySeconds.clamp(1, 10).toInt()));
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      return jsonDecode(await utf8.decoder.bind(response).join());
    }
    return null;
  }

  LyricsDocument? _lrclibDocument(Map<String, dynamic> json, {String source = 'LRCLIB'}) {
    if (json['instrumental'] == true) {
      return LyricsDocument(lines: [], timingQuality: LyricTimingQuality.plain, source: source, instrumental: true);
    }
    final synced = json['syncedLyrics']?.toString().trim() ?? '';
    if (synced.isNotEmpty) return LyricsParser.parseLrc(synced, source: source);
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

  Future<LyricsDocument?> _readCache(String key) async {
    try {
      final file = await _cacheFile(key);
      if (!await file.exists()) return null;
      final document = LyricsDocument.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
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

  static String _key(String trackId, String title, String artist, String album, Duration? duration) => sha256
      .convert(
        utf8.encode(
          '$_cacheVersion\u0000$trackId\u0000$title\u0000$artist\u0000$album\u0000${duration?.inSeconds ?? 0}',
        ),
      )
      .toString();

  static ({String title, String artist}) _lookupMetadata(String rawTitle, String rawArtist) {
    var title = _cleanTitle(rawTitle);
    var artist = _cleanArtist(rawArtist);
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
