import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/widgets/library/playlist_artwork.dart';
import 'package:resonance/widgets/common/progressive_network_artwork.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('preview returns four entries without creating a deleted playlist', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('resonance-preview-');
    addTearDown(() => dir.delete(recursive: true));
    final files = FileService(documentsPathOverride: dir.path);
    await files.replacePlaylistTracks(1, ['a', 'b', 'c', 'd', 'e']);
    expect(await files.readPlaylistPreview(1), ['a', 'b', 'c', 'd']);
    expect(await files.readPlaylistPreview(9), isEmpty);
    expect(await File('${dir.path}/r_playlist_9.m3u8').exists(), isFalse);
  });
  testWidgets('original audio uses cached cover when an embedded picture is unavailable', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late Directory dir;
    late String path;
    const cover = 'https://example.invalid/original-artwork.jpg';
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('resonance-artwork-');
      path = '${dir.path}/original-no-embedded-cover.webm';
      await File(path).writeAsBytes([0]);
      await MetadataCacheService.set(path, 'Original', 'Artist', artworkUrl: cover);
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await MetadataCacheService.flush();
        await dir.delete(recursive: true);
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 34, height: 34, child: PlaylistArtwork(tracks: [path], favorite: false)),
        ),
      ),
    );
    // Each real file/stat stage needs a real-zone turn followed by a widget
    // microtask turn; a single sleep does not drain a multi-stage IO pipeline.
    for (var attempt = 0; attempt < 20 && find.byType(ProgressiveNetworkArtwork).evaluate().isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final artwork = tester.widget<ProgressiveNetworkArtwork>(find.byType(ProgressiveNetworkArtwork));
    expect(artwork.url, cover);
    expect(tester.takeException(), isNull);
  });
}
