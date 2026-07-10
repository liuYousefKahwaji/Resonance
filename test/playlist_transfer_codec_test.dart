import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';

void main() {
  const ids = ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'aaaaaaaaaaa', 'ccccccccccc'];

  PlaylistTransferManifest roundTrip(EncodedPlaylistTransfer encoded, {bool reverse = false}) {
    final session = PlaylistTransferSession();
    final payloads = reverse ? encoded.qrPayloads.reversed : encoded.qrPayloads;
    for (final payload in payloads) {
      session.acceptChunk(payload);
    }
    return session.reconstructManifest();
  }

  test('manifest serializes, compresses, and deserializes', () {
    const manifest = PlaylistTransferManifest(playlistName: 'Road Trip', youtubeVideoIds: ids);
    final encoded = PlaylistTransferCodec.encode(manifest);
    final decoded = roundTrip(encoded);
    expect(decoded.version, PlaylistTransferCodec.protocolVersion);
    expect(decoded.playlistName, 'Road Trip');
    expect(decoded.youtubeVideoIds, ids);
  });

  test('small playlist creates one QR chunk', () {
    final encoded = PlaylistTransferCodec.encode(
      const PlaylistTransferManifest(playlistName: 'Small', youtubeVideoIds: ['aaaaaaaaaaa']),
    );
    expect(encoded.qrPayloads, hasLength(1));
    expect(encoded.qrPayloads.single, startsWith(PlaylistTransferCodec.prefix));
  });

  test('large encoded data creates multiple QR chunks', () {
    final generated = [for (var i = 0; i < 500; i++) _validId(i)];
    final encoded = PlaylistTransferCodec.encode(
      PlaylistTransferManifest(playlistName: 'Large', youtubeVideoIds: generated),
      chunkDataLength: 64,
    );
    expect(encoded.qrPayloads.length, greaterThan(1));
    expect(roundTrip(encoded).youtubeVideoIds, generated);
  });

  test('chunks can be received out of order', () {
    final generated = [for (var i = 0; i < 300; i++) _validId(i)];
    final encoded = PlaylistTransferCodec.encode(
      PlaylistTransferManifest(playlistName: 'Reverse', youtubeVideoIds: generated),
      chunkDataLength: 64,
    );
    expect(roundTrip(encoded, reverse: true).youtubeVideoIds, generated);
  });

  test('duplicate chunks are ignored', () {
    final encoded = PlaylistTransferCodec.encode(
      const PlaylistTransferManifest(playlistName: 'Duplicate chunk', youtubeVideoIds: ids),
    );
    final session = PlaylistTransferSession();
    expect(session.acceptChunk(encoded.qrPayloads.single), ChunkAcceptance.accepted);
    expect(session.acceptChunk(encoded.qrPayloads.single), ChunkAcceptance.duplicate);
    expect(session.receivedChunkCount, 1);
  });

  test('missing chunks are reported exactly', () {
    final encoded = PlaylistTransferCodec.encode(
      PlaylistTransferManifest(playlistName: 'Missing', youtubeVideoIds: [for (var i = 0; i < 300; i++) _validId(i)]),
      chunkDataLength: 64,
    );
    final session = PlaylistTransferSession();
    for (var i = 0; i < encoded.qrPayloads.length; i++) {
      if (i != 1) session.acceptChunk(encoded.qrPayloads[i]);
    }
    expect(session.missingChunkIndexes, [2]);
    expect(
      session.reconstructManifest,
      throwsA(
        isA<PlaylistTransferException>().having(
          (error) => error.error,
          'error',
          PlaylistTransferError.incompleteTransfer,
        ),
      ),
    );
  });

  test('corrupted chunk is rejected', () {
    final encoded = PlaylistTransferCodec.encode(
      const PlaylistTransferManifest(playlistName: 'Corrupt', youtubeVideoIds: ids),
    );
    final original = encoded.qrPayloads.single;
    final replacement = original.endsWith('A') ? 'B' : 'A';
    final corrupted = '${original.substring(0, original.length - 1)}$replacement';
    expect(
      () => PlaylistTransferSession().acceptChunk(corrupted),
      throwsA(
        isA<PlaylistTransferException>().having((error) => error.error, 'error', PlaylistTransferError.corruptedChunk),
      ),
    );
  });

  test('incorrect complete-payload checksum is rejected', () {
    final encoded = PlaylistTransferCodec.encode(
      const PlaylistTransferManifest(playlistName: 'Checksum', youtubeVideoIds: ids),
    );
    final parts = encoded.qrPayloads.single.split(':');
    parts[5] = '0' * 64;
    final session = PlaylistTransferSession()..acceptChunk(parts.join(':'));
    expect(
      session.reconstructManifest,
      throwsA(
        isA<PlaylistTransferException>().having(
          (error) => error.error,
          'error',
          PlaylistTransferError.incorrectChecksum,
        ),
      ),
    );
  });

  test('chunks from different transfers cannot be mixed', () {
    final first = PlaylistTransferCodec.encode(
      const PlaylistTransferManifest(playlistName: 'One', youtubeVideoIds: ['aaaaaaaaaaa']),
    );
    final second = PlaylistTransferCodec.encode(
      const PlaylistTransferManifest(playlistName: 'Two', youtubeVideoIds: ['bbbbbbbbbbb']),
    );
    final session = PlaylistTransferSession()..acceptChunk(first.qrPayloads.single);
    expect(
      () => session.acceptChunk(second.qrPayloads.single),
      throwsA(
        isA<PlaylistTransferException>().having((error) => error.error, 'error', PlaylistTransferError.mixedTransfers),
      ),
    );
  });

  test('unsupported protocol version has an understandable error', () {
    final encoded = PlaylistTransferCodec.encode(
      const PlaylistTransferManifest(playlistName: 'Future', youtubeVideoIds: ids),
    );
    final futurePayload = encoded.qrPayloads.single.replaceFirst('RESO-PLAYLIST-1:', 'RESO-PLAYLIST-2:');
    expect(
      () => PlaylistTransferSession().acceptChunk(futurePayload),
      throwsA(
        isA<PlaylistTransferException>().having(
          (error) => error.error,
          'error',
          PlaylistTransferError.unsupportedVersion,
        ),
      ),
    );
  });

  test('empty playlist is rejected', () {
    expect(
      () => PlaylistTransferCodec.encode(const PlaylistTransferManifest(playlistName: 'Empty', youtubeVideoIds: [])),
      throwsA(isA<PlaylistTransferException>()),
    );
  });

  test('duplicate playlist entries remain in exact order', () {
    const order = ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'aaaaaaaaaaa', 'ccccccccccc'];
    final decoded = roundTrip(
      PlaylistTransferCodec.encode(const PlaylistTransferManifest(playlistName: 'Duplicates', youtubeVideoIds: order)),
    );
    expect(decoded.youtubeVideoIds, order);
  });

  test('large playlist round trips', () {
    final generated = [for (var i = 0; i < 9000; i++) _validId(i % 1000)];
    final decoded = roundTrip(
      PlaylistTransferCodec.encode(PlaylistTransferManifest(playlistName: 'Very Large', youtubeVideoIds: generated)),
    );
    expect(decoded.youtubeVideoIds, generated);
  });

  test('unicode playlist name round trips', () {
    const name = 'ليل بيروت 🎵 日本語';
    final decoded = roundTrip(
      PlaylistTransferCodec.encode(const PlaylistTransferManifest(playlistName: name, youtubeVideoIds: ids)),
    );
    expect(decoded.playlistName, name);
  });

  test('invalid YouTube ID is rejected', () {
    expect(
      () => PlaylistTransferCodec.encode(
        const PlaylistTransferManifest(playlistName: 'Invalid', youtubeVideoIds: ['not-valid']),
      ),
      throwsA(isA<PlaylistTransferException>()),
    );
  });

  test('maximum entry and QR payload limits are enforced', () {
    expect(
      () => PlaylistTransferCodec.encode(
        PlaylistTransferManifest(
          playlistName: 'Too many',
          youtubeVideoIds: List.filled(PlaylistTransferCodec.maxPlaylistEntries + 1, 'aaaaaaaaaaa'),
        ),
      ),
      throwsA(isA<PlaylistTransferException>()),
    );
    expect(
      () => PlaylistTransferSession().acceptChunk(
        '${PlaylistTransferCodec.prefix}${'x' * PlaylistTransferCodec.maxQrPayloadLength}',
      ),
      throwsA(
        isA<PlaylistTransferException>().having((error) => error.error, 'error', PlaylistTransferError.payloadTooLarge),
      ),
    );
  });

  test('decompressed-size limit rejects compression bombs', () {
    final oversized = List<int>.filled(PlaylistTransferCodec.maxDecompressedPayloadBytes + 1, 65);
    final payloads = _encodeRawPayload(oversized);
    final session = PlaylistTransferSession();
    for (final payload in payloads) {
      session.acceptChunk(payload);
    }
    expect(
      session.reconstructManifest,
      throwsA(
        isA<PlaylistTransferException>().having(
          (error) => error.error,
          'error',
          PlaylistTransferError.decompressedPayloadTooLarge,
        ),
      ),
    );
  });
}

String _validId(int value) => value.toRadixString(36).padLeft(11, '0');

List<String> _encodeRawPayload(List<int> decompressed) {
  final compressed = ZLibCodec(level: 9).encode(decompressed);
  final fullChecksum = sha256.convert(compressed).toString();
  final transferId = fullChecksum.substring(0, 16);
  final encoded = base64UrlEncode(compressed).replaceAll('=', '');
  const chunkLength = 1000;
  final chunks = <String>[];
  for (var offset = 0; offset < encoded.length; offset += chunkLength) {
    chunks.add(encoded.substring(offset, (offset + chunkLength).clamp(0, encoded.length)));
  }
  return [
    for (var index = 0; index < chunks.length; index++)
      '${PlaylistTransferCodec.prefix}$transferId:${index + 1}:${chunks.length}:'
          '${sha256.convert(ascii.encode(chunks[index])).toString().substring(0, 16)}:'
          '$fullChecksum:${chunks[index]}',
  ];
}
