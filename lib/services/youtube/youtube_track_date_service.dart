import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/models/youtube_track_date.dart';
import 'package:resonance/services/youtube/youtube_artist_service.dart';

/// Optional visible-row enrichment. Never extracts audio or reads browser
/// credentials. Two bounded requests at a time; failures are cached too.
class YoutubeTrackDateService {
  const YoutubeTrackDateService({this.loader});
  final Future<String> Function(Uri)? loader;
  static final _cache = <String, ({DateTime at, YoutubeTrackDate? date})>{};
  static final _pending = <String, Future<YoutubeTrackDate?>>{};
  static final _waiters = <Completer<void>>[];
  static int _active = 0;

  Future<YoutubeTrackDate?> fetch(YoutubeTrack track, {bool Function()? isActive}) async {
    if (track.date?.value != null) return track.date;
    final id = track.videoId;
    if (id == null) return null;
    final cached = _cache[id];
    if (cached != null &&
        DateTime.now().difference(cached.at) <
            (cached.date == null ? const Duration(minutes: 5) : const Duration(hours: 6))) {
      return cached.date;
    }
    final existing = _pending[id];
    if (existing != null) return existing;
    final future = _fetch(id, isActive);
    _pending[id] = future;
    try {
      return await future;
    } finally {
      if (identical(_pending[id], future)) _pending.remove(id);
    }
  }

  Future<YoutubeTrackDate?> _fetch(String id, bool Function()? isActive) async {
    if (_active >= 2) {
      final ready = Completer<void>();
      _waiters.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      if (isActive != null && !isActive()) return null;
      final uri = Uri.https('www.youtube.com', '/watch', {'v': id, 'hl': 'en'});
      final html = loader != null ? await loader!(uri) : await _read(uri);
      final date = parseHtml(html);
      _cache[id] = (at: DateTime.now(), date: date);
      if (_cache.length > 500) _cache.remove(_cache.keys.first);
      return date;
    } catch (_) {
      _cache[id] = (at: DateTime.now(), date: null);
      return null;
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }

  Future<String> _read(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.maxRedirects = 3;
        request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) return '';
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 4 * 1024 * 1024) return '';
        }
        return utf8.decode(bytes);
      })().timeout(const Duration(seconds: 7));
    } finally {
      client.close(force: true);
    }
  }

  static YoutubeTrackDate? parseHtml(String html) {
    try {
      final data = YoutubeArtistService.jsonAfter(html, RegExp(r'(?:var\s+)?ytInitialPlayerResponse\s*=\s*'));
      final micro = data['microformat']?['playerMicroformatRenderer'];
      if (micro is Map) {
        final date =
            YoutubeTrackDate.parse(micro['releaseDate'], isRelease: true) ??
            YoutubeTrackDate.parse(micro['publishDate'] ?? micro['uploadDate']);
        if (date != null) return date;
      }
    } catch (_) {
      /* Some watch pages expose only schema metadata. */
    }
    final match = RegExp(
      r'<meta\s+itemprop="(?:datePublished|uploadDate)"\s+content="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    return YoutubeTrackDate.parse(match?[1]);
  }
}
