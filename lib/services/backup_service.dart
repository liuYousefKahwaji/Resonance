import 'dart:convert';
import 'package:resonance/core/audio/playback_range.dart';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/smart_playlist.dart';
import 'listening_statistics.dart';

enum BackupMode { settings, everything }

class BackupPreview {
  const BackupPreview(this.manifest, this.bytes, this.unresolved);
  final Map<String, dynamic> manifest;
  final int bytes, unresolved;
  int get playlistCount => (manifest['playlists'] as List).length;
  int get audioCount => (manifest['audio'] as List).length;
}

/// Portable whitelist-based backup. Authentication and pairing never cross devices.
class BackupService {
  BackupService({FileService? files, String? supportDirectory})
    : files = files ?? FileService(),
      _supportDirectory = supportDirectory;
  final FileService files;
  final String? _supportDirectory;
  static const settingsKeys = {
    'is_dark_mode',
    'theme_style',
    'theme_custom_color',
    'theme_full_palette',
    'rounder_corners',
    'windows_native_controls',
    'listening_focus',
    'artwork_player_colors',
    'app_language',
    'intro_enabled',
    'seek_step_seconds',
    'playback_settings_scope',
    'crossfade_enabled',
    'crossfade_duration_seconds',
    'resume_long_tracks',
    'last_volume',
    'last_speed',
    'last_pitch',
    'last_equalizer_settings_v1',
    'last_bass_boost',
    'last_loop_mode',
    'last_shuffle',
    'volume_normalization_enabled',
    'lyrics_animation_fps',
    'track_list_motion_blur',
    'discord_enabled',
    'saved_hotkeys',
    'tray_mode',
    'listening_statistics_enabled',
  };
  static const dataKeys = {
    'long_track_positions_v1',
    'per_track_playback_settings_v2',
    'per_track_playback_ranges_v1',
    'resonance_track_sources_v1',
    'track_metadata_cache_v2',
    'library_album_metadata_v1',
    'library_added_dates_v1',
    'resonance_listening_history_v1',
    'download_history_v1',
    'listening_statistics_v1',
    'smart_playlists_v1',
  };
  static bool allowedKey(String key) => settingsKeys.contains(key) || dataKeys.contains(key);
  Future<BackupPreview> previewExport(BackupMode mode, {bool includeAudio = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = {...settingsKeys, if (mode == BackupMode.everything) ...dataKeys};
    final playlists = <Map<String, dynamic>>[];
    final audio = <Map<String, dynamic>>[];
    var bytes = 0, missing = 0;
    if (mode == BackupMode.everything) {
      final names = await files.getPlaylistNames();
      final localPaths = <String>{};
      for (final number in await files.listPlaylistNumbers()) {
        final tracks = await files.readPlaylistTracks(number);
        playlists.add({
          'number': number,
          'name': names[number],
          'tracks': tracks,
          'sort': (await files.playlistSortState(number)).toJson(),
        });
        localPaths.addAll(tracks.where((path) => !path.startsWith('http')));
      }
      for (final path in localPaths) {
        if (!await File(path).exists()) {
          missing++;
          continue;
        }
        final size = await File(path).length();
        if (includeAudio) {
          audio.add({'path': path, 'entry': 'audio/${audio.length}${p.extension(path).toLowerCase()}', 'size': size});
          bytes += size;
        } else {
          missing++;
        }
      }
    }
    final manifest = <String, dynamic>{
      'format': 'resonance-backup',
      'schema': 1,
      'mode': mode.name,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
      'settings': {
        for (final key in keys)
          if (prefs.containsKey(key)) key: prefs.get(key),
      },
      'playlists': playlists,
      'audio': audio,
      'activePlaylist': await files.getActivePlaylistNumber(),
    };
    bytes += utf8.encode(jsonEncode(manifest)).length;
    return BackupPreview(manifest, bytes, missing);
  }

  Future<void> export(String destination, BackupPreview preview, {void Function(int, int)? onProgress}) async {
    final manifest = jsonDecode(jsonEncode(preview.manifest)) as Map<String, dynamic>;
    final encoder = ZipFileEncoder()..create('$destination.part');
    try {
      final audio = manifest['audio'] as List;
      for (var index = 0; index < audio.length; index++) {
        final item = audio[index] as Map;
        final file = File(item['path'] as String);
        if (!await file.exists() || await file.length() != item['size']) {
          throw StateError('An audio file changed during backup');
        }
        item['sha256'] = (await sha256.bind(file.openRead()).first).toString();
        await encoder.addFile(file, item['entry'] as String, ZipFileEncoder.store);
        onProgress?.call(index + 1, audio.length);
      }
      final bytes = utf8.encode(jsonEncode(manifest));
      encoder.addArchiveFile(ArchiveFile('manifest.json', bytes.length, bytes));
    } finally {
      await encoder.close();
    }
    await File('$destination.part').rename(destination);
  }

  BackupPreview inspect(String source) {
    final input = InputFileStream(source);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final names = <String>{};
      var total = 0;
      for (final entry in archive) {
        if (!entry.isFile ||
            entry.isSymbolicLink ||
            !names.add(entry.name) ||
            entry.name.contains('\\') ||
            entry.name.startsWith('/') ||
            entry.name.split('/').any((part) => part == '..' || part.isEmpty) ||
            !(entry.name == 'manifest.json' || RegExp(r'^audio/\d+\.[a-z0-9]+$').hasMatch(entry.name))) {
          throw const FormatException('Invalid backup file entry');
        }
        total += entry.size;
        if (entry.size > 4 * 1024 * 1024 * 1024 || total > 200 * 1024 * 1024 * 1024 || names.length > 100001) {
          throw const FormatException('Backup exceeds supported limits');
        }
      }
      final json = archive.findFile('manifest.json');
      if (json == null || json.size > 16 * 1024 * 1024) {
        throw const FormatException('Backup manifest missing or too large');
      }
      final manifest = jsonDecode(utf8.decode(json.content)) as Map<String, dynamic>;
      validateManifest(manifest);
      final declared = <String>{'manifest.json'};
      for (final raw in manifest['audio'] as List) {
        final entry = raw as Map;
        if (!declared.add(entry['entry'] as String)) throw const FormatException('Duplicate audio entry');
        final actual = archive.findFile(entry['entry'] as String);
        if (actual == null || actual.size != entry['size']) {
          throw const FormatException('Missing or invalid audio file');
        }
      }
      if (names.length != declared.length) throw const FormatException('Undeclared backup entries');
      final backed = (manifest['audio'] as List).map((entry) => (entry as Map)['path']).toSet();
      final missing = <String>{
        for (final playlist in manifest['playlists'] as List)
          for (final path in (playlist as Map)['tracks'] as List)
            if (!(path as String).startsWith('http') && !backed.contains(path) && !File(path).existsSync()) path,
      };
      return BackupPreview(manifest, total, missing.length);
    } finally {
      input.closeSync();
    }
  }

