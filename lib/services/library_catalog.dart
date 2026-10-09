import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'metadata_cache_service.dart';

class LibraryTrack {
  const LibraryTrack({
    required this.id,
    required this.path,
    required this.title,
    required this.artist,
    this.album = '',
    this.albumArtist = '',
    this.durationSeconds,
    this.trackNumber,
    this.artwork,
    this.addedAt,
    this.favorite = false,
    this.available = false,
    this.playlists = const {},
  });
  final String id, path, title, artist, album, albumArtist;
  final int? durationSeconds, trackNumber;
  final String? artwork;
  final DateTime? addedAt;
  final bool favorite, available;
  final Set<int> playlists;
  bool get stream => path.startsWith('http://') || path.startsWith('https://');
  String get albumKey =>
      album.isEmpty ? 'folder:${p.dirname(path)}' : '${albumArtist.isEmpty ? artist : albumArtist}\u0000$album';
}

/// Bounded local metadata indexing, shared by album browsing and rule previews.
class LibraryCatalog extends ChangeNotifier {
  LibraryCatalog({FileService? files}) : files = files ?? FileService();
  final FileService files;
  static const datesKey = 'library_added_dates_v1';
  static const metadataKey = 'library_album_metadata_v1';
  List<LibraryTrack> tracks = const [];
  bool loading = false;
  Object? error;
  int revision = 0;
  Future<void>? _pending;
  bool _disposed = false, _dirty = false;
  StreamSubscription<Object?>? _subscription;
  void start() {
    _subscription ??= FileService.mutations.listen((_) {
      revision++;
      unawaited(refresh());
    });
    unawaited(refresh());
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_pending != null) {
      _dirty = true;
      return _pending!;
    }
    final task = _refreshUntilCurrent();
    _pending = task;
    return task.whenComplete(() {
      _pending = null;
    });
  }

  Future<void> _refreshUntilCurrent() async {
    do {
      _dirty = false;
      await _load();
    } while (_dirty && !_disposed);
  }

  Future<void> _load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final sources = await files.favoriteSourceIds();
      final dates = decodeMap(prefs.getString(datesKey));
      final cached = decodeMap(prefs.getString(metadataKey));
      final members = <String, Set<int>>{};
      for (final number in await files.listPlaylistNumbers()) {
        for (final path in await files.readPlaylistTracks(number)) {
          members.putIfAbsent(path, () => {}).add(number);
        }
      }
      final favoriteIds = <String>{
        for (final entry in members.entries)
          if (entry.value.contains(0)) files.favoriteIdentity(entry.key, sourceIds: sources),
      };
      final result = <String, LibraryTrack>{};
      var processed = 0;
      for (final entry in members.entries) {
        final path = entry.key;
        final id = files.favoriteIdentity(path, sourceIds: sources);
        final stream = path.startsWith('http://') || path.startsWith('https://');
        final exists = !stream && await File(path).exists();
        Map<String, dynamic> tags = cached[path] is Map ? Map<String, dynamic>.from(cached[path] as Map) : {};
        if (exists) {
          final modified = (await File(path).lastModified()).millisecondsSinceEpoch;
          if (tags['modified'] != modified) {
            try {
              final metadata = await MetadataGod.readMetadata(file: path);
              tags = {
                'modified': modified,
                'title': metadata.title,
                'artist': metadata.artist,
                'album': metadata.album,
                'albumArtist': metadata.albumArtist,
                'duration': metadata.durationMs == null ? null : (metadata.durationMs! / 1000).round(),
                'trackNumber': metadata.trackNumber,
              };
              cached[path] = tags;
            } catch (_) {
              /* Missing tags fall back to filename/folder. */
              tags = {'modified': modified};
              cached[path] = tags;
            }
          }
        }
        final quick = await MetadataCacheService.get(path);
        final title = '${tags['title'] ?? quick?.title ?? p.basenameWithoutExtension(path)}';
        final artist = '${tags['artist'] ?? quick?.artist ?? 'Unknown artist'}';
        final previous = result[id];
        final playlists = {...entry.value, ...?previous?.playlists};
        final preferredPath = previous != null && previous.available && !exists ? previous.path : path;
        final track = LibraryTrack(
          id: id,
          path: preferredPath,
          title: title,
          artist: artist,
          album: '${tags['album'] ?? ''}',
          albumArtist: '${tags['albumArtist'] ?? ''}',
          durationSeconds: (tags['duration'] as num?)?.toInt(),
          trackNumber: (tags['trackNumber'] as num?)?.toInt(),
          artwork: quick?.artworkUrl ?? previous?.artwork,
          addedAt: DateTime.tryParse('${dates[id] ?? ''}'),
          favorite: favoriteIds.contains(id),
          available: exists || previous?.available == true,
          playlists: playlists,
        );
        result[id] = previous != null && previous.available && !exists
            ? LibraryTrack(
                id: previous.id,
                path: previous.path,
                title: previous.title,
                artist: previous.artist,
                album: previous.album,
                albumArtist: previous.albumArtist,
                durationSeconds: previous.durationSeconds,
                trackNumber: previous.trackNumber,
                artwork: previous.artwork,
                addedAt: previous.addedAt,
                favorite: track.favorite,
                available: true,
                playlists: playlists,
              )
            : track;
        if (++processed % 20 == 0) {
          if (_disposed) return;
          tracks = result.values.toList();
          notifyListeners();
          await Future<void>.delayed(Duration.zero);
        }
      }
      await prefs.setString(metadataKey, jsonEncode(cached));
      if (_disposed) return;
      tracks = result.values.toList();
      revision++;
    } catch (failure) {
      error = failure;
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  static Map<String, dynamic> decodeMap(String? raw) {
    try {
      final value = jsonDecode(raw ?? '{}');
      return value is Map ? Map<String, dynamic>.from(value) : {};
    } catch (_) {
      return {};
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
