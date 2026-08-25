import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/core/youtube/youtube_music_home_models.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';

/// Retrieves the authenticated YouTube Music home feed through the native
/// cookie boundary on Android or the packaged helper on Windows.
class YoutubeMusicHomeService {
  static const _androidChannel = MethodChannel('resonance/android_youtube');

  const YoutubeMusicHomeService();

  Future<void> testWindowsAccess(String browserSource) async {
    final raw = await _fetchWindows(1, overrideBrowserSource: browserSource);
    if (decodeResponse(raw).isEmpty) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.sessionRejected,
        userMessage: 'The selected browser profile did not return an authenticated YouTube Music home.',
      );
    }
  }

  Future<YoutubeMusicHome> fetch({int limit = 60}) async {
    final access = YoutubeAccessService.active;
    if (access == null ||
        !access.isConfigured ||
        access.status.state == YoutubeAccessState.rejected ||
        access.status.state == YoutubeAccessState.verificationRequired ||
        access.status.state == YoutubeAccessState.unavailable) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.verificationRequired,
        userMessage: 'Connect YouTube access to view your YouTube Music home.',
      );
    }
    try {
      final raw = Platform.isAndroid
          ? await _androidChannel.invokeMethod<String>('getMusicHome', {'limit': limit.clamp(1, 80)})
          : Platform.isWindows
          ? await _fetchWindows(limit)
          : throw const YoutubeFailure(
              kind: YoutubeFailureKind.unsupported,
              userMessage: 'YouTube Music home is available on Windows and Android only.',
            );
      if (raw == null || raw.trim().isEmpty) throw StateError('YouTube Music returned an empty home feed.');
      final home = decodeResponse(raw);
      await access.recordAuthenticatedSuccess();
      return home;
    } catch (error) {
      final failure = error is YoutubeFailure
          ? error
          : YoutubeFailureClassifier.classify(error, authenticated: access.isConfigured);
      access.observeFailure(failure);
      throw failure;
    }
  }

  Future<String> _fetchWindows(int limit, {String? overrideBrowserSource}) async {
    final runner = WindowsYtdlpRunner.instance;
    final helper = runner.ytMusicHomePath;
    if (!await File(helper).exists()) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.unsupported,
        userMessage: 'The YouTube Music home component is missing from this installation.',
        technicalSummary: 'Missing bin/resonance-ytmusic-home.exe.',
      );
    }
    final access = YoutubeAccessService.active;
    final browser = overrideBrowserSource ?? access?.windowsBrowserId;
    final cookiePath = access?.windowsCookiePath;
    if (browser == null && cookiePath == null) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.verificationRequired,
        userMessage: 'Connect a browser session before opening YouTube Music home.',
      );
    }
    final process = await Process.start(helper, [
      if (browser != null) ...['--browser', browser] else ...['--cookies-file', cookiePath!],
      '--limit',
      '$limit',
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

  @visibleForTesting
  YoutubeMusicHome decodeResponse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Invalid YouTube Music home response.');
    final shelves = <YoutubeMusicHomeShelf>[];
    final rawShelves = decoded['shelves'];
    if (rawShelves is! List) return const YoutubeMusicHome(shelves: []);
    for (final shelf in rawShelves) {
      if (shelf is! Map) continue;
      final title = shelf['title']?.toString().trim() ?? '';
      final rawTracks = shelf['tracks'];
      final rawItems = shelf['items'];
      if (title.isEmpty || (rawTracks is! List && rawItems is! List)) continue;
      final tracks = <YoutubeTrack>[];
      for (final rawTrack in rawTracks is List ? rawTracks : const []) {
        if (rawTrack is! Map) continue;
        final map = Map<String, dynamic>.from(rawTrack);
        final track = YoutubeTrack.fromJson(map);
        if (track.videoId != null && track.title.trim().isNotEmpty) tracks.add(track);
      }
      final items = <YoutubeMusicHomeItem>[];
      for (final rawItem in rawItems is List ? rawItems : const []) {
        if (rawItem is! Map) continue;
        final title = rawItem['title']?.toString().trim() ?? '';
        if (title.isEmpty) continue;
        YoutubeTrack? track;
        final rawTrack = rawItem['track'];
        if (rawTrack is Map) {
          final candidate = YoutubeTrack.fromJson(Map<String, dynamic>.from(rawTrack));
          if (candidate.videoId != null) track = candidate;
        }
        items.add(
          YoutubeMusicHomeItem(
            title: title,
            subtitle: rawItem['subtitle']?.toString().trim() ?? '',
            thumbnailUrl: rawItem['thumbnail']?.toString().trim().isNotEmpty == true
                ? rawItem['thumbnail'].toString()
                : null,
            kind: rawItem['kind']?.toString().trim() ?? 'collection',
            track: track,
            playlistId: rawItem['playlistId']?.toString().trim().isNotEmpty == true
                ? rawItem['playlistId'].toString().trim()
                : null,
            browseId: rawItem['browseId']?.toString().trim().isNotEmpty == true
                ? rawItem['browseId'].toString().trim()
                : null,
          ),
        );
        if (track != null && tracks.every((existing) => existing.url != track!.url)) tracks.add(track);
      }
      if (tracks.isNotEmpty || items.isNotEmpty) {
        shelves.add(YoutubeMusicHomeShelf(title: title, tracks: tracks, items: items));
      }
    }
    return YoutubeMusicHome(shelves: shelves);
  }
}