  static void validateManifest(Map<String, dynamic> manifest) {
    if (manifest['format'] != 'resonance-backup' ||
        manifest['schema'] != 1 ||
        !['settings', 'everything'].contains(manifest['mode']) ||
        manifest['settings'] is! Map ||
        manifest['playlists'] is! List ||
        manifest['audio'] is! List) {
      throw const FormatException('Unsupported backup format');
    }
    if ((manifest['mode'] == 'settings') &&
        ((manifest['playlists'] as List).isNotEmpty || (manifest['audio'] as List).isNotEmpty)) {
      throw const FormatException('Settings backup contains library data');
    }
    for (final entry in (manifest['settings'] as Map).entries) {
      if (entry.key is! String ||
          !allowedKey(entry.key as String) ||
          !(entry.value is String ||
              entry.value is bool ||
              entry.value is int ||
              entry.value is double ||
              entry.value is List && (entry.value as List).every((value) => value is String))) {
        throw const FormatException('Invalid or non-portable preference');
      }
      if (manifest['mode'] == 'settings' && !settingsKeys.contains(entry.key)) {
        throw const FormatException('Unexpected library setting');
      }
      if (dataKeys.contains(entry.key)) {
        if (entry.value is! String) throw const FormatException('Invalid library preference');
        final value = jsonDecode(entry.value as String);
        if (entry.key == 'smart_playlists_v1') {
          if (value is! List) throw const FormatException('Invalid smart playlists');
          for (final item in value) {
            SmartPlaylist.fromJson(Map<String, dynamic>.from(item as Map));
          }
        } else if (entry.key == 'resonance_listening_history_v1' || entry.key == 'download_history_v1') {
          if (value is! List) throw const FormatException('Invalid history');
        } else if (value is! Map) {
          throw const FormatException('Invalid library data');
        }
        if (entry.key == 'per_track_playback_ranges_v1' &&
            (!(value as Map).keys.every((key) => key is String && !key.startsWith('http')) ||
                !value.values.every(PlaybackRange.validJson))) {
          throw const FormatException('Invalid playback ranges');
        }
        if (entry.key == ListeningStatistics.storageKey) ListeningStatistics.validateData(value as Map);
      }
    }
    final numbers = <int>{};
    for (final value in manifest['playlists'] as List) {
      if (value is! Map ||
          value['number'] is! int ||
          (value['number'] as int) < 0 ||
          !numbers.add(value['number'] as int) ||
          value['name'] is! String ||
          value['tracks'] is! List ||
          !(value['tracks'] as List).every(
            (path) => path is String && path.isNotEmpty && !path.contains('\n') && !path.contains('\r'),
          )) {
        throw const FormatException('Invalid playlist');
      }
    }
    for (final value in manifest['audio'] as List) {
      if (value is! Map ||
          value['path'] is! String ||
          value['entry'] is! String ||
          value['size'] is! int ||
          !RegExp(r'^audio/\d+\.[a-z0-9]+$').hasMatch(value['entry'] as String) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch('${value['sha256']}')) {
        throw const FormatException('Invalid audio manifest');
      }
    }
  }

