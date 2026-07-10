import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:resonance/services/track_source_repository.dart';

enum PlaylistTransferError {
  unrelatedQr,
  unsupportedVersion,
  invalidChunk,
  corruptedChunk,
  mixedTransfers,
  incompleteTransfer,
  incorrectChecksum,
  malformedManifest,
  invalidManifest,
  payloadTooLarge,
  decompressedPayloadTooLarge,
}

class PlaylistTransferException implements Exception {
  final PlaylistTransferError error;
  final String message;

  const PlaylistTransferException(this.error, this.message);

  @override
  String toString() => message;
}

class PlaylistTransferManifest {
  final int version;
  final String playlistName;
  final List<String> youtubeVideoIds;

  const PlaylistTransferManifest({
    this.version = PlaylistTransferCodec.protocolVersion,
    required this.playlistName,
    required this.youtubeVideoIds,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'playlistName': playlistName,
    'youtubeVideoIds': youtubeVideoIds,
  };

  factory PlaylistTransferManifest.fromJson(Map<String, dynamic> json) {
    final ids = json['youtubeVideoIds'];
    if (ids is! List) {
      throw const PlaylistTransferException(
        PlaylistTransferError.malformedManifest,
        'The playlist transfer does not contain a track list.',
      );
    }
    return PlaylistTransferManifest(
      version: json['version'] is int ? json['version'] as int : -1,
      playlistName: json['playlistName']?.toString() ?? '',
      youtubeVideoIds: ids.map((value) => value.toString()).toList(growable: false),
    );
  }
}

class EncodedPlaylistTransfer {
  final String transferId;
  final String payloadChecksum;
  final List<String> qrPayloads;
  final PlaylistTransferManifest manifest;

  const EncodedPlaylistTransfer({
    required this.transferId,
    required this.payloadChecksum,
    required this.qrPayloads,
    required this.manifest,
  });
}

enum ChunkAcceptance { accepted, duplicate }

class PlaylistTransferCodec {
  static const int protocolVersion = 1;
  static const String prefix = 'RESO-PLAYLIST-1:';
  static const int defaultChunkDataLength = 1000;
  static const int maxCompressedPayloadBytes = 1024 * 1024;
  static const int maxDecompressedPayloadBytes = 4 * 1024 * 1024;
  static const int maxPlaylistEntries = 10000;
  static const int maxPlaylistNameLength = 250;
  static const int maxChunkCount = 2048;
  static const int maxQrPayloadLength = 2500;

  static final RegExp _hex64 = RegExp(r'^[a-f0-9]{64}$');
  static final RegExp _hex16 = RegExp(r'^[a-f0-9]{16}$');
  static final RegExp _base64Url = RegExp(r'^[A-Za-z0-9_-]+$');

  static EncodedPlaylistTransfer encode(
    PlaylistTransferManifest manifest, {
    int chunkDataLength = defaultChunkDataLength,
  }) {
    _validateManifest(manifest);
    if (chunkDataLength < 64 || chunkDataLength > 1800) {
      throw RangeError.range(chunkDataLength, 64, 1800, 'chunkDataLength');
    }
    final serialized = utf8.encode(jsonEncode(manifest.toJson()));
    if (serialized.length > maxDecompressedPayloadBytes) {
      throw const PlaylistTransferException(
        PlaylistTransferError.decompressedPayloadTooLarge,
        'The playlist is too large to transfer safely.',
      );
    }
    final compressed = Uint8List.fromList(ZLibCodec(level: 9).encode(serialized));
    if (compressed.length > maxCompressedPayloadBytes) {
      throw const PlaylistTransferException(
        PlaylistTransferError.payloadTooLarge,
        'The compressed playlist is too large to transfer safely.',
      );
    }
    final payloadChecksum = sha256.convert(compressed).toString();
    final transferId = payloadChecksum.substring(0, 16);
    final encoded = base64UrlEncode(compressed).replaceAll('=', '');
    final chunks = <String>[];
    for (var offset = 0; offset < encoded.length; offset += chunkDataLength) {
      chunks.add(encoded.substring(offset, (offset + chunkDataLength).clamp(0, encoded.length)));
    }
    if (chunks.isEmpty) chunks.add('AA');
    if (chunks.length > maxChunkCount) {
      throw const PlaylistTransferException(
        PlaylistTransferError.payloadTooLarge,
        'This playlist requires too many QR codes.',
      );
    }
    final qrPayloads = <String>[];
    for (var index = 0; index < chunks.length; index++) {
      final chunk = chunks[index];
      final chunkChecksum = sha256.convert(ascii.encode(chunk)).toString().substring(0, 16);
      qrPayloads.add('$prefix$transferId:${index + 1}:${chunks.length}:$chunkChecksum:$payloadChecksum:$chunk');
    }
    return EncodedPlaylistTransfer(
      transferId: transferId,
      payloadChecksum: payloadChecksum,
      qrPayloads: List.unmodifiable(qrPayloads),
      manifest: manifest,
    );
  }

