import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:resonance/platform/android/storage_permission_service.dart';
import 'package:resonance/services/import_service.dart';

class ImportTrackButton extends StatefulWidget {
  final Function(String) onFileAdded;
  const ImportTrackButton({super.key, required this.onFileAdded});

  @override
  State<ImportTrackButton> createState() => _ImportTrackButtonState();
}

class _ImportTrackButtonState extends State<ImportTrackButton> {
  Future<void> _selectFiles() async {
    // On Android, check / request storage permission before launching FilePicker.
    if (Platform.isAndroid) {
      final granted = await StoragePermissionService.requestWithRationale(context);
      if (!granted) {
        // Permission denied — user was already shown a rationale/settings dialog
        // by requestWithRationale; nothing more to do here.
        return;
      }
    }

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'ogg', 'm3u', 'm3u8'],
    );

    if (result == null) return;

    final paths = result.files.where((f) => f.path != null).map((f) => f.path!).toList();
    await ImportService.importFiles(paths, widget.onFileAdded);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: _selectFiles,
      icon: const Icon(Icons.add),
    );
  }
}