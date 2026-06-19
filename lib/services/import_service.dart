import 'dart:io';
import 'package:resonance/core/storage/file_service.dart';

class ImportService {
  /// Processes a list of file paths (audio files and/or .m3u/.m3u8 playlists).
  /// For each valid audio file or playlist entry, calls onFileAdded with the track path.
  static Future<void> importFiles(
    List<String> paths,
    Function(String) onFileAdded,
  ) async {
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
            await FileService().writeTextToFile('$trimmed\n', append: true);
            onFileAdded(trimmed);
          }
        }
      } else if (['mp3', 'wav', 'm4a', 'ogg'].contains(extension)) {
        // It's a single audio file
        await FileService().writeTextToFile('$path\n', append: true);
        onFileAdded(path);
      }
      // Ignore other file types silently
    }
  }
}