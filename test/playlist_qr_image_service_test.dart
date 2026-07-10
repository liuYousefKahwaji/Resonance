import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/playlist_qr_image_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generated PNG decodes locally to the exact QR payload', () async {
    final transfer = PlaylistTransferCodec.encode(
      const PlaylistTransferManifest(playlistName: 'QR smoke test', youtubeVideoIds: ['aaaaaaaaaaa', 'bbbbbbbbbbb']),
    );
    final bytes = await PlaylistQrImageService.renderPng(transfer.qrPayloads.single, imageSize: 700, quietZone: 48);
    final directory = await Directory.systemTemp.createTemp('resonance-qr-smoke-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}transfer.png');
    await file.writeAsBytes(bytes);

    expect(await PlaylistQrImageService.decodeFile(file.path), transfer.qrPayloads.single);
  });

  test('QR filenames are sanitized without changing the playlist display name', () {
    expect(PlaylistQrImageService.sanitizeFilename(r'Night:Drive/Windows?'), 'Night_Drive_Windows_');
    expect(PlaylistQrImageService.sanitizeFilename('   '), 'Playlist');
  });
}