  static void _validateManifest(PlaylistTransferManifest manifest) {
    if (manifest.version != protocolVersion) {
      throw const PlaylistTransferException(
        PlaylistTransferError.unsupportedVersion,
        'This playlist transfer was created by a newer Resonance version.',
      );
    }
    final name = manifest.playlistName.trim();
    if (name.isEmpty || name.length > maxPlaylistNameLength || name.contains('\u0000')) {
      throw const PlaylistTransferException(
        PlaylistTransferError.invalidManifest,
        'The playlist transfer has an invalid display name.',
      );
    }
    if (manifest.youtubeVideoIds.isEmpty || manifest.youtubeVideoIds.length > maxPlaylistEntries) {
      throw const PlaylistTransferException(
        PlaylistTransferError.invalidManifest,
        'The playlist transfer has an invalid number of entries.',
      );
    }
    for (final id in manifest.youtubeVideoIds) {
      if (!TrackSourceRepository.isValidYoutubeVideoId(id)) {
        throw PlaylistTransferException(
          PlaylistTransferError.invalidManifest,
          'The playlist transfer contains an invalid YouTube video ID: $id',
        );
      }
    }
  }
}

class PlaylistTransferSession {
  String? _transferId;
  String? _payloadChecksum;
  int? _totalChunks;
  final Map<int, String> _chunks = {};

  String? get transferId => _transferId;
  int? get totalChunks => _totalChunks;
  int get receivedChunkCount => _chunks.length;
  bool get isEmpty => _chunks.isEmpty;
  bool get isComplete => _totalChunks != null && _chunks.length == _totalChunks;
  List<int> get receivedChunkIndexes => (_chunks.keys.map((index) => index + 1).toList()..sort());
  List<int> get missingChunkIndexes => _totalChunks == null
      ? const []
      : [
          for (var index = 0; index < _totalChunks!; index++)
            if (!_chunks.containsKey(index)) index + 1,
        ];

  ChunkAcceptance acceptChunk(String rawPayload) {
    if (rawPayload.length > PlaylistTransferCodec.maxQrPayloadLength) {
      throw const PlaylistTransferException(
        PlaylistTransferError.payloadTooLarge,
        'The QR payload is larger than Resonance accepts.',
      );
    }
    if (!rawPayload.startsWith('RESO-PLAYLIST-')) {
      throw const PlaylistTransferException(
        PlaylistTransferError.unrelatedQr,
        'This is not a Resonance playlist QR code.',
      );
    }
    final parts = rawPayload.split(':');
    if (parts.length != 7) {
      throw const PlaylistTransferException(PlaylistTransferError.invalidChunk, 'This Resonance QR code is malformed.');
    }
    final version = int.tryParse(parts[0].substring('RESO-PLAYLIST-'.length));
    if (version != PlaylistTransferCodec.protocolVersion) {
      throw const PlaylistTransferException(
        PlaylistTransferError.unsupportedVersion,
        'This playlist transfer was created by a newer Resonance version.',
      );
    }
    final transferId = parts[1];
    final oneBasedIndex = int.tryParse(parts[2]);
    final total = int.tryParse(parts[3]);
    final chunkChecksum = parts[4];
    final payloadChecksum = parts[5];
    final chunk = parts[6];
    if (!PlaylistTransferCodec._hex16.hasMatch(transferId) ||
        oneBasedIndex == null ||
        total == null ||
        total < 1 ||
        total > PlaylistTransferCodec.maxChunkCount ||
        oneBasedIndex < 1 ||
        oneBasedIndex > total ||
        !PlaylistTransferCodec._hex16.hasMatch(chunkChecksum) ||
        !PlaylistTransferCodec._hex64.hasMatch(payloadChecksum) ||
        chunk.isEmpty ||
        !PlaylistTransferCodec._base64Url.hasMatch(chunk)) {
      throw const PlaylistTransferException(
        PlaylistTransferError.invalidChunk,
        'This Resonance QR code has invalid chunk metadata.',
      );
    }
    final actualChunkChecksum = sha256.convert(ascii.encode(chunk)).toString().substring(0, 16);
    if (actualChunkChecksum != chunkChecksum) {
      throw const PlaylistTransferException(
        PlaylistTransferError.corruptedChunk,
        'One of the QR codes is corrupted. Scan or upload it again.',
      );
    }
    if (_transferId != null &&
        (_transferId != transferId || _payloadChecksum != payloadChecksum || _totalChunks != total)) {
      throw const PlaylistTransferException(
        PlaylistTransferError.mixedTransfers,
        'The QR codes belong to different playlist transfers.',
      );
    }
    _transferId ??= transferId;
    _payloadChecksum ??= payloadChecksum;
    _totalChunks ??= total;
    final index = oneBasedIndex - 1;
    final previous = _chunks[index];
    if (previous != null) {
      if (previous != chunk) {
        throw const PlaylistTransferException(
          PlaylistTransferError.corruptedChunk,
          'Two different QR chunks use the same position.',
        );
      }
      return ChunkAcceptance.duplicate;
    }
    final prospectiveLength = _chunks.values.fold<int>(chunk.length, (sum, value) => sum + value.length);
    final maxEncodedLength = ((PlaylistTransferCodec.maxCompressedPayloadBytes + 2) ~/ 3) * 4;
    if (prospectiveLength > maxEncodedLength) {
      throw const PlaylistTransferException(
        PlaylistTransferError.payloadTooLarge,
        'The compressed playlist is too large to import safely.',
      );
    }
    _chunks[index] = chunk;
    return ChunkAcceptance.accepted;
  }

