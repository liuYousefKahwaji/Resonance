import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:resonance/models/track_source_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TrackSourceRepository {
  static const String storageKey = 'resonance_track_sources_v1';
  static final RegExp youtubeVideoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

  final SharedPreferences? _preferences;
  final bool? _isWindowsOverride;

  const TrackSourceRepository({SharedPreferences? preferences, bool? isWindowsOverride})
    : _preferences = preferences,
      _isWindowsOverride = isWindowsOverride;

  static String canonicalUrlFor(String videoId) => 'https://www.youtube.com/watch?v=$videoId';

  static bool isValidYoutubeVideoId(String value) => youtubeVideoIdPattern.hasMatch(value);

  static String? videoIdFromUrlOrId(String value) {
    final trimmed = value.trim();
    if (isValidYoutubeVideoId(trimmed)) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) return null;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    String? candidate;
    if (host == 'youtu.be') {
      candidate = uri.pathSegments.firstOrNull;
    } else if (host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtube-nocookie.com' ||
        host.endsWith('.youtube-nocookie.com')) {
      candidate = uri.queryParameters['v'];
      if (candidate == null && uri.pathSegments.length >= 2) {
        final kind = uri.pathSegments.first;
        if (kind == 'shorts' || kind == 'embed' || kind == 'live') {
          candidate = uri.pathSegments[1];
        }
      }
    }
    return candidate != null && isValidYoutubeVideoId(candidate) ? candidate : null;
  }

  Future<TrackSourceRecord?> getSourceForTrack(String localPath) async {
    final records = await _loadRecords();
    final record = records[_trackKey(localPath)];
    return record != null && isValidYoutubeVideoId(record.youtubeVideoId) ? record : null;
  }

  Future<TrackSourceRecord?> getSourceForYoutubeId(String videoId) async {
    if (!isValidYoutubeVideoId(videoId)) return null;
    final records = await _loadRecords();
    for (final record in records.values) {
      if (record.youtubeVideoId == videoId) return record;
    }
    return null;
  }

  Future<String?> findLocalTrackByYoutubeId(String videoId) async {
    final record = await getSourceForYoutubeId(videoId);
    if (record == null || _isNetworkUrl(record.localPath)) return null;
    final file = File(record.localPath);
    if (!await file.exists()) return null;
    await saveSource(
      localPath: file.path,
      youtubeVideoId: videoId,
      method: record.method,
      createdAt: record.createdAt,
      lastVerifiedAt: DateTime.now().toUtc(),
    );
    return file.path;
  }

  Future<TrackSourceRecord> saveSource({
    required String localPath,
    required String youtubeVideoId,
    required TrackSourceMethod method,
    DateTime? createdAt,
    DateTime? lastVerifiedAt,
  }) async {
    if (!isValidYoutubeVideoId(youtubeVideoId)) {
      throw ArgumentError.value(youtubeVideoId, 'youtubeVideoId', 'Invalid YouTube video ID');
    }
    final records = await _loadRecords();
    final key = _trackKey(localPath);
    TrackSourceRecord? previous = records[key];
    for (final entry in records.entries.toList()) {
      if (entry.value.youtubeVideoId == youtubeVideoId && entry.key != key) {
        previous ??= entry.value;
        records.remove(entry.key);
      }
    }
    final record = TrackSourceRecord(
      localTrackKey: key,
      localPath: localPath,
      youtubeVideoId: youtubeVideoId,
      canonicalUrl: canonicalUrlFor(youtubeVideoId),
      method: method,
      createdAt: createdAt ?? previous?.createdAt ?? DateTime.now().toUtc(),
      lastVerifiedAt: lastVerifiedAt ?? previous?.lastVerifiedAt,
    );
    records[key] = record;
    await _saveRecords(records);
    return record;
  }

  Future<void> removeInvalidMapping(String localPath) async {
    final records = await _loadRecords();
    if (records.remove(_trackKey(localPath)) != null) await _saveRecords(records);
  }

  Future<Map<String, TrackSourceRecord>> _loadRecords() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final records = <String, TrackSourceRecord>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map) continue;
        final record = TrackSourceRecord.fromJson(Map<String, dynamic>.from(entry.value as Map));
        if (record.localPath.isNotEmpty && isValidYoutubeVideoId(record.youtubeVideoId)) {
          records[entry.key] = record;
        }
      }
      return records;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveRecords(Map<String, TrackSourceRecord> records) async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(records.map((key, value) => MapEntry(key, value.toJson()))));
  }

  String _trackKey(String value) {
    final trimmed = value.trim();
    if (_isNetworkUrl(trimmed)) return trimmed;
    final normalized = p.normalize(p.absolute(trimmed));
    return (_isWindowsOverride ?? Platform.isWindows) ? normalized.toLowerCase() : normalized;
  }

  static bool _isNetworkUrl(String value) => value.startsWith('http://') || value.startsWith('https://');
}
