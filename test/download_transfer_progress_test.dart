import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/download_transfer_progress.dart';

void main() {
  test('Windows numeric payload and Android payload share exact units and handle unknowns', () {
    final progress = DownloadTransferProgress.parse(
      'resonance_progress:25%|resonance_transfer:{"downloadedBytes":1048576,"totalBytes":4194304,"bytesPerSecond":524288,"etaSeconds":6}',
    )!;
    expect(progress.sizeLabel, '1.0 MB / 4.0 MB');
    expect(progress.bytesPerSecond, 524288);
    expect(progress.etaSeconds, 6);
    final unknown = DownloadTransferProgress.parse(
      'resonance_transfer:{"downloadedBytes":1024,"totalBytes":null,"estimatedTotalBytes":null,"bytesPerSecond":null,"etaSeconds":null}',
    )!;
    expect(unknown.sizeLabel, '1.0 KB');
    expect(unknown.etaSeconds, isNull);
    final estimate = DownloadTransferProgress.parse(
      'resonance_transfer:{"estimatedTotalBytes":2048,"bytesPerSecond":-1,"etaSeconds":"NA"}',
    )!;
    expect(estimate.sizeLabel, '~2.0 KB');
    expect(estimate.bytesPerSecond, isNull);
    expect(estimate.etaSeconds, isNull);
    expect(DownloadTransferProgress.parse('resonance_transfer:not json'), isNull);
    expect(DownloadTransferProgress.parse('progress:0:Starting'), isNull);
  });
  test(
    'bundled Windows downloader emits valid details even when native fields are unknown',
    () async {
      final parent = await Directory('build/v403').create(recursive: true);
      final folder = await parent.createTemp('native-transfer-test-');
      final bytes = List<int>.filled(2 * 1024 * 1024, 0);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final listener = server.listen((request) async {
        try {
          request.response.headers.contentType = ContentType('audio', 'mpeg');
          request.response.contentLength = bytes.length;
          if (request.method != 'HEAD') request.response.add(bytes);
          await request.response.close();
        } catch (_) {
          /* yt-dlp may close its initial format probe early. */
        }
      });
      try {
        final result = await Process.run(
          File('assets/bin/yt-dlp.exe').absolute.path,
          [
            '--ignore-config',
            '--no-cache-dir',
            '--force-generic-extractor',
            '--no-playlist',
            '--no-warnings',
            '--proxy',
            '',
            '--progress',
            '--newline',
            '--no-colors',
            '--progress-template',
            windowsDownloadProgressTemplate,
            '-o',
            '${folder.path}/download.mp3',
            'http://127.0.0.1:${server.port}/fixture.mp3',
          ],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(const Duration(seconds: 35));
        expect(result.exitCode, 0);
        final lines = '${result.stdout}\n${result.stderr}'
            .split('\n')
            .where((line) => line.contains(DownloadTransferProgress.marker))
            .toList();
        expect(lines, isNotEmpty);
        final values = lines.map(DownloadTransferProgress.parse).toList();
        expect(
          values.every((value) => value != null),
          isTrue,
          reason: 'Missing native fields must be JSON null, not bare NA.',
        );
        expect(
          values.any((value) => value!.downloadedBytes == bytes.length && value.totalBytes == bytes.length),
          isTrue,
        );
        expect(await File('${folder.path}/download.mp3').length(), bytes.length);
      } finally {
        await server.close(force: true);
        await listener.cancel();
        assert(folder.absolute.path.startsWith(parent.absolute.path));
        await folder.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || !File('assets/bin/yt-dlp.exe').existsSync(),
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
