import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/youtube/windows_ytmusic_helper.dart';

/// The radio/watch queue returned by YouTube Music for a specific video.
/// This is a guest endpoint and does not expose or require saved cookies.
class YoutubeMusicRelatedService {
  static const _android = MethodChannel('resonance/android_youtube');
  static final Map<String, ({DateTime at, List<YoutubeTrack> tracks})> _cache = {};
  static final Map<String, Future<List<YoutubeTrack>>> _inFlight = {};

  const YoutubeMusicRelatedService();

  Future<List<YoutubeTrack>> fetch(String videoId, {int limit = 25}) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) return const [];
    final cached = _cache[videoId];
    if (cached != null && DateTime.now().difference(cached.at) < const Duration(minutes: 20)) {
      return cached.tracks;
    }
    final pending = _inFlight.putIfAbsent(videoId, () async {
      final raw = Platform.isAndroid
          ? await _android.invokeMethod<String>('getMusicRelated', {'videoId': videoId, 'limit': limit})
          : Platform.isWindows
          ? await const WindowsYtMusicHelper().invoke(action: 'related', videoId: videoId, limit: limit)
          : null;
      if (raw == null) return const <YoutubeTrack>[];
      return decodeResponse(raw, videoId);
    });
    try {
      final tracks = await pending.timeout(const Duration(seconds: 12));
      if (tracks.isNotEmpty) _cache[videoId] = (at: DateTime.now(), tracks: tracks);
      return tracks;
    } finally {
      if (identical(_inFlight[videoId], pending)) _inFlight.remove(videoId);
    }
  }

  static List<YoutubeTrack> decodeResponse(String raw, String seedVideoId) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['tracks'] is! List) return const [];
    final seen = <String>{seedVideoId};
    return [
      for (final value in decoded['tracks'] as List)
        if (value is Map)
          for (final track in [YoutubeTrack.fromJson(Map<String, dynamic>.from(value))])
            if (track.videoId case final id?)
              if (seen.add(id)) track,
    ];
  }
}
