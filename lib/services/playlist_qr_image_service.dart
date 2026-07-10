import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image_lib;
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zxing2/qrcode.dart';

class PlaylistQrImageService {
  static const MethodChannel _androidChannel = MethodChannel('resonance/playlist_transfer');

  static Future<Uint8List> renderPng(String payload, {double imageSize = 1200, double quietZone = 64}) async {
    final qrSize = imageSize - quietZone * 2;
    final painter = QrPainter(
      data: payload,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
      gapless: true,
      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
      dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, imageSize, imageSize), Paint()..color = Colors.white);
    canvas.save();
    canvas.translate(quietZone, quietZone);
    painter.paint(canvas, Size(qrSize, qrSize));
    canvas.restore();
    final rendered = await recorder.endRecording().toImage(imageSize.round(), imageSize.round());
    try {
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('QR image encoding returned no PNG data');
      return data.buffer.asUint8List();
    } finally {
      rendered.dispose();
    }
  }

  static Future<String> decodeFile(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    return compute(_decodeQrImage, bytes);
  }

  static Future<String?> saveQrCodes({required String playlistName, required List<String> payloads}) async {
    if (payloads.isEmpty) return null;
    final safeName = sanitizeFilename(playlistName);
    final digits = payloads.length.toString().length.clamp(2, 4);
    final files = <({String name, Uint8List bytes})>[];
    for (var index = 0; index < payloads.length; index++) {
      final sequence = (index + 1).toString().padLeft(digits, '0');
      final total = payloads.length.toString().padLeft(digits, '0');
      final name = payloads.length == 1
          ? '${safeName}_resonance_qr.png'
          : '${safeName}_resonance_qr_$sequence-of-$total.png';
      files.add((name: name, bytes: await renderPng(payloads[index])));
    }
    if (Platform.isWindows) {
      if (files.length == 1) {
        var path = await FilePicker.saveFile(
          dialogTitle: 'Save Resonance playlist QR',
          fileName: files.single.name,
          type: FileType.custom,
          allowedExtensions: const ['png'],
        );
        if (path == null) return null;
        if (p.extension(path).toLowerCase() != '.png') path = '$path.png';
        await File(path).writeAsBytes(files.single.bytes, flush: true);
        return path;
      }
      final directory = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder for the QR codes');
      if (directory == null) return null;
      for (final file in files) {
        await File(p.join(directory, file.name)).writeAsBytes(file.bytes, flush: true);
      }
      return directory;
    }
    if (Platform.isAndroid) {
      final result = await _androidChannel.invokeMethod<String>('saveQrCodes', {
        'files': [
          for (final file in files) {'name': file.name, 'bytes': file.bytes},
        ],
      });
      return result ?? 'Pictures/Resonance';
    }
    throw UnsupportedError('Saving playlist QR codes is supported on Windows and Android.');
  }

  static String sanitizeFilename(String value) {
    var sanitized = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (sanitized.isEmpty) sanitized = 'Playlist';
    if (sanitized.length > 80) sanitized = sanitized.substring(0, 80).trimRight();
    return sanitized;
  }
}

String _decodeQrImage(Uint8List bytes) {
  final decoded = image_lib.decodeImage(bytes);
  if (decoded == null || decoded.width < 21 || decoded.height < 21) {
    throw const FormatException('The selected file is not a readable image.');
  }
  final pixels = decoded.convert(numChannels: 4).getBytes(order: image_lib.ChannelOrder.abgr).buffer.asInt32List();
  final source = RGBLuminanceSource(decoded.width, decoded.height, pixels);
  final reader = QRCodeReader();
  try {
    return reader.decode(BinaryBitmap(HybridBinarizer(source))).text;
  } catch (_) {
    reader.reset();
    return reader.decode(BinaryBitmap(GlobalHistogramBinarizer(source))).text;
  }
}
