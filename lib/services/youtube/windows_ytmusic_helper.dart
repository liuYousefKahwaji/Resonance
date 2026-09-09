import 'dart:convert';
import 'dart:io';

import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';

/// Runs the packaged Windows YT Music helper without duplicating its sensitive
/// browser/cookies selection logic across Home and history-sync features.
class WindowsYtMusicHelper {
  const WindowsYtMusicHelper();

  Future<String> invoke({
    required String action,
    int? limit,
    String? videoId,
    String? overrideBrowserSource,
    YoutubeAccessService? access,
  }) async {
    final runner = WindowsYtdlpRunner.instance;
    final helper = runner.ytMusicHomePath;
    if (!await File(helper).exists()) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.unsupported,
        userMessage: 'The YouTube Music component is missing from this installation.',
        technicalSummary: 'Missing bin/resonance-ytmusic-home.exe.',
      );
    }
    final configuredAccess = access ?? YoutubeAccessService.active;
    final browser = overrideBrowserSource ?? configuredAccess?.windowsBrowserId;
    final cookiePath = configuredAccess?.windowsCookiePath;
    if (browser == null && cookiePath == null) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.verificationRequired,
        userMessage: 'Connect YouTube access before using YouTube Music.',
      );
    }

    final process = await Process.start(helper, [
      if (browser != null) ...['--browser', browser] else ...['--cookies-file', cookiePath!],
      '--action',
      action,
      if (limit != null) ...['--limit', '$limit'],
      if (videoId != null) ...['--video-id', videoId],
    ], runInShell: false);
    final stdout = await process.stdout.transform(utf8.decoder).join();
    final stderr = await process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    if (exitCode != 0 || stdout.trim().isEmpty) {
      throw YoutubeFailureClassifier.classify(
        stderr.isEmpty ? 'YouTube Music helper exited with code $exitCode' : stderr,
        authenticated: true,
      );
    }
    return stdout;
  }
}
