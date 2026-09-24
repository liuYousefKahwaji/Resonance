import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/windows_ytmusic_helper.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/services/youtube/youtube_history_preferences.dart';
import 'package:resonance/services/youtube/youtube_music_history_service.dart';

enum YoutubeHistoryWriteStatus { written, disabled, skipped, authUnavailable, unsupported, failed }

class YoutubeHistoryWriteResult {
  const YoutubeHistoryWriteResult(this.status, {this.videoId, this.diagnosticCode});

  final YoutubeHistoryWriteStatus status;
  final String? videoId;
  final String? diagnosticCode;
}

abstract interface class YoutubeHistoryReporter {
  Future<YoutubeHistoryWriteResult> reportVideoId(String videoId);
}

typedef AndroidHistoryInvoker = Future<Object?> Function(String videoId);
typedef WindowsHistoryInvoker = Future<String> Function(String videoId);

/// Best-effort transport for an already-confirmed listening session.
///
/// It owns no playback timing and deliberately never throws expected remote
/// failures to the player layer.
class YoutubeHistoryService implements YoutubeHistoryReporter {
  YoutubeHistoryService({
    required YoutubeHistoryPreferences preferences,
    required YoutubeAccessService access,
    bool? isWindows,
    bool? isAndroid,
    AndroidHistoryInvoker? androidInvoker,
    WindowsHistoryInvoker? windowsInvoker,
  }) : _preferences = preferences,
       _access = access,
       _isWindows = isWindows ?? Platform.isWindows,
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _androidInvoker = androidInvoker ?? _defaultAndroidInvoke,
       _windowsInvoker = windowsInvoker ?? _defaultWindowsInvoke;

  static const _androidChannel = MethodChannel('resonance/android_youtube');
  static final RegExp _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

  final YoutubeHistoryPreferences _preferences;
  final YoutubeAccessService _access;
  final bool _isWindows;
  final bool _isAndroid;
  final AndroidHistoryInvoker _androidInvoker;
  final WindowsHistoryInvoker _windowsInvoker;

  static Future<Object?> _defaultAndroidInvoke(String videoId) =>
      _androidChannel.invokeMethod<Object?>('addMusicHistory', {'videoId': videoId});

  static Future<String> _defaultWindowsInvoke(String videoId) =>
      const WindowsYtMusicHelper().invoke(action: 'add-history', videoId: videoId);

  @override
  Future<YoutubeHistoryWriteResult> reportVideoId(String videoId) async {
    if (!_preferences.enabled) return const YoutubeHistoryWriteResult(YoutubeHistoryWriteStatus.disabled);
    if (!_videoIdPattern.hasMatch(videoId)) {
      return const YoutubeHistoryWriteResult(YoutubeHistoryWriteStatus.skipped, diagnosticCode: 'invalid_video_id');
    }
    if (!_access.isConfigured) {
      return YoutubeHistoryWriteResult(YoutubeHistoryWriteStatus.authUnavailable, videoId: videoId);
    }
    if (!_isWindows && !_isAndroid) {
      return YoutubeHistoryWriteResult(YoutubeHistoryWriteStatus.unsupported, videoId: videoId);
    }
    try {
      final raw = _isWindows ? await _windowsInvoker(videoId) : await _androidInvoker(videoId);
      final payload = _decodePayload(raw);
      if (payload?['ok'] == true && _asInt(payload?['statusCode']) == 204) {
        await _access.recordAuthenticatedSuccess();
        YoutubeMusicHistoryService.clearCache();
        return YoutubeHistoryWriteResult(YoutubeHistoryWriteStatus.written, videoId: videoId);
      }
      return YoutubeHistoryWriteResult(
        YoutubeHistoryWriteStatus.failed,
        videoId: videoId,
        diagnosticCode: 'malformed_response',
      );
    } catch (error) {
      final failure = YoutubeFailureClassifier.classify(error, authenticated: true);
      _access.observeFailure(failure);
      return YoutubeHistoryWriteResult(
        failure.isAccessFailure ? YoutubeHistoryWriteStatus.authUnavailable : YoutubeHistoryWriteStatus.failed,
        videoId: videoId,
        diagnosticCode: failure.kind.name,
      );
    }
  }

  static Map<Object?, Object?>? _decodePayload(Object? raw) {
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        return decoded is Map ? Map<Object?, Object?>.from(decoded) : null;
      } catch (_) {
        return null;
      }
    }
    return raw is Map ? Map<Object?, Object?>.from(raw) : null;
  }

  static int? _asInt(Object? value) => value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
}
