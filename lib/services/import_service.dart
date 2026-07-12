import 'dart:io';
import 'package:resonance/core/storage/file_service.dart';

class ImportService {
  /// Processes a list of file paths (audio files and/or .m3u/.m3u8 playlists).
  /// For each valid audio file or playlist entry, calls onFileAdded with the track path.
  static Future<void> importFiles(List<String> paths, Function(String) onFileAdded, {int? playlistNumber}) async {
    final files = FileService();
    for (final path in paths) {
      if (path.isEmpty) continue;
      final extension = path.split('.').last.toLowerCase();

      if (extension == 'm3u' || extension == 'm3u8') {
        // It's a playlist file – read its content
        final playlistFile = File(path);
        if (!await playlistFile.exists()) continue;
        final content = await playlistFile.readAsString();
        final lines = content.split('\n');

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
            // Add each track from the playlist
            if (playlistNumber == null) {
              await files.writeTextToFile('$trimmed\n', append: true);
            } else {
              await files.addToPlaylist(playlistNumber, trimmed);
            }
            onFileAdded(trimmed);
          }
        }
      } else if (['mp3', 'wav', 'm4a', 'ogg', 'opus', 'webm', 'aac', 'flac'].contains(extension)) {
        // It's a single audio file
        if (playlistNumber == null) {
          await files.writeTextToFile('$path\n', append: true);
        } else {
          await files.addToPlaylist(playlistNumber, path);
        }
        onFileAdded(path);
      }
      // Ignore other file types silently
    }
  }
}
