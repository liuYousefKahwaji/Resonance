import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

class UpdateDownloadProgress {
  final int received;
  final int total;
  final bool verifying;

  const UpdateDownloadProgress(this.received, this.total, {this.verifying = false});
}

class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();

  @override
  String toString() => 'Update download cancelled';
}

class UpdateDownloadController {
  HttpClient? _client;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  void _attach(HttpClient client) {
    _client = client;
    if (_cancelled) client.close(force: true);
  }

  void _detach(HttpClient client) {
    if (identical(_client, client)) _client = null;
  }

  void _throwIfCancelled() {
    if (_cancelled) throw const UpdateDownloadCancelled();
  }
}

/// Downloads a GitHub release asset in resumable ranges, then verifies its digest.
/// Each range is kept separately so an interrupted attempt can resume safely.
class VerifiedUpdateDownloader {
  final HttpClient Function() _clientFactory;

  VerifiedUpdateDownloader({HttpClient Function()? clientFactory}) : _clientFactory = clientFactory ?? HttpClient.new;

  Future<void> download({
    required Uri url,
    required int size,
    required String sha256Hex,
    required File destination,
    void Function(UpdateDownloadProgress)? onProgress,
    UpdateDownloadController? controller,
  }) async {
    if (size <= 0 || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256Hex)) {
      throw const FormatException('Invalid update asset');
    }
    controller?._throwIfCancelled();
    await destination.parent.create(recursive: true);
    if (await destination.exists()) {
      if (await destination.length() == size &&
          (await sha256.bind(destination.openRead()).first).toString() == sha256Hex.toLowerCase()) {
        onProgress?.call(UpdateDownloadProgress(size, size, verifying: true));
        return;
      }
      await destination.delete();
    }

    final client = _clientFactory()..connectionTimeout = const Duration(seconds: 12);
    controller?._attach(client);
    try {
      final request = await client.getUrl(url).timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.userAgentHeader, 'Resonance-Updater');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode == HttpStatus.partialContent) {
        _requireRange(response, 0, 0, size);
        await response.drain<void>().timeout(const Duration(seconds: 20));
        await _downloadRanges(client, url, size, sha256Hex.toLowerCase(), destination, onProgress, controller);
      } else if (response.statusCode == HttpStatus.ok) {
        await _downloadSingle(response, size, sha256Hex.toLowerCase(), destination, onProgress, controller);
      } else {
        throw HttpException('Update server returned ${response.statusCode}');
      }
    } catch (_) {
      controller?._throwIfCancelled();
      rethrow;
    } finally {
      controller?._detach(client);
      client.close(force: true);
    }
  }

  Future<void> _downloadRanges(
    HttpClient client,
    Uri url,
    int size,
    String expectedSha,
    File destination,
    void Function(UpdateDownloadProgress)? onProgress,
    UpdateDownloadController? controller,
  ) async {
    final count = math.min(4, size);
    final span = (size + count - 1) ~/ count;
    final parts = List.generate(count, (index) => File('${destination.path}.chunk$index'));
    var received = 0;
    for (var index = 0; index < count; index++) {
      final length = math.min(span, size - index * span);
      if (await parts[index].exists()) {
        if (await parts[index].length() > length) await parts[index].delete();
        if (await parts[index].exists()) received += await parts[index].length();
      }
    }
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    void report({bool force = false}) {
      final now = DateTime.now();
      if (force || now.difference(lastProgressAt) >= const Duration(milliseconds: 150)) {
        lastProgressAt = now;
        onProgress?.call(UpdateDownloadProgress(received, size));
      }
    }

    report(force: true);
    try {
      await Future.wait([
        for (var index = 0; index < count; index++)
          _downloadRange(
            client,
            url,
            parts[index],
            index * span,
            math.min(size - 1, (index + 1) * span - 1),
            size,
            controller,
            (bytes) {
              received += bytes;
              report();
            },
          ),
      ], eagerError: true);
      controller?._throwIfCancelled();
      report(force: true);
      onProgress?.call(UpdateDownloadProgress(size, size, verifying: true));
      final assembled = File('${destination.path}.assembling');
      final sink = assembled.openWrite();
      try {
        for (final part in parts) {
          controller?._throwIfCancelled();
          await sink.addStream(part.openRead());
        }
      } finally {
        await sink.close();
      }
      controller?._throwIfCancelled();
      final actualSha = (await sha256.bind(assembled.openRead()).first).toString();
      controller?._throwIfCancelled();
      if (await assembled.length() != size || actualSha != expectedSha) {
        await assembled.delete();
        for (final part in parts) {
          if (await part.exists()) await part.delete();
        }
        throw const FormatException('Update checksum mismatch; download again');
      }
      await assembled.rename(destination.path);
      for (final part in parts) {
        if (await part.exists()) await part.delete();
      }
    } catch (_) {
      controller?._throwIfCancelled();
      rethrow;
    }
  }

  Future<void> _downloadRange(
    HttpClient client,
    Uri url,
    File part,
    int start,
    int end,
    int total,
    UpdateDownloadController? controller,
    void Function(int) onBytes,
  ) async {
    final length = end - start + 1;
    for (var attempt = 0; attempt < 3; attempt++) {
      controller?._throwIfCancelled();
      final existing = await part.exists() ? await part.length() : 0;
      if (existing == length) return;
      try {
        final request = await client.getUrl(url).timeout(const Duration(seconds: 15));
        request.headers.set(HttpHeaders.userAgentHeader, 'Resonance-Updater');
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=${start + existing}-$end');
        final response = await request.close().timeout(const Duration(seconds: 20));
        _requireRange(response, start + existing, end, total);
        final sink = part.openWrite(mode: FileMode.append);
        try {
          await sink.addStream(
            response.timeout(const Duration(seconds: 25)).map((bytes) {
              onBytes(bytes.length);
              return bytes;
            }),
          );
        } finally {
          await sink.close();
        }
        if (await part.length() == length) return;
        throw const HttpException('Update download ended early');
      } catch (_) {
        controller?._throwIfCancelled();
        if (attempt == 2) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt + 1));
      }
    }
  }

  Future<void> _downloadSingle(
    HttpClientResponse response,
    int size,
    String expectedSha,
    File destination,
    void Function(UpdateDownloadProgress)? onProgress,
    UpdateDownloadController? controller,
  ) async {
    final temporary = File('${destination.path}.part');
    var received = 0;
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    final sink = temporary.openWrite();
    try {
      await sink.addStream(
        response.timeout(const Duration(seconds: 25)).map((bytes) {
          controller?._throwIfCancelled();
          received += bytes.length;
          final now = DateTime.now();
          if (now.difference(lastProgressAt) >= const Duration(milliseconds: 150)) {
            lastProgressAt = now;
            onProgress?.call(UpdateDownloadProgress(received, size));
          }
          return bytes;
        }),
      );
    } finally {
      await sink.close();
    }
    controller?._throwIfCancelled();
    onProgress?.call(UpdateDownloadProgress(received, size, verifying: true));
    if (await temporary.length() != size || (await sha256.bind(temporary.openRead()).first).toString() != expectedSha) {
      await temporary.delete();
      throw const FormatException('Update checksum mismatch; download again');
    }
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
  }

  void _requireRange(HttpClientResponse response, int start, int end, int total) {
    final expected = 'bytes $start-$end/$total';
    if (response.statusCode != HttpStatus.partialContent || response.headers.value('content-range') != expected) {
      throw HttpException('Update server did not return the requested byte range');
    }
  }
}
