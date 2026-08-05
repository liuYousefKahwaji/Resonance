import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:resonance/models/youtube_track.dart';

/// Fills engagement fields which YouTube's lightweight search responses omit.
/// yt-dlp remains authoritative when it supplies values; the public Return
/// YouTube Dislike API is only used for missing counts.
class YoutubeStatsService {
  static const _cacheTtl = Duration(hours: 1);
  static const _timeout = Duration(seconds: 5);
  static final Map<String, ({DateTime storedAt, YoutubeTrack track})> _cache = {};
  static final Map<String, Future<YoutubeTrack>> _inFlight = {};

  const YoutubeStatsService();

  Future<YoutubeTrack> hydrate(YoutubeTrack track) async {
    if (track.likeCount != null && track.viewCount != null) return track;
    final id = track.videoId;
    if (id == null) return track;
    final cached = _cache[id];
    if (cached != null && DateTime.now().difference(cached.storedAt) < _cacheTtl) {
      return track.copyWith(viewCount: cached.track.viewCount, likeCount: cached.track.likeCount);
    }
    final running = _inFlight[id];
    if (running != null) return running;
    final future = _fetch(track, id);
    _inFlight[id] = future;
    try {
      final hydrated = await future;
      _cache[id] = (storedAt: DateTime.now(), track: hydrated);
      return hydrated;
    } finally {
      if (identical(_inFlight[id], future)) _inFlight.remove(id);
    }
  }

  Future<List<YoutubeTrack>> hydrateAll(List<YoutubeTrack> tracks, {int concurrency = 4}) async {
    final hydrated = <YoutubeTrack>[];
    final batchSize = concurrency.clamp(1, 8);
    for (var offset = 0; offset < tracks.length; offset += batchSize) {
      final batch = tracks.skip(offset).take(batchSize);
      hydrated.addAll(await Future.wait([for (final track in batch) hydrate(track)]));
    }
    return hydrated;
  }

  Future<YoutubeTrack> _fetch(YoutubeTrack track, String id) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(Uri.https('returnyoutubedislikeapi.com', '/votes', {'videoId': id}));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'Resonance/2.8.0');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return track;
      }
      final payload = jsonDecode(await utf8.decoder.bind(response).join());
      if (payload is! Map) return track;
      final likes = _count(payload['likes']);
      final views = _count(payload['viewCount']);
      return track.copyWith(viewCount: track.viewCount ?? views, likeCount: track.likeCount ?? likes);
    } catch (error) {
      debugPrint('YouTube statistics fallback failed for $id: $error');
      return track;
    } finally {
      client.close(force: true);
    }
  }

  static int? _count(dynamic value) => value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
}
