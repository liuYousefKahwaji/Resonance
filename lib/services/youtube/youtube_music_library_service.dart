import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/core/youtube/youtube_music_home_models.dart';
import 'package:resonance/services/youtube/windows_ytmusic_helper.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/services/youtube/youtube_music_home_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The saved playlist shelf has its own request and account-scoped cache so
/// fetching every library page cannot delay the first playable Home shelves.
class YoutubeMusicLibraryService {
  static const _channel = MethodChannel('resonance/android_youtube');
  static const _snapshotKey = 'youtube_music_library.snapshot_v1';
  static ({YoutubeAccessService access, int revision, DateTime storedAt, YoutubeMusicHomeShelf shelf})? _cache;
  static final _inFlight = <String, Future<YoutubeMusicHomeShelf>>{};
  final Future<String> Function(YoutubeAccessService access)? loader;

  const YoutubeMusicLibraryService({this.loader});

  static void clearCache() {
    _cache = null;
    _inFlight.clear();
  }

  bool _available(YoutubeAccessService access) =>
      access.isConfigured &&
      !{
        YoutubeAccessState.rejected,
        YoutubeAccessState.verificationRequired,
        YoutubeAccessState.unavailable,
      }.contains(access.status.state);

  String _identity(YoutubeAccessService access) => [
    access.status.method.name,
    access.status.browserId ?? '',
    access.windowsCookiePath ?? '',
    access.status.configuredAt?.toUtc().toIso8601String() ?? '',
  ].join('|');

  Future<YoutubeMusicHomeShelf?> loadCached() async {
    final access = YoutubeAccessService.active;
    if (access == null || !_available(access)) return null;
    final revision = access.revision;
    final cache = _cache;
    if (cache != null &&
        identical(cache.access, access) &&
        cache.revision == revision &&
        DateTime.now().difference(cache.storedAt) < const Duration(hours: 24)) {
      return cache.shelf;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_snapshotKey);
      if (raw == null) return null;
      final snapshot = jsonDecode(raw);
      if (snapshot is! Map || snapshot['identity'] != _identity(access)) return null;
      final stored = DateTime.tryParse(snapshot['storedAt']?.toString() ?? '');
      if (stored == null || DateTime.now().difference(stored) >= const Duration(hours: 24)) return null;
      final shelf = decodeResponse(jsonEncode(snapshot['data']));
      if (access.revision != revision || !_available(access)) return null;
      return shelf;
    } catch (_) {
      return null;
    }
  }

  Future<YoutubeMusicHomeShelf> fetch({bool forceRefresh = false}) async {
    final access = YoutubeAccessService.active;
    if (access == null || !_available(access)) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.verificationRequired,
        userMessage: 'Connect YouTube access to view your playlist library.',
      );
    }
    final cache = _cache;
    if (!forceRefresh &&
        cache != null &&
        identical(cache.access, access) &&
        cache.revision == access.revision &&
        DateTime.now().difference(cache.storedAt) < const Duration(minutes: 3)) {
      return cache.shelf;
    }
    final key = '${identityHashCode(access)}:${access.revision}';
    final pending = _inFlight.putIfAbsent(key, () => _fetchFresh(access, access.revision));
    try {
      return await pending;
    } finally {
      if (identical(_inFlight[key], pending)) _inFlight.remove(key);
    }
  }

  Future<YoutubeMusicHomeShelf> _fetchFresh(YoutubeAccessService access, int revision) async {
    try {
      final raw = loader != null
          ? await loader!(access)
          : Platform.isAndroid
          ? await _channel.invokeMethod<String>('getMusicLibrary')
          : Platform.isWindows
          ? await const WindowsYtMusicHelper().invoke(action: 'library', access: access)
          : throw UnsupportedError('YouTube Music library is available on Windows and Android.');
      if (raw == null) throw const FormatException('Empty playlist library response.');
      final shelf = decodeResponse(raw);
      if (access.revision != revision || !_available(access) || !identical(access, YoutubeAccessService.active)) {
        throw StateError('YouTube access changed during the request.');
      }
      await access.recordAuthenticatedSuccess();
      if (access.revision != revision || !_available(access) || !identical(access, YoutubeAccessService.active)) {
        throw StateError('YouTube access changed during the request.');
      }
      _cache = (access: access, revision: revision, storedAt: DateTime.now(), shelf: shelf);
      unawaited(_storeSnapshot(access, revision, raw));
      return shelf;
    } catch (error) {
      if (access.revision != revision || !identical(access, YoutubeAccessService.active)) rethrow;
      final failure = error is YoutubeFailure ? error : YoutubeFailureClassifier.classify(error, authenticated: true);
      access.observeFailure(failure);
      throw failure;
    }
  }

  Future<void> _storeSnapshot(YoutubeAccessService access, int revision, String raw) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (access.revision != revision || !_available(access) || !identical(access, YoutubeAccessService.active)) return;
      await prefs.setString(
        _snapshotKey,
        jsonEncode({
          'identity': _identity(access),
          'storedAt': DateTime.now().toIso8601String(),
          'data': jsonDecode(raw),
        }),
      );
    } catch (_) {
      // Disk caching cannot hold up library browsing.
    }
  }

  YoutubeMusicHomeShelf decodeResponse(String raw) {
    final payload = jsonDecode(raw);
    if (payload is! Map || payload['shelves'] is! List) {
      throw const FormatException('Invalid playlist library response.');
    }
    final home = const YoutubeMusicHomeService().decodeResponse(raw);
    final items = <YoutubeMusicHomeItem>[];
    final seen = <String>{};
    for (final shelf in home.shelves) {
      for (final item in shelf.items) {
        final url = item.playlistUrl;
        if (url != null && seen.add(url)) items.add(item);
      }
    }
    return YoutubeMusicHomeShelf(title: 'Playlist Library', tracks: const [], items: List.unmodifiable(items));
  }
}