  Future<void> restore(String source, {required bool replace, String? relinkFolder}) async {
    final preview = inspect(source);
    final manifest = preview.manifest;
    final prefs = await SharedPreferences.getInstance();
    final snapshot = {
      for (final key in {...settingsKeys, ...dataKeys, 'resonance_playlist_names', 'active_resonance_playlist'})
        key: prefs.get(key),
    };
    final docs = await files.documentsDirectory;
    final originals = <String, List<int>>{};
    await for (final entry in Directory(docs).list()) {
      if (entry is File && RegExp(r'^r_playlist_\d+\.m3u8(?:\.sort\.json)?$').hasMatch(p.basename(entry.path))) {
        originals[entry.path] = await entry.readAsBytes();
      }
    }
    final support = _supportDirectory ?? (await getApplicationSupportDirectory()).path;
    final staging = await Directory(
      p.join(support, 'RestoredAudio', '${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true);
    final paths = <String, String>{};
    final existingAudio = <String>{};
    for (final number in await files.listPlaylistNumbers()) {
      existingAudio.addAll((await files.readPlaylistTracks(number)).where((path) => !path.startsWith('http')));
    }
    final knownHashes = <String, String>{};
    final input = InputFileStream(source);
    try {
      final archive = ZipDecoder().decodeStream(input);
      for (final raw in manifest['audio'] as List) {
        final entry = raw as Map;
        final outputPath = p.join(staging.path, p.basename(entry['entry'] as String));
        final output = OutputFileStream(outputPath);
        try {
          archive.findFile(entry['entry'] as String)!.writeContent(output);
        } finally {
          await output.close();
        }
        final file = File(outputPath);
        if (await file.length() != entry['size'] ||
            (await sha256.bind(file.openRead()).first).toString() != entry['sha256']) {
          throw const FormatException('Backup audio verification failed');
        }
        final original = entry['path'] as String;
        // Keep an existing identical file rather than creating a second copy.
        String? reusable;
        for (final candidate in {original, ...existingAudio, ...paths.values}) {
          final candidateFile = File(candidate);
          if (!await candidateFile.exists() || await candidateFile.length() != entry['size']) continue;
          final hash = knownHashes[candidate] ??= (await sha256.bind(candidateFile.openRead()).first).toString();
          if (hash == entry['sha256']) {
            reusable = candidate;
            break;
          }
        }
        if (reusable != null) {
          paths[original] = reusable;
          await file.delete();
        } else {
          paths[original] = outputPath;
        }
      }
      if (relinkFolder != null) {
        final candidates = <String, List<String>>{};
        await for (final entry in Directory(relinkFolder).list(recursive: true, followLinks: false)) {
          if (entry is File) candidates.putIfAbsent(p.basename(entry.path).toLowerCase(), () => []).add(entry.path);
        }
        for (final playlist in manifest['playlists'] as List) {
          for (final path in (playlist as Map)['tracks'] as List) {
            if (!(path as String).startsWith('http') && !paths.containsKey(path) && !await File(path).exists()) {
              final matches = candidates[p.basename(path.replaceAll('\\', '/')).toLowerCase()];
              if (matches?.length == 1) paths[path] = matches!.single;
            }
          }
        }
      }
      final numberMap = <int, int>{0: 0};
      var changed = false;
      try {
        changed = true;
        if (replace && manifest['mode'] == 'everything') {
          for (final key in dataKeys) {
            await prefs.remove(key);
          }
          for (final number in (await files.listPlaylistNumbers()).reversed) {
            if (number > 1) await files.deletePlaylist(number);
          }
          await files.replacePlaylistTracks(0, []);
          await files.replacePlaylistTracks(1, []);
        }
        var usedPrimary = false;
        for (final raw in manifest['playlists'] as List) {
          final playlist = raw as Map;
          final oldNumber = playlist['number'] as int;
          final tracks = (playlist['tracks'] as List).cast<String>().map((path) => paths[path] ?? path).toList();
          int number;
          if (oldNumber == 0) {
            number = 0;
            await files.setTracksFavorite(tracks, true);
          } else if (replace && !usedPrimary) {
            usedPrimary = true;
            number = 1;
            await files.renamePlaylist(number, playlist['name'] as String);
            await files.replacePlaylistTracks(number, tracks);
          } else {
            int? duplicate;
            if (!replace) {
              final names = await files.getPlaylistNames();
              for (final entry in names.entries) {
                if (entry.key == 0 || entry.value != playlist['name']) continue;
                final existing = await files.readPlaylistTracks(entry.key);
                if (existing.length == tracks.length &&
                    List.generate(
                      tracks.length,
                      (index) => files.sameTrackPath(existing[index], tracks[index]),
                    ).every((value) => value)) {
                  duplicate = entry.key;
                  break;
                }
              }
            }
            number = duplicate ?? (await files.createImportedPlaylist(playlist['name'] as String, tracks)).number;
          }
          numberMap[oldNumber] = number;
          final sort = playlist['sort'];
          if (sort is Map) {
            final state = PlaylistSortState.fromJson(Map<String, dynamic>.from(sort));
            await files.restorePlaylistSortState(
              number,
              state.copyWith(addedOrder: state.addedOrder.map((path) => paths[path] ?? path).toList()),
              tracks: tracks,
            );
          }
        }
        for (final entry in (manifest['settings'] as Map).entries) {
          final key = entry.key as String;
          if (Platform.isAndroid &&
              {'windows_native_controls', 'discord_enabled', 'saved_hotkeys', 'tray_mode'}.contains(key)) {
            continue;
          }
          dynamic value = entry.value;
          if (value is String && dataKeys.contains(key)) {
            final decoded = jsonDecode(value);
            value = jsonEncode(_rewrite(decoded, paths, numberMap));
            if (!replace && prefs.getString(key) != null) {
              final previous = jsonDecode(prefs.getString(key)!);
              final incoming = jsonDecode(value);
              value = jsonEncode(
                key == ListeningStatistics.storageKey
                    ? _mergeStatistics(previous, incoming)
                    : _merge(previous, incoming),
              );
            }
          }
          await _set(prefs, key, value);
        }
        if (manifest['mode'] == 'everything') {
          final active = numberMap[manifest['activePlaylist']] ?? 1;
          await files.setActivePlaylistNumber(active);
        }
      } catch (_) {
        if (changed) {
          await for (final entry in Directory(docs).list()) {
            if (entry is File &&
                RegExp(r'^r_playlist_\d+\.m3u8(?:\.sort\.json)?$').hasMatch(p.basename(entry.path)) &&
                !originals.containsKey(entry.path)) {
              await entry.delete();
            }
          }
          for (final original in originals.entries) {
            await File(original.key).writeAsBytes(original.value, flush: true);
          }
          for (final entry in snapshot.entries) {
            if (entry.value == null) {
              await prefs.remove(entry.key);
            } else {
              await _set(prefs, entry.key, entry.value);
            }
          }
        }
        rethrow;
      }
    } catch (_) {
      // Only this verified, unique staging folder is owned by this operation.
      if (await staging.exists() && p.isWithin(p.join(support, 'RestoredAudio'), staging.path)) {
        await staging.delete(recursive: true);
      }
      rethrow;
    } finally {
      input.closeSync();
    }
  }

  static dynamic _rewrite(dynamic value, Map<String, String> paths, Map<int, int> numbers) {
    if (value is String) {
      if (paths.containsKey(value)) return paths[value];
      for (final entry in paths.entries) {
        if (value == entry.key.toLowerCase()) return Platform.isWindows ? entry.value.toLowerCase() : entry.value;
        if (value == 'file:${entry.key}' ||
            value == 'local:${entry.key}' ||
            value == 'local:${entry.key.toLowerCase()}' ||
            value == 'file:${entry.key.toLowerCase()}') {
          return '${value.split(':').first}:${Platform.isWindows ? entry.value.toLowerCase() : entry.value}';
        }
      }
      return value;
    }
    if (value is List) return value.map((item) => _rewrite(item, paths, numbers)).toList();
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        var key = '${_rewrite(entry.key, paths, numbers)}';
        var item = _rewrite(entry.value, paths, numbers);
        if (key == 'localTrackKey' && item is String) item = Platform.isWindows ? item.toLowerCase() : item;
        if (key == 'field' && item == 'playlist') {
          /* Rule values remapped below. */
        }
        result[key] = item;
      }
      if (result['field'] == 'playlist') {
        result['value'] = '${numbers[int.tryParse('${result['value']}')] ?? result['value']}';
      }
      if (result['playlists'] is Map) {
        result['playlists'] = {
          for (final entry in (result['playlists'] as Map).entries)
            '${numbers[int.tryParse('${entry.key}')] ?? entry.key}': entry.value,
        };
      }
      return result;
    }
    return value;
  }

