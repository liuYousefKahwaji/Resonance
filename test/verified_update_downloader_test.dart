import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/verified_update_downloader.dart';

void main() {
  test('downloads parallel ranges, resumes a partial chunk, and verifies the result', () async {
    final bytes = List<int>.generate(4096, (index) => index % 251);
    final ranges = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final header = request.headers.value(HttpHeaders.rangeHeader)!;
      ranges.add(header);
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(header)!;
      final start = int.parse(match[1]!);
      final end = int.parse(match[2]!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set('content-range', 'bytes $start-$end/${bytes.length}');
      request.response.add(bytes.sublist(start, end + 1));
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp('resonance-update-test-');
    try {
      final destination = File('${directory.path}/update.zip');
      await File('${destination.path}.chunk0').writeAsBytes(bytes.sublist(0, 512));
      final progress = <UpdateDownloadProgress>[];
      await VerifiedUpdateDownloader().download(
        url: Uri.parse('http://127.0.0.1:${server.port}/update.zip'),
        size: bytes.length,
        sha256Hex: sha256.convert(bytes).toString(),
        destination: destination,
        onProgress: progress.add,
      );
      expect(await destination.readAsBytes(), bytes);
      expect(ranges, contains('bytes=512-1023'));
      expect(ranges, contains('bytes=1024-2047'));
      expect(ranges, contains('bytes=2048-3071'));
      expect(ranges, contains('bytes=3072-4095'));
      expect(progress.first.received, 512);
      expect(progress.last.verifying, isTrue);
      expect(await File('${destination.path}.chunk0').exists(), isFalse);
    } finally {
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test('cancelled download keeps chunks for a later attempt', () async {
    final bytes = List<int>.generate(65536, (index) => index % 239);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(request.headers.value(HttpHeaders.rangeHeader)!)!;
      final start = int.parse(match[1]!);
      final end = int.parse(match[2]!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set('content-range', 'bytes $start-$end/${bytes.length}');
      request.response.add(bytes.sublist(start, end + 1));
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp('resonance-update-cancel-');
    try {
      final destination = File('${directory.path}/update.zip');
      final controller = UpdateDownloadController();
      await expectLater(
        VerifiedUpdateDownloader().download(
          url: Uri.parse('http://127.0.0.1:${server.port}/update.zip'),
          size: bytes.length,
          sha256Hex: sha256.convert(bytes).toString(),
          destination: destination,
          controller: controller,
          onProgress: (progress) {
            if (progress.received > 0 && !controller.isCancelled) controller.cancel();
          },
        ),
        throwsA(isA<UpdateDownloadCancelled>()),
      );
      expect(await File('${destination.path}.chunk0').exists(), isTrue);
      await VerifiedUpdateDownloader().download(
        url: Uri.parse('http://127.0.0.1:${server.port}/update.zip'),
        size: bytes.length,
        sha256Hex: sha256.convert(bytes).toString(),
        destination: destination,
      );
      expect(await destination.readAsBytes(), bytes);
    } finally {
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
}