  PlaylistTransferManifest reconstructManifest() {
    if (!isComplete) {
      final missing = missingChunkIndexes.join(', ');
      throw PlaylistTransferException(
        PlaylistTransferError.incompleteTransfer,
        'Transfer incomplete. Missing QR ${missing.isEmpty ? 'codes' : missing}.',
      );
    }
    final encoded = [for (var index = 0; index < _totalChunks!; index++) _chunks[index]!].join();
    Uint8List compressed;
    try {
      final padding = '=' * ((4 - encoded.length % 4) % 4);
      compressed = base64Url.decode('$encoded$padding');
    } catch (_) {
      throw const PlaylistTransferException(
        PlaylistTransferError.corruptedChunk,
        'The QR payload could not be decoded.',
      );
    }
    if (compressed.length > PlaylistTransferCodec.maxCompressedPayloadBytes) {
      throw const PlaylistTransferException(
        PlaylistTransferError.payloadTooLarge,
        'The compressed playlist is too large to import safely.',
      );
    }
    if (sha256.convert(compressed).toString() != _payloadChecksum) {
      throw const PlaylistTransferException(
        PlaylistTransferError.incorrectChecksum,
        'The completed playlist transfer failed its integrity check.',
      );
    }
    final decompressed = _decompressWithLimit(compressed);
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(decompressed));
    } catch (_) {
      throw const PlaylistTransferException(
        PlaylistTransferError.malformedManifest,
        'The playlist transfer manifest is malformed.',
      );
    }
    if (decoded is! Map) {
      throw const PlaylistTransferException(
        PlaylistTransferError.malformedManifest,
        'The playlist transfer manifest is malformed.',
      );
    }
    final manifest = PlaylistTransferManifest.fromJson(Map<String, dynamic>.from(decoded));
    PlaylistTransferCodec._validateManifest(manifest);
    return manifest;
  }

  void clear() {
    _transferId = null;
    _payloadChecksum = null;
    _totalChunks = null;
    _chunks.clear();
  }

  static Uint8List _decompressWithLimit(Uint8List compressed) {
    final sink = _LimitedByteSink(PlaylistTransferCodec.maxDecompressedPayloadBytes);
    try {
      final input = ZLibCodec().decoder.startChunkedConversion(sink);
      const blockSize = 16 * 1024;
      for (var offset = 0; offset < compressed.length; offset += blockSize) {
        input.add(compressed.sublist(offset, (offset + blockSize).clamp(0, compressed.length)));
      }
      input.close();
      return sink.bytes;
    } on PlaylistTransferException {
      rethrow;
    } catch (_) {
      throw const PlaylistTransferException(
        PlaylistTransferError.corruptedChunk,
        'The compressed playlist data is corrupted.',
      );
    }
  }
}

class _LimitedByteSink extends ByteConversionSink {
  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  var _closed = false;

  _LimitedByteSink(this.limit);

  Uint8List get bytes => _builder.takeBytes();

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_closed) throw StateError('Sink is closed');
    if (_builder.length + end - start > limit) {
      throw const PlaylistTransferException(
        PlaylistTransferError.decompressedPayloadTooLarge,
        'The decompressed playlist is too large to import safely.',
      );
    }
    _builder.add(chunk.sublist(start, end));
    if (isLast) close();
  }

  @override
  void close() => _closed = true;
}