  static dynamic _merge(dynamic existing, dynamic incoming) {
    if (existing is Map && incoming is Map) {
      return {
        ...incoming,
        ...existing,
        for (final key in existing.keys.where(incoming.containsKey)) key: _merge(existing[key], incoming[key]),
      };
    }
    if (existing is List && incoming is List) {
      final seen = <String>{};
      return [
        ...existing,
        ...incoming,
      ].where((item) => seen.add(item is Map && item['id'] is String ? 'id:${item['id']}' : jsonEncode(item))).toList();
    }
    return existing;
  }

  // A repeated backup must not count the same listening twice. Keep the larger
  // counters for overlapping records and retain independent days/tracks.
  static dynamic _mergeStatistics(dynamic existing, dynamic incoming) {
    if (existing is Map && incoming is Map) {
      return {
        ...incoming,
        ...existing,
        for (final key in existing.keys.where(incoming.containsKey))
          key: key == 'startedAt'
              ? ('${existing[key]}'.compareTo('${incoming[key]}') < 0 ? existing[key] : incoming[key])
              : key == 'lastPlayed'
              ? ('${existing[key]}'.compareTo('${incoming[key]}') > 0 ? existing[key] : incoming[key])
              : _mergeStatistics(existing[key], incoming[key]),
      };
    }
    if (existing is num && incoming is num) return existing > incoming ? existing : incoming;
    return existing;
  }

  static Future<void> _set(SharedPreferences prefs, String key, dynamic value) async {
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    } else if (value is List) {
      await prefs.setStringList(key, value.cast<String>());
    } else {
      throw const FormatException('Unsupported preference value');
    }
  }
}
