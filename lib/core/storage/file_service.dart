import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final String? _documentsPathOverride;
  final bool? _isWindowsOverride;
  static final StreamController<PlaylistMutation> _mutations = StreamController<PlaylistMutation>.broadcast(sync: true);
  static final Map<String, Future<void>> _writeTails = {};
  static final Map<String, int> _revisions = {};

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

  Future<File> _ensurePlaylistFile(int number) async {
    final safeNumber = number < 1 ? defaultPlaylistNumber : number;
    final file = await _playlistFile(safeNumber);
    if (!await file.exists()) await file.writeAsString('#\n');
    return file;
  }

  Future<File> get _legacyFile async {
    final path = await _localPath;
    return File('$path/playlist.m3u8');
  }

  Future<int> getActivePlaylistNumber() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_activePlaylistKey) ?? defaultPlaylistNumber;
  }

  Future<void> setActivePlaylistNumber(int number) async {
    final safeNumber = number < 1 ? defaultPlaylistNumber : number;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_activePlaylistKey, safeNumber);
    final file = await _playlistFile(safeNumber);
    if (!await file.exists()) {
      await file.writeAsString("#\n");
    }
  }

  Future<List<int>> listPlaylistNumbers() async {
    await _ensureDefaultPlaylist();
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
    return names;
  }

  Future<void> renamePlaylist(int number, String name) async {
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
    if (numbers.length <= 1 || !numbers.contains(number)) {
      return getActivePlaylistNumber();
    }
    final names = await getPlaylistNames();
    final active = await getActivePlaylistNumber();
    final file = await _playlistFile(number);
    if (await file.exists()) await file.delete();
    names.remove(number);

    final remaining = numbers.where((value) => value != number).toList()..sort();
    var nextActive = active == number ? remaining.first : active;
    if (number == defaultPlaylistNumber) {
      final promotedNumber = remaining.first;
      final promotedFile = await _playlistFile(promotedNumber);
      final primaryFile = await _playlistFile(defaultPlaylistNumber);
      await promotedFile.rename(primaryFile.path);
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
      final file = await _playlistFile(number);
      if (!await file.exists()) continue;
      final lines = await file.readAsLines();
      final kept = <String>['#'];
      for (final line in lines) {
        final clean = line.trim();
        if (clean.isEmpty || clean.startsWith('#')) continue;
        if (!sameTrackPath(clean, trackPath)) kept.add(clean);
      }
      await file.writeAsString('${kept.join('\n')}\n');
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
    final defaultFile = await _playlistFile(defaultPlaylistNumber);
    if (await defaultFile.exists()) return;

    final legacy = await _legacyFile;
    if (await legacy.exists()) {
      await legacy.rename(defaultFile.path);
    } else {
      await defaultFile.writeAsString("#\n");
    }
  }

  // 3. Write data to the file (with optional append flag)
  Future<File> writeTextToFile(String text, {bool append = false}) async {
    final file = await _localFile;

    if (append) {
      // Use append mode so you don't overwrite existing songs!
      return file.writeAsString(text, mode: FileMode.append);
    } else {
      return file.writeAsString(text);
    }
  }

  Future<File> writeTextToPlaylist(int playlistNumber, String text, {bool append = false}) async {
    final file = await _ensurePlaylistFile(playlistNumber);
    return file.writeAsString(text, mode: append ? FileMode.append : FileMode.write);
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
    final normalized = tracks.map((track) => track.trim()).where((track) => track.isNotEmpty);
    await file.writeAsString('#\n${normalized.map((track) => '$track\n').join()}', flush: true);
    await _publish(playlistNumber, kind);
  });

  Future<bool> appendTrack(int playlistNumber, String trackPath) async {
    var changed = false;
    await _serialize(playlistNumber, () async {
      final clean = trackPath.trim();
      if (clean.isEmpty) return;
      final tracks = await readPlaylistTracks(playlistNumber);
      if (tracks.any((candidate) => sameTrackPath(candidate, clean))) return;
      final file = await _ensurePlaylistFile(playlistNumber);
      await file.writeAsString('$clean\n', mode: FileMode.append, flush: true);
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
      await file.writeAsString('#\n${tracks.map((track) => '$track\n').join()}', flush: true);
      changed = true;
      await _publish(playlistNumber, PlaylistMutationKind.removed);
    });
    return changed;
  }

  Future<void> reorderPlaylistNumber(int playlistNumber, List<String> tracks) =>
      replacePlaylistTracks(playlistNumber, tracks, kind: PlaylistMutationKind.reordered);

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
