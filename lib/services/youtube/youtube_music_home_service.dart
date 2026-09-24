import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/core/youtube/youtube_music_home_models.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/services/youtube/windows_ytmusic_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Retrieves the authenticated YouTube Music home feed through the native
/// cookie boundary on Android or the packaged helper on Windows.
class YoutubeMusicHomeService {
  static const _androidChannel = MethodChannel('resonance/android_youtube');
  static const _cacheTtl = Duration(minutes: 3);
  static const _diskCacheTtl = Duration(hours: 24);
  static const _diskCacheKey = 'youtube_music_home.snapshot_v1';
  static ({YoutubeAccessService access, int revision, int limit, DateTime storedAt, YoutubeMusicHome home})?
  _cachedHome;
  static final Map<String, Future<YoutubeMusicHome>> _requestsInFlight = {};

  const YoutubeMusicHomeService();

  /// A previously viewed Home can paint immediately while a live refresh runs.
  /// Only normalized shelf data is stored; browser cookies stay native-side.
  Future<YoutubeMusicHome?> loadCached() async {
    final access = YoutubeAccessService.active;
    if (access == null || !_canUseHome(access)) return null;
    final memory = _cachedHome;
    if (memory != null &&
        identical(memory.access, access) &&
        memory.revision == access.revision &&
        DateTime.now().difference(memory.storedAt) < _diskCacheTtl) {
      return memory.home;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_diskCacheKey);
      if (raw == null) return null;
      final snapshot = jsonDecode(raw);
      if (snapshot is! Map || snapshot['identity'] != _cacheIdentity(access)) return null;
      final storedAt = DateTime.tryParse(snapshot['storedAt']?.toString() ?? '');
      if (storedAt == null || DateTime.now().difference(storedAt) >= _diskCacheTtl) return null;
      final payload = snapshot['home'];
      if (payload is! Map) return null;
      final home = decodeResponse(jsonEncode(payload));
      if (home.isEmpty) return null;
      _cachedHome = (
        access: access,
        revision: access.revision,
        limit: snapshot['limit'] is int ? snapshot['limit'] as int : 24,
        storedAt: storedAt,
        home: home,
      );
      return home;
    } catch (_) {
      return null;
    }
  }

  bool _canUseHome(YoutubeAccessService access) =>
      access.isConfigured &&
      access.status.state != YoutubeAccessState.rejected &&
      access.status.state != YoutubeAccessState.verificationRequired &&
      access.status.state != YoutubeAccessState.unavailable;

  String _cacheIdentity(YoutubeAccessService access) => [
    access.status.method.name,
    access.status.browserId ?? '',
    access.windowsCookiePath ?? '',
    access.status.configuredAt?.toUtc().toIso8601String() ?? '',
  ].join('|');

  Future<void> _storeCachedRaw(YoutubeAccessService access, String raw, int limit) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _diskCacheKey,
        jsonEncode({
          'identity': _cacheIdentity(access),
          'storedAt': DateTime.now().toIso8601String(),
          'limit': limit,
          'home': jsonDecode(raw),
        }),
      );
    } catch (_) {
      // A disk cache failure must never hold up Home.
    }
  }

  Future<void> testWindowsAccess(String browserSource) async {
    final raw = await _fetchWindows(1, overrideBrowserSource: browserSource);
    if (decodeResponse(raw).isEmpty) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.sessionRejected,
        userMessage: 'The selected browser profile did not return an authenticated YouTube Music home.',
      );
    }
  }

  Future<YoutubeMusicHome> fetch({int limit = 24, bool forceRefresh = false}) async {
    final access = YoutubeAccessService.active;
    if (access == null || !_canUseHome(access)) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.verificationRequired,
        userMessage: 'Connect YouTube access to view your YouTube Music home.',
      );
    }
    final requestedLimit = limit.clamp(1, 80);
    final cached = _cachedHome;
    if (!forceRefresh &&
        cached != null &&
        identical(cached.access, access) &&
        cached.revision == access.revision &&
        cached.limit == requestedLimit &&
        DateTime.now().difference(cached.storedAt) < _cacheTtl) {
      return cached.home;
    }
    final key = '${identityHashCode(access)}:${access.revision}:$requestedLimit';
    var pending = _requestsInFlight[key];
    if (pending == null) {
      pending = _fetchFresh(access, requestedLimit);
      _requestsInFlight[key] = pending;
    }
    try {
      return await pending;
    } finally {
      if (identical(_requestsInFlight[key], pending)) _requestsInFlight.remove(key);
    }
  }

  Future<YoutubeMusicHome> _fetchFresh(YoutubeAccessService access, int limit) async {
    try {
      final raw = Platform.isAndroid
          ? await _androidChannel.invokeMethod<String>('getMusicHome', {'limit': limit})
          : Platform.isWindows
          ? await _fetchWindows(limit)
          : throw const YoutubeFailure(
              kind: YoutubeFailureKind.unsupported,
              userMessage: 'YouTube Music home is available on Windows and Android only.',
            );
      if (raw == null || raw.trim().isEmpty) throw StateError('YouTube Music returned an empty home feed.');
      final home = decodeResponse(raw);
      await access.recordAuthenticatedSuccess();
      _cachedHome = (access: access, revision: access.revision, limit: limit, storedAt: DateTime.now(), home: home);
      if (!home.isEmpty) unawaited(_storeCachedRaw(access, raw, limit));
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
    return const WindowsYtMusicHelper().invoke(
      action: 'home',
      limit: limit,
      overrideBrowserSource: overrideBrowserSource,
    );
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
