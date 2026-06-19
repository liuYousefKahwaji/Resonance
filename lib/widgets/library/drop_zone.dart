import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:resonance/services/import_service.dart';

class DropZone extends StatelessWidget {
  final Widget child;
  final Function(String) onFileAdded;

  const DropZone({
    super.key,
    required this.child,
    required this.onFileAdded,
  });

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (details) async {
        final paths = details.files
            .map((file) => file.path)
            // ignore: unnecessary_null_comparison
            .where((path) => path != null)
            .cast<String>()
            .toList();
        await ImportService.importFiles(paths, onFileAdded);
      },
      child: child,
    );
  }
}