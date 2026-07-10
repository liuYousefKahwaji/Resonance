import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FileService {
  static const String _activePlaylistKey = 'active_resonance_playlist';
  static const String _playlistNamesKey = 'resonance_playlist_names';
  static const int maxPlaylistNameLength = 25;
  static const int defaultPlaylistNumber = 1;
  final String? _documentsPathOverride;
  final bool? _isWindowsOverride;

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
    return next;
  }

  /// Creates an imported playlist through the same numbered-file and separate
  /// display-name flow used by the rest of Resonance.
  Future<({int number, String displayName})> createImportedPlaylist(String requestedName, List<String> tracks) async {
    final names = await getPlaylistNames();
    final displayName = _availablePlaylistName(requestedName, names.values.toSet());
    final number = await createNextPlaylist();
    await renamePlaylist(number, displayName);
    await reorderPlaylist(tracks);
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
  /// other playlists. Returns the playlist which should become active.
  Future<int> deletePlaylist(int number) async {
    final numbers = await listPlaylistNumbers();
    if (numbers.length <= 1 || !numbers.contains(number)) {
      return getActivePlaylistNumber();
    }
    final file = await _playlistFile(number);
    if (await file.exists()) await file.delete();
    final names = await getPlaylistNames();
    names.remove(number);
    await _savePlaylistNames(names);

    final remaining = numbers.where((value) => value != number).toList()..sort();
    final active = await getActivePlaylistNumber();
    final nextActive = active == number ? remaining.first : active;
    await setActivePlaylistNumber(nextActive);
    return nextActive;
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

  Future<void> removeFromPlaylist(String filePath) async {
    try {
      final file = await _localFile;
      if (await file.exists()) {
        final contents = await file.readAsString();
        final lines = contents.split("\n");
        final updatedLines = lines.where((line) => line != filePath).toList();
        await file.writeAsString(updatedLines.join("\n"));
      }
    } catch (_) {}
  }

  /// Overwrites the playlist file with [newOrder] as the new track sequence.
  /// Called after a drag-to-reorder so PlayerHandler.next()/previous()
  /// (which re-read the file fresh each time) honour the new order.
  Future<void> reorderPlaylist(List<String> newOrder) async {
    try {
      final file = await _localFile;
      final buffer = StringBuffer('#\n');
      for (final path in newOrder) {
        buffer.write('$path\n');
      }
      await file.writeAsString(buffer.toString());
    } catch (_) {}
  }
}
