import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:path/path.dart' as p;
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';

/// The car browses the same numbered playlists as the phone. IDs refer to a
/// the source path, so reordering a playlist cannot play the wrong song from a
/// stale car selection. Every selection is checked against disk again.
class AndroidAutoCatalog {
  static const playlistPrefix = 'resonance:playlist:';
  static const trackPrefix = 'resonance:track:';

  final FileService files;

  AndroidAutoCatalog({FileService? files}) : files = files ?? FileService();

  static String playlistId(int number) => '$playlistPrefix$number';
  static String trackId(int number, String source, {int occurrence = 0}) =>
      '$trackPrefix$number:${base64Url.encode(utf8.encode(source))}:$occurrence';

  static ({int playlist, String source, int occurrence})? parseTrackId(String id) {
    final match = RegExp(r'^resonance:track:(\d+):([A-Za-z0-9_-]+={0,2}):(\d+)$').firstMatch(id);
    if (match == null) return null;
    final playlist = int.tryParse(match[1]!);
    final occurrence = int.tryParse(match[3]!);
    if (playlist == null || playlist < 1 || occurrence == null) return null;
    try {
      final source = utf8.decode(base64Url.decode(base64Url.normalize(match[2]!)));
      if (source.isEmpty) return null;
      return (playlist: playlist, source: source, occurrence: occurrence);
    } catch (_) {
      return null;
    }
  }

  Future<List<MediaItem>> children(String parentId) async {
    if (parentId == AudioService.browsableRootId || parentId == AudioService.recentRootId) {
      final names = await files.getPlaylistNames();
      return [
        for (final number in await files.listPlaylistNumbers())
          MediaItem(
            id: playlistId(number),
            title: names[number] ?? 'Playlist $number',
            playable: false,
            extras: const {AndroidContentStyle.browsableHintKey: AndroidContentStyle.listItemHintValue},
          ),
      ];
    }
    if (!parentId.startsWith(playlistPrefix)) return const [];
    final number = int.tryParse(parentId.substring(playlistPrefix.length));
    if (number == null || number < 1 || !(await files.listPlaylistNumbers()).contains(number)) return const [];
    final tracks = await files.readPlaylistTracks(number);
    final occurrences = <String, int>{};
    final items = <Future<MediaItem>>[];
    for (final track in tracks) {
      final occurrence = occurrences.update(track, (count) => count + 1, ifAbsent: () => 0);
      items.add(_trackItem(number, track, occurrence: occurrence));
    }
    return Future.wait(items);
  }

  Future<MediaItem?> track(String id) async {
    final location = await resolve(id);
    if (location == null) return null;
    final parsed = parseTrackId(id)!;
    return _trackItem(location.playlist, location.path, occurrence: parsed.occurrence);
  }

  Future<MediaItem?> item(String id) async {
    if (id.startsWith(playlistPrefix)) {
      final root = await children(AudioService.browsableRootId);
      for (final playlist in root) {
        if (playlist.id == id) return playlist;
      }
      return null;
    }
    return track(id);
  }

  Future<MediaItem> _trackItem(int playlist, String path, {required int occurrence}) async {
    final cached = await MetadataCacheService.get(path);
    final isStream = path.startsWith('http://') || path.startsWith('https://');
    return MediaItem(
      id: trackId(playlist, path, occurrence: occurrence),
      title: cached?.title ?? (isStream ? 'YouTube stream' : p.basenameWithoutExtension(path)),
      artist: cached?.artist ?? (isStream ? 'YouTube' : 'Unknown Artist'),
      artUri: cached?.artworkUrl == null ? null : Uri.tryParse(cached!.artworkUrl!),
      extras: const {AndroidContentStyle.playableHintKey: AndroidContentStyle.listItemHintValue},
    );
  }

  Future<({int playlist, int index, String path})?> resolve(String id) async {
    final location = parseTrackId(id);
    if (location == null || !(await files.listPlaylistNumbers()).contains(location.playlist)) return null;
    final tracks = await files.readPlaylistTracks(location.playlist);
    var index = -1;
    var seen = 0;
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i] != location.source) continue;
      if (seen++ == location.occurrence) {
        index = i;
        break;
      }
    }
    if (index < 0) return null;
    final path = tracks[index];
    if (!path.startsWith('http://') && !path.startsWith('https://') && !await File(path).exists()) return null;
    return (playlist: location.playlist, index: index, path: path);
  }
}
