import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FileService {
  
  // 1. Get the directory path safely
  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  // 2. ONLY returns the file reference (No reading/writing allowed here!)
  Future<File> get _localFile async {
    final path = await _localPath;
    return File('$path/playlist.m3u8');
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

  Future<void> removeFromPlaylist(String filePath) async{
    try {
      final file = await _localFile;
      if(await file.exists()){
        final contents = await file.readAsString();
        final lines = contents.split("\n");
        final updatedLines = lines.where((line) => line != filePath).toList();
        await file.writeAsString(updatedLines.join("\n"));
      }
    } catch (_){}
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