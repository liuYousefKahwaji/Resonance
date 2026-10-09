import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'playlist_sort.dart';
export 'playlist_sort.dart';

enum PlaylistMutationKind { created, replaced, appended, removed, reordered, deleted }

class PlaylistMutation {
  final int playlistNumber;
  final int revision;
  final PlaylistMutationKind kind;

  const PlaylistMutation(this.playlistNumber, this.revision, this.kind);
}

class FileService {
  static const String _activePlaylistKey = 'active_resonance_playlist';
  static const String _playlistNamesKey = 'resonance_playlist_names';
  static const int maxPlaylistNameLength = 25;
  static const int defaultPlaylistNumber = 1;
  static const int favoritesPlaylistNumber = 0;
  static bool isFavoritesPlaylist(int number) => number == favoritesPlaylistNumber;
  final String? _documentsPathOverride;
  final bool? _isWindowsOverride;
  static final StreamController<PlaylistMutation> _mutations = StreamController<PlaylistMutation>.broadcast(sync: true);
  static final Map<String, Future<void>> _writeTails = {};
  static final Map<String, Future<File>> _initializingFiles = {};
  static final Map<String, int> _revisions = {};
  static Future<void> _dateWrites = Future.value();
  static int activePlaylistNumber = defaultPlaylistNumber;

  static Stream<PlaylistMutation> get mutations => _mutations.stream;

  FileService({String? documentsPathOverride, bool? isWindowsOverride})
    : _documentsPathOverride = documentsPathOverride,
      _isWindowsOverride = isWindowsOverride;

  // 1. Get the directory path safely
  Future<String> get _localPath async {
    if (_documentsPathOverride != null) return _documentsPathOverride;
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<File> _playlistFile(int number) async {
    final path = await _localPath;
    return File('$path/r_playlist_$number.m3u8');
  }

  Future<String> get documentsDirectory => _localPath;

  Future<File> _ensurePlaylistFile(int number) async {
    final safeNumber = number < 0 ? defaultPlaylistNumber : number;
    final file = await _playlistFile(safeNumber);
    final pending = _initializingFiles.putIfAbsent(file.path, () async {
      if (!await file.exists()) {
        final legacy = safeNumber == defaultPlaylistNumber ? await _legacyFile : null;
        if (legacy != null && await legacy.exists()) {
          await legacy.rename(file.path);
        } else {
          await file.writeAsString('#\n');
        }
      }
      return file;
    });
    try {
      return await pending;
    } finally {
      if (identical(_initializingFiles[file.path], pending)) _initializingFiles.remove(file.path);
    }
  }

  Future<File> get _legacyFile async {
    final path = await _localPath;
    return File('$path/playlist.m3u8');
  }

  Future<int> getActivePlaylistNumber() async {
    final prefs = await SharedPreferences.getInstance();
    return activePlaylistNumber = prefs.getInt(_activePlaylistKey) ?? defaultPlaylistNumber;
  }

  Future<void> setActivePlaylistNumber(int number) async {
    final safeNumber = number < 0 ? defaultPlaylistNumber : number;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_activePlaylistKey, safeNumber);
    activePlaylistNumber = safeNumber;
    await _ensurePlaylistFile(safeNumber);
  }

