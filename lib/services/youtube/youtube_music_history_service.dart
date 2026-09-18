import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/youtube/windows_ytmusic_helper.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';

class YoutubeMusicHistoryService {
  static const _androidChannel = MethodChannel('resonance/android_youtube');

  const YoutubeMusicHistoryService();

  Future<List<YoutubeTrack>> fetch({int limit = 100}) async {
    final access = YoutubeAccessService.active;
    if (access == null || !access.isConfigured) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.verificationRequired,
        userMessage: 'Connect YouTube access to view your YouTube Music history.',
      );
    }
    try {
      final bounded = limit.clamp(1, 100);
      final raw = Platform.isAndroid
          ? await _androidChannel.invokeMethod<String>('getMusicHistory', {'limit': bounded})
          : Platform.isWindows
          ? await const WindowsYtMusicHelper().invoke(action: 'history', limit: bounded)
          : throw const YoutubeFailure(
              kind: YoutubeFailureKind.unsupported,
              userMessage: 'YouTube Music history is available on Windows and Android only.',
            );
      if (raw == null || raw.trim().isEmpty) throw StateError('YouTube Music returned an empty history response.');
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['tracks'] is! List) throw const FormatException('Invalid history response.');
      final tracks = <YoutubeTrack>[];
      for (final value in decoded['tracks'] as List) {
        if (value is! Map) continue;
        final track = YoutubeTrack.fromJson(Map<String, dynamic>.from(value));
        if (track.videoId != null) tracks.add(track);
      }
      await access.recordAuthenticatedSuccess();
      return tracks;
    } catch (error) {
      final failure = error is YoutubeFailure
          ? error
          : YoutubeFailureClassifier.classify(error, authenticated: access.isConfigured);
      access.observeFailure(failure);
      throw failure;
    }
  }
}
