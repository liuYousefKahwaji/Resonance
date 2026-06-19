import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Cached metadata for a single track.
class CachedTrackMetadata {
  final String title;
  final String artist;

  const CachedTrackMetadata({required this.title, required this.artist});
}

/// Caches extracted track metadata (title/artist) so the library list
/// doesn't need to re-run [AudioMetadata.extract] (which hits the disk
/// and parses file headers) every time a TrackTile is rebuilt - e.g. when
/// scrolling a ListView.builder that recycles widgets.
///
/// Entries are keyed by file path and validated against the file's last
/// modified time, so if a file is replaced/re-tagged, the cache is
/// automatically invalidated for that entry.
///
/// Storage: a single JSON blob in SharedPreferences. Simple, and plenty
/// fast for a personal library (hundreds to a few thousand tracks).
class MetadataCacheService {
  static const String _prefsKey = 'track_metadata_cache_v1';

  // In-memory mirror so repeated lookups during a scroll session don't
  // even need to touch SharedPreferences.
  static Map<String, dynamic>? _cache;
  static Future<void>? _loadingFuture;

  static Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    if (_loadingFuture != null) {
      await _loadingFuture;
      return;
    }

    _loadingFuture = () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_prefsKey);
        if (raw != null) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            _cache = decoded;
            return;
          }
        }
      } catch (_) {
        // Corrupted cache - start fresh rather than crashing.
      }
      _cache = {};
    }();

    await _loadingFuture;
  }

  static Future<void> _persist() async {
    if (_cache == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_cache));
    } catch (_) {
      // Non-fatal: worst case, the cache just isn't persisted this run.
    }
  }

  /// Returns cached metadata for [filePath] if present and still valid
  /// (i.e. the file's last-modified time hasn't changed since caching).
  /// Returns null on cache miss or invalidation - caller should extract
  /// fresh metadata and call [set].
  static Future<CachedTrackMetadata?> get(String filePath) async {
    await _ensureLoaded();
    final entry = _cache![filePath];
    if (entry == null || entry is! Map) return null;

    try {
      final cachedMtime = entry['mtime'] as int?;
      final currentMtime = (await File(filePath).lastModified()).millisecondsSinceEpoch;
      if (cachedMtime == null || cachedMtime != currentMtime) {
        return null;
      }
    } catch (_) {
      // If we can't stat the file, don't trust the cache.
      return null;
    }

    final title = entry['title'] as String?;
    final artist = entry['artist'] as String?;
    if (title == null || artist == null) return null;

    return CachedTrackMetadata(title: title, artist: artist);
  }

  /// Stores metadata for [filePath], tagged with the file's current
  /// last-modified time for future invalidation checks.
  static Future<void> set(String filePath, String title, String artist) async {
    await _ensureLoaded();

    int mtime;
    try {
      mtime = (await File(filePath).lastModified()).millisecondsSinceEpoch;
    } catch (_) {
      mtime = 0;
    }

    _cache![filePath] = {
      'title': title,
      'artist': artist,
      'mtime': mtime,
    };

    await _persist();
  }

  /// Removes a single entry (e.g. when a track is deleted from the library).
  static Future<void> remove(String filePath) async {
    await _ensureLoaded();
    if (_cache!.remove(filePath) != null) {
      await _persist();
    }
  }

  /// Clears the entire cache. Useful for a "rescan library" settings option.
  static Future<void> clear() async {
    _cache = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }
}