  Future<List<int>> listPlaylistNumbers() async {
    await _ensureDefaultPlaylist();
    await _ensurePlaylistFile(favoritesPlaylistNumber);
    final path = await _localPath;
    final dir = Directory(path);
    final numbers = <int>{};
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final match = RegExp(r'r_playlist_(\d+)\.m3u8$').firstMatch(entity.path);
        if (match == null) continue;
        final number = int.tryParse(match.group(1)!);
        if (number != null) numbers.add(number);
      }
    }
    if (numbers.isEmpty) numbers.add(defaultPlaylistNumber);
    final sorted = numbers.toList()..sort();
    return sorted;
  }

  Future<int> createNextPlaylist() async {
    final numbers = await listPlaylistNumbers();
    final next = numbers.isEmpty ? defaultPlaylistNumber : numbers.last + 1;
    final file = await _playlistFile(next);
    await file.writeAsString("#\n");
    await setActivePlaylistNumber(next);
    await _publish(next, PlaylistMutationKind.created);
    return next;
  }

  /// Creates an imported playlist through the same numbered-file and separate
  /// display-name flow used by the rest of Resonance.
  Future<({int number, String displayName})> createImportedPlaylist(String requestedName, List<String> tracks) async {
    final names = await getPlaylistNames();
    final displayName = _availablePlaylistName(requestedName, names.values.toSet());
    final number = await createNextPlaylist();
    await renamePlaylist(number, displayName);
    await replacePlaylistTracks(number, tracks, kind: PlaylistMutationKind.replaced);
    return (number: number, displayName: displayName);
  }

  Future<Map<int, String>> getPlaylistNames() async {
    final numbers = await listPlaylistNumbers();
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_playlistNamesKey);
    final names = <int, String>{};
    if (saved != null) {
      try {
        final decoded = jsonDecode(saved) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final number = int.tryParse(entry.key);
          final name = entry.value?.toString().trim() ?? '';
          if (number != null && numbers.contains(number) && name.isNotEmpty) {
            names[number] = name;
          }
        }
      } catch (_) {}
    }
    for (final number in numbers) {
      names.putIfAbsent(number, () => 'Playlist $number');
    }
    names[favoritesPlaylistNumber] = 'Favorites';
    return names;
  }

  Future<void> renamePlaylist(int number, String name) async {
    if (isFavoritesPlaylist(number)) return;
    final cleanName = _normalizePlaylistName(name);
    if (cleanName.isEmpty) return;
    final names = await getPlaylistNames();
    names[number] = cleanName;
    await _savePlaylistNames(names);
  }

  String _normalizePlaylistName(String name) {
    final cleanName = name.trim();
    if (cleanName.length <= maxPlaylistNameLength) return cleanName;
    return cleanName.substring(0, maxPlaylistNameLength).trimRight();
  }

  String _availablePlaylistName(String requestedName, Set<String> existingNames) {
    final base = _normalizePlaylistName(requestedName).isEmpty
        ? 'Imported Playlist'
        : _normalizePlaylistName(requestedName);
    if (!existingNames.contains(base)) return base;
    for (var copy = 2; ; copy++) {
      final suffix = ' ($copy)';
      final maximumBaseLength = maxPlaylistNameLength - suffix.length;
      final shortened = base.length <= maximumBaseLength ? base : base.substring(0, maximumBaseLength).trimRight();
      final candidate = '$shortened$suffix';
      if (!existingNames.contains(candidate)) return candidate;
    }
  }

  /// Deletes the numbered storage file while keeping filenames stable for all
  /// other playlists. When playlist 1 is deleted, the next playlist is
  /// promoted to number 1 so the primary slot never becomes a new empty list.
  /// Returns the playlist which should become active.
  Future<int> deletePlaylist(int number) async {
    final numbers = await listPlaylistNumbers();
    if (isFavoritesPlaylist(number) ||
        numbers.where((value) => !isFavoritesPlaylist(value)).length <= 1 ||
        !numbers.contains(number)) {
      return getActivePlaylistNumber();
    }
    final names = await getPlaylistNames();
    final active = await getActivePlaylistNumber();
    final file = await _playlistFile(number);
    if (await file.exists()) await file.delete();
    final sortFile = File('${file.path}.sort.json');
    if (await sortFile.exists()) await sortFile.delete();
    names.remove(number);

    final remaining = numbers.where((value) => value != number && !isFavoritesPlaylist(value)).toList()..sort();
    var nextActive = active == number ? remaining.first : active;
    if (number == defaultPlaylistNumber) {
      final promotedNumber = remaining.first;
      final promotedFile = await _playlistFile(promotedNumber);
      final primaryFile = await _playlistFile(defaultPlaylistNumber);
      await promotedFile.rename(primaryFile.path);
      final promotedSort = File('${promotedFile.path}.sort.json');
      if (await promotedSort.exists()) await promotedSort.rename('${primaryFile.path}.sort.json');
      final promotedName = names.remove(promotedNumber) ?? 'Playlist $promotedNumber';
      names[defaultPlaylistNumber] = promotedName;
      if (nextActive == promotedNumber) nextActive = defaultPlaylistNumber;
    }
    await _savePlaylistNames(names);
    await setActivePlaylistNumber(nextActive);
    await _publish(number, PlaylistMutationKind.deleted);
    return nextActive;
  }

  /// Removes every occurrence of [trackPath] from every Resonance playlist.
  Future<void> removeTrackFromAllPlaylists(String trackPath) async {
    final numbers = await listPlaylistNumbers();
    for (final number in numbers) {
      await _serialize(number, () async {
        final tracks = await readPlaylistTracks(number);
        final kept = tracks.where((track) => !sameTrackPath(track, trackPath)).toList();
        if (kept.length == tracks.length) return;
        await _writeTracks(number, await _ensurePlaylistFile(number), kept);
        await _publish(number, PlaylistMutationKind.removed);
      });
    }
  }

  Future<int?> findPlaylistContaining(String trackPath, {int? preferredPlaylistNumber}) async {
    final numbers = await listPlaylistNumbers();
    final searchOrder = <int>[
      if (preferredPlaylistNumber != null && numbers.contains(preferredPlaylistNumber)) preferredPlaylistNumber,
      ...numbers.where((number) => number != preferredPlaylistNumber),
    ];
    for (final number in searchOrder) {
      final file = await _playlistFile(number);
      if (!await file.exists()) continue;
      final tracks = (await file.readAsLines()).map((line) => line.trim());
      if (tracks.any((candidate) => sameTrackPath(candidate, trackPath))) return number;
    }
    return null;
  }

  bool sameTrackPath(String first, String second) {
    if (first == second) return true;
    if (first.startsWith('http://') ||
        first.startsWith('https://') ||
        second.startsWith('http://') ||
        second.startsWith('https://')) {
      return false;
    }
    final firstPath = p.normalize(p.absolute(first));
    final secondPath = p.normalize(p.absolute(second));
    return (_isWindowsOverride ?? Platform.isWindows)
        ? firstPath.toLowerCase() == secondPath.toLowerCase()
        : firstPath == secondPath;
  }

  int findTrackIndex(List<String> tracks, String trackPath) {
    return tracks.indexWhere((candidate) => sameTrackPath(candidate, trackPath));
  }

  Future<Map<String, String>> favoriteSourceIds() =>
      TrackSourceRepository(isWindowsOverride: _isWindowsOverride).youtubeIdsByLocalPath();

  String favoriteIdentity(String track, {Map<String, String> sourceIds = const {}}) {
    if (track.startsWith('http://') || track.startsWith('https://')) {
      final videoId = TrackSourceRepository.videoIdFromUrlOrId(track);
      return videoId == null ? 'url:$track' : 'youtube:$videoId';
    }
    final normalized = p.normalize(p.absolute(track));
    final key = (_isWindowsOverride ?? Platform.isWindows) ? normalized.toLowerCase() : normalized;
    final mapped = sourceIds[key];
    return mapped == null ? 'file:$key' : 'youtube:$mapped';
  }

  Future<void> setTrackFavorite(String track, bool favorite) => _updateTrackFavorite(track, favorite);

  Future<void> toggleTrackFavorite(String track) => _updateTrackFavorite(track, null);

  Future<void> _updateTrackFavorite(String track, bool? requested) => _serialize(favoritesPlaylistNumber, () async {
    final sourceIds = await favoriteSourceIds();
    final identity = favoriteIdentity(track, sourceIds: sourceIds);
    final tracks = await readPlaylistTracks(favoritesPlaylistNumber);
    final exists = tracks.any((entry) => favoriteIdentity(entry, sourceIds: sourceIds) == identity);
    final favorite = requested ?? !exists;
    if (exists == favorite) return;
    final updated = favorite
        ? [...tracks, track]
        : tracks.where((entry) => favoriteIdentity(entry, sourceIds: sourceIds) != identity).toList();
    await _writeTracks(favoritesPlaylistNumber, await _ensurePlaylistFile(favoritesPlaylistNumber), updated);
    await _publish(favoritesPlaylistNumber, favorite ? PlaylistMutationKind.appended : PlaylistMutationKind.removed);
  });

  Future<void> favoriteTracks(Iterable<String> tracks) => setTracksFavorite(tracks, true);

  Future<void> setTracksFavorite(Iterable<String> tracks, bool favorite) {
    final selected = tracks.toList(growable: false);
    if (selected.isEmpty) return Future<void>.value();
    return _serialize(favoritesPlaylistNumber, () async {
      final current = await readPlaylistTracks(favoritesPlaylistNumber);
      final sources = await favoriteSourceIds();
      final identities = selected.map((track) => favoriteIdentity(track, sourceIds: sources)).toSet();
      final updated = favorite
          ? [...current, ...selected]
          : current.where((track) => !identities.contains(favoriteIdentity(track, sourceIds: sources))).toList();
      await _writeTracks(favoritesPlaylistNumber, await _ensurePlaylistFile(favoritesPlaylistNumber), updated);
      await _publish(favoritesPlaylistNumber, favorite ? PlaylistMutationKind.appended : PlaylistMutationKind.removed);
    });
  }

  Future<void> _savePlaylistNames(Map<int, String> names) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _playlistNamesKey,
      jsonEncode(names.map((number, name) => MapEntry(number.toString(), name))),
    );
  }

  Future<File> get _localFile async {
    await _ensureDefaultPlaylist();
    return _playlistFile(await getActivePlaylistNumber());
  }

  Future<void> _ensureDefaultPlaylist() async {
    await _ensurePlaylistFile(defaultPlaylistNumber);
  }

  // 3. Write data to the file (with optional append flag)
  Future<File> writeTextToFile(String text, {bool append = false}) async {
    return writeTextToPlaylist(await getActivePlaylistNumber(), text, append: append);
  }

  Future<File> writeTextToPlaylist(int playlistNumber, String text, {bool append = false}) async {
    final file = await _ensurePlaylistFile(playlistNumber);
    final entries = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    await _serialize(playlistNumber, () async {
      final tracks = append ? [...await readPlaylistTracks(playlistNumber), ...entries] : entries;
      await _writeTracks(playlistNumber, file, tracks);
      await _publish(playlistNumber, append ? PlaylistMutationKind.appended : PlaylistMutationKind.replaced);
    });
    return file;
  }

  /// Returns normalized track entries for an explicit playlist. Callers which
  /// need to mutate a playlist should use the methods below so rapid operations
  /// cannot overwrite one another.
  Future<List<String>> readPlaylistTracks(int playlistNumber) async {
    final contents = await readTextFromPlaylist(playlistNumber);
    return contents
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList(growable: false);
  }

  Future<void> replacePlaylistTracks(
    int playlistNumber,
    List<String> tracks, {
    PlaylistMutationKind kind = PlaylistMutationKind.replaced,
  }) => _serialize(playlistNumber, () async {
    final file = await _ensurePlaylistFile(playlistNumber);
    final normalized = tracks.map((track) => track.trim()).where((track) => track.isNotEmpty).toList();
    await _writeTracks(playlistNumber, file, normalized, manual: kind == PlaylistMutationKind.reordered);
    await _publish(playlistNumber, kind);
  });

  /// Replace surviving stream references atomically, preserving playlist order.
  /// A track removed while downloading must not be added back.
  Future<void> replaceStreamWithDownload(int playlistNumber, String stream, String localPath) async {
    await _serialize(playlistNumber, () async {
      if (!await (await _playlistFile(playlistNumber)).exists()) return;
      final tracks = await readPlaylistTracks(playlistNumber);
      final sources = isFavoritesPlaylist(playlistNumber) ? await favoriteSourceIds() : const <String, String>{};
      bool matches(String track) => isFavoritesPlaylist(playlistNumber)
          ? favoriteIdentity(track, sourceIds: sources) == favoriteIdentity(stream, sourceIds: sources)
          : track == stream;
      if (!tracks.any(matches)) return;
      final updated = tracks.map((track) => matches(track) ? localPath : track).toList();
      final file = await _ensurePlaylistFile(playlistNumber);
      final state = await playlistSortState(playlistNumber);
      await _writeTracks(
        playlistNumber,
        file,
        updated,
        state: state.copyWith(addedOrder: state.addedOrder.map((entry) => matches(entry) ? localPath : entry).toList()),
      );
      await _publish(playlistNumber, PlaylistMutationKind.replaced);
    });
    // Release the normal playlist's lock before updating global membership.
    // Favorite changes may re-sort that normal playlist again.
    if (!isFavoritesPlaylist(playlistNumber)) {
      await replaceStreamWithDownload(favoritesPlaylistNumber, stream, localPath);
    }
  }

  Future<bool> appendTrack(int playlistNumber, String trackPath) async {
    var changed = false;
    await _serialize(playlistNumber, () async {
      final clean = trackPath.trim();
      if (clean.isEmpty) return;
      final tracks = await readPlaylistTracks(playlistNumber);
      if (tracks.any((candidate) => sameTrackPath(candidate, clean))) return;
      final file = await _ensurePlaylistFile(playlistNumber);
      await _writeTracks(playlistNumber, file, [...tracks, clean]);
      changed = true;
      await _publish(playlistNumber, PlaylistMutationKind.appended);
    });
    return changed;
  }

  Future<bool> removeOccurrence(int playlistNumber, String trackPath, {int? playlistIndex}) async {
    var changed = false;
    await _serialize(playlistNumber, () async {
      final tracks = (await readPlaylistTracks(playlistNumber)).toList();
      var index = -1;
      if (playlistIndex != null &&
          playlistIndex >= 0 &&
          playlistIndex < tracks.length &&
          sameTrackPath(tracks[playlistIndex], trackPath)) {
        index = playlistIndex;
      } else {
        index = findTrackIndex(tracks, trackPath);
      }
      if (index < 0) return;
      tracks.removeAt(index);
      final file = await _ensurePlaylistFile(playlistNumber);
      await _writeTracks(playlistNumber, file, tracks);
      changed = true;
      await _publish(playlistNumber, PlaylistMutationKind.removed);
    });
    return changed;
  }

  Future<void> reorderPlaylistNumber(int playlistNumber, List<String> tracks) =>
      replacePlaylistTracks(playlistNumber, tracks, kind: PlaylistMutationKind.reordered);

  Future<PlaylistSortState> playlistSortState(int number) async {
    final file = await _playlistFile(number);
    final sidecar = File('${file.path}.sort.json');
    if (await sidecar.exists()) {
      try {
        return PlaylistSortState.fromJson(jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>);
      } catch (_) {
        /* An unreadable preference must not hide the playlist. */
      }
    }
    return PlaylistSortState(addedOrder: await readPlaylistTracks(number));
  }

  Future<void> sortPlaylist(
    int number,
    PlaylistSortMode mode, {
    bool descending = false,
    bool reroll = false,
    bool? favoritesFirst,
  }) => _serialize(number, () async {
    final current = await playlistSortState(number);
    final selected = current.copyWith(
      mode: mode,
      descending: descending,
      favoritesFirst: favoritesFirst,
      seed: reroll || current.seed == 0 ? PlaylistSortState.newSeed() : current.seed,
    );
    await _writeTracks(number, await _ensurePlaylistFile(number), await readPlaylistTracks(number), state: selected);
    await _publish(number, PlaylistMutationKind.reordered);
  });

  Future<void> restorePlaylistSortState(int number, PlaylistSortState state, {List<String>? tracks}) =>
      _serialize(number, () async {
        await _writeTracks(
          number,
          await _ensurePlaylistFile(number),
          tracks ?? await readPlaylistTracks(number),
          state: state,
          preserveOrder: true,
        );
        await _publish(number, PlaylistMutationKind.reordered);
      });

  Future<void> _writeTracks(
    int number,
    File file,
    List<String> tracks, {
    bool manual = false,
    PlaylistSortState? state,
    bool preserveOrder = false,
  }) async {
    Map<String, String> sourceIds = const {};
    var selected = (state ?? await playlistSortState(number)).reconcile(tracks);
    if (isFavoritesPlaylist(number) || selected.favoritesFirst || selected.mode == PlaylistSortMode.random) {
      sourceIds = await favoriteSourceIds();
    }
    if (isFavoritesPlaylist(number)) {
      final identities = <String>{};
      tracks = tracks.where((track) => identities.add(favoriteIdentity(track, sourceIds: sourceIds))).toList();
      selected = selected.reconcile(tracks);
    }
    if (manual) selected = selected.copyWith(mode: PlaylistSortMode.custom, descending: false);
    final titles = <String, String>{};
    if (selected.mode == PlaylistSortMode.title) {
      for (final track in tracks.toSet()) {
        var cached = await MetadataCacheService.get(track);
        if (cached == null && !track.startsWith('http') && await File(track).exists()) {
          try {
            final metadata = await AudioMetadata.extract(File(track));
            final title = metadata?.trackName?.trim();
            if (title != null && title.isNotEmpty) {
              cached = CachedTrackMetadata(title: title, artist: metadata?.firstArtists ?? 'Unknown Artist');
              await MetadataCacheService.set(track, cached.title, cached.artist);
            }
          } catch (_) {
            /* Untagged files sort by filename. */
          }
        }
        titles[track] = cached?.title.trim().isNotEmpty == true ? cached!.title : p.basenameWithoutExtension(track);
      }
    }
    // Unsorted playlists must keep the producer's supplied order (notably live
    // Sync queues). Choosing a sort initializes the seed and enables sorting.
    final favoriteKeys = selected.favoritesFirst && isFavoritesPlaylist(number)
        ? tracks.map((track) => favoriteIdentity(track, sourceIds: sourceIds)).toSet()
        : selected.favoritesFirst
        ? (await readPlaylistTracks(
            favoritesPlaylistNumber,
          )).map((track) => favoriteIdentity(track, sourceIds: sourceIds)).toSet()
        : const <String>{};
    final favorites = {
      for (final track in tracks)
        if (favoriteKeys.contains(favoriteIdentity(track, sourceIds: sourceIds))) track,
    };
    final randomIdentities = <String, String>{};
    if (selected.mode == PlaylistSortMode.random) {
      for (final track in tracks) {
        final identity = favoriteIdentity(track, sourceIds: sourceIds);
        if (identity.startsWith('youtube:')) {
          randomIdentities[track] = TrackSourceRepository.canonicalUrlFor(identity.substring(8));
        }
      }
    }
    final ordered =
        preserveOrder || selected.mode == PlaylistSortMode.dateAdded && selected.seed == 0 && !selected.favoritesFirst
        ? tracks
        : selected.sorted(tracks, titles: titles, favorites: favorites, randomIdentities: randomIdentities);
    // The numbered playlist stays authoritative for Next/Previous. The sidecar
    // remembers insertion order even after sorting or manual rearrangement.
    final sidecar = File('${file.path}.sort.json');
    final partial = File('${sidecar.path}.part');
    await partial.writeAsString(jsonEncode(selected.toJson()), flush: true);
    await partial.rename(sidecar.path);
    final stagedPlaylist = File('${file.path}.part');
    final previousTracks = await file.exists() ? await file.readAsLines() : <String>[];
    await stagedPlaylist.writeAsString('#\n${ordered.map((track) => '$track\n').join()}', flush: true);
    await stagedPlaylist.rename(file.path);
    if (number != favoritesPlaylistNumber) {
      final added = tracks.where((track) => !previousTracks.contains(track)).toList();
      if (added.isNotEmpty) {
        final task = _dateWrites.catchError((_) {}).then((_) async {
          final prefs = await SharedPreferences.getInstance();
          Map<String, dynamic> dates;
          try {
            dates = Map<String, dynamic>.from(jsonDecode(prefs.getString('library_added_dates_v1') ?? '{}') as Map);
          } catch (_) {
            dates = {};
          }
          final mappings = await favoriteSourceIds();
          for (final track in added) {
            dates.putIfAbsent(
              favoriteIdentity(track, sourceIds: mappings),
              () => DateTime.now().toUtc().toIso8601String(),
            );
          }
          await prefs.setString('library_added_dates_v1', jsonEncode(dates));
        });
        _dateWrites = task;
        await task;
      }
    }
  }

  Future<void> _serialize(int playlistNumber, Future<void> Function() operation) async {
    final key = '${await _localPath}|$playlistNumber';
    final previous = _writeTails[key] ?? Future<void>.value();
    final next = previous.catchError((_) {}).then((_) => operation());
    _writeTails[key] = next;
    try {
      await next;
    } finally {
      if (identical(_writeTails[key], next)) _writeTails.remove(key);
    }
  }

  Future<void> _publish(int playlistNumber, PlaylistMutationKind kind) async {
    final key = '${await _localPath}|$playlistNumber';
    final revision = (_revisions[key] ?? 0) + 1;
    _revisions[key] = revision;
    _mutations.add(PlaylistMutation(playlistNumber, revision, kind));
    if (isFavoritesPlaylist(playlistNumber) && kind != PlaylistMutationKind.reordered) {
      for (final number in await listPlaylistNumbers()) {
        if (isFavoritesPlaylist(number) || !(await playlistSortState(number)).favoritesFirst) continue;
        await _serialize(number, () async {
          await _writeTracks(number, await _ensurePlaylistFile(number), await readPlaylistTracks(number));
          await _publish(number, PlaylistMutationKind.reordered);
        });
      }
    }
  }

  Future<void> notifyLibraryRestored() async {
    for (final number in await listPlaylistNumbers()) {
      await _publish(number, PlaylistMutationKind.reordered);
    }
  }

  Future<String> readTextFromPlaylist(int playlistNumber) async {
    final file = await _ensurePlaylistFile(playlistNumber);
    var contents = await file.readAsString();
    if (!contents.startsWith('#')) {
      contents = '#\n$contents';
      await file.writeAsString(contents);
    }
    return contents;
  }

  Future<void> addToPlaylist(int playlistNumber, String trackPath) async {
    await appendTrack(playlistNumber, trackPath);
  }

  // 4. Read data from the file safely
  Future<String> readTextFromFile() async {
    try {
      final file = await _localFile;

      if (await file.exists()) {
        String contents = await file.readAsString();

        // If the file is empty or missing the M3U header, initialize it properly
        if (!contents.startsWith("#")) {
          contents = "#\n$contents";
          await file.writeAsString(contents);
        }
        return contents;
      }

      // If file doesn't exist, create it with a header and return empty contents
      await file.writeAsString("#\n");
      return "#\n";
    } catch (e) {
      return "Error reading file: $e";
    }
  }

  Future<void> removeFromPlaylist(String filePath, {int? playlistIndex}) async {
    try {
      await removeOccurrence(await getActivePlaylistNumber(), filePath, playlistIndex: playlistIndex);
    } catch (_) {}
  }

  /// Overwrites the playlist file with [newOrder] as the new track sequence.
  /// Called after a drag-to-reorder so PlayerHandler.next()/previous()
  /// (which re-read the file fresh each time) honour the new order.
  Future<void> reorderPlaylist(List<String> newOrder) async {
    try {
      await reorderPlaylistNumber(await getActivePlaylistNumber(), newOrder);
    } catch (_) {}
  }
}
