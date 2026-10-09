import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

Future<bool> savePortableFile(String temporaryPath, {required String name, String mime = 'application/zip'}) async {
  if (Platform.isAndroid) {
    return await const MethodChannel(
          'resonance/portable_export',
        ).invokeMethod<bool>('save', {'path': temporaryPath, 'name': name, 'mime': mime}) ??
        false;
  }
  final destination = await FilePicker.saveFile(
    fileName: name,
    type: FileType.custom,
    allowedExtensions: [p.extension(name).substring(1)],
  );
  if (destination == null) return false;
  await File(temporaryPath).copy(destination);
  return true;
}
