import 'dart:convert';
import 'dart:async';
import 'package:resonance/services/youtube/youtube_request.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:resonance/models/youtube_video_source.dart';
import 'package:resonance/services/youtube/windows_ytmusic_helper.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';

class YoutubeVideoService {
  const YoutubeVideoService();
  static const _android = MethodChannel('resonance/android_youtube');
  static const format =
      'bestvideo[height<=720][has_drm!=true]+bestaudio[has_drm!=true]/best[height<=720][has_drm!=true]';
  static final _versions = <String, ({DateTime at, YoutubeMediaVersions value})>{};
  static final _streams = <String, ({DateTime at, ResolvedYoutubeVideo value})>{};
  static int _requestId = -1000000;

  Future<YoutubeMediaVersions> versions(String videoId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) throw const FormatException('Invalid video ID');
    final cached = _versions[videoId];
    if (cached != null && DateTime.now().difference(cached.at) < const Duration(minutes: 20)) return cached.value;
    final raw = Platform.isWindows
        ? await const WindowsYtMusicHelper().invoke(action: 'versions', videoId: videoId)
        : await _android.invokeMethod<String>('getMusicMediaVersions', {'videoId': videoId});
    final value = YoutubeMediaVersions.fromJson(Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map));
    if (value.originalId != videoId) throw const FormatException('Video identity changed');
    _versions[videoId] = (at: DateTime.now(), value: value);
    if (_versions.length > 100) _versions.remove(_versions.keys.first);
    return value;
  }

  Future<ResolvedYoutubeVideo> resolve(String videoId, {bool Function()? isCurrent}) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) throw const FormatException('Invalid video ID');
    final access = YoutubeAccessService.active;
    final key = '$videoId:${identityHashCode(access)}:${access?.revision ?? 0}';
    final cached = _streams[key];
    bool fresh(Uri uri) {
      final expiry = int.tryParse(uri.queryParameters['expire'] ?? '');
      return expiry == null || DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60 < expiry;
    }

    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 10) &&
        fresh(cached.value.videoUri) &&
        fresh(cached.value.audioUri)) {
      return cached.value;
    }
    final url = 'https://www.youtube.com/watch?v=$videoId';
    late final ResolvedYoutubeVideo value;
    if (Platform.isWindows) {
      final runner = WindowsYtdlpRunner.instance;
      final args = ['--dump-single-json', '--no-download', '--no-playlist', '--format', format, url];
      late final WindowsYtdlpResult result;
      final request = YoutubeRequest();
      final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (isCurrent?.call() == false) request.cancel();
      });
      try {
        try {
          result = await runner.run(
            args,
            guest: true,
            timeout: const Duration(seconds: 15),
            reportFailure: !runner.hasConfiguredAccess,
            sourceUrl: url,
            requireOutput: true,
            request: request,
          );
        } catch (error) {
          if (error is YoutubeRequestCancelled || !runner.hasConfiguredAccess) rethrow;
          result = await runner.run(
            args,
            sourceUrl: url,
            requireOutput: true,
            timeout: const Duration(seconds: 15),
            request: request,
          );
        }
      } finally {
        timer.cancel();
      }
      value = ResolvedYoutubeVideo.fromExtraction(jsonDecode(result.stdout) as Map<String, dynamic>);
    } else {
      final requestId = --_requestId;
      var cancelled = false;
      final timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        if (!cancelled && isCurrent?.call() == false) {
          cancelled = true;
          unawaited(_android.invokeMethod<void>('cancelStreamData', {'requestId': requestId}).catchError((_) {}));
        }
      });
      try {
        final raw = await _android.invokeMethod<String>('getVideoStreamData', {'url': url, 'requestId': requestId});
        value = ResolvedYoutubeVideo.fromJson(Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map));
      } finally {
        timer.cancel();
      }
    }
    _streams[key] = (at: DateTime.now(), value: value);
    if (_streams.length > 12) _streams.remove(_streams.keys.first);
    return value;
  }
}
