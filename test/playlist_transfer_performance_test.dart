import 'package:resonance/services/youtube/youtube_request.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/youtube_download_result.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/youtube_transfer_service.dart';
import 'package:resonance/widgets/youtube/windows_youtube.dart';
import 'package:resonance/screens/playlist_transfer/playlist_import_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MetadataCacheService.clear();
  });
  tearDown(MetadataCacheService.flush);

  test('transfer download starts without waiting for a separate metadata extraction', () async {
    final backend = _DownloadBackend();
    final service = YoutubeTransferService(windowsDownloader: backend);
    final result = await service
        .downloadVideo('aaaaaaaaaaa', onProgress: (_, __) {})
        .timeout(const Duration(seconds: 1));
    expect(backend.metadataRequests, 0);
    expect(backend.downloadRequests, 1);
    expect(result.localPath, 'song.mp3');
    expect(result.title, 'Ready');
    expect(result.artist, 'Artist');
  });

  test('transfer names are cached immediately with no remote lookups', () async {
    final service = YoutubeTransferService(windowsDownloader: _DownloadBackend());
    await service.prepareStreams(
      const PlaylistTransferManifest(
        playlistName: 'Named',
        youtubeVideoIds: ['aaaaaaaaaaa'],
        trackMetadata: {'aaaaaaaaaaa': PlaylistTransferTrackMetadata(title: 'أغنية', artist: 'Artist')},
      ),
    );
    final metadata = await MetadataCacheService.get('https://www.youtube.com/watch?v=aaaaaaaaaaa');
    expect(metadata!.title, 'أغنية');
    expect(metadata.artist, 'Artist');
  });

  testWidgets('Stream From Playlist completes even when the metadata extractor never responds', (tester) async {
    SharedPreferences.setMockInitialValues({'download_directory': 'Test downloads'});
    final backend = _DownloadBackend();
    final directory = await tester.runAsync(() => Directory.systemTemp.createTemp('resonance-transfer-ui-'));
    final files = FileService(documentsPathOverride: directory!.path);
    int? importedNumber;
    bool? syncRequested;
    addTearDown(() => directory.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistImportScreen(
          files: files,
          youtube: YoutubeTransferService(windowsDownloader: backend),
          onImported: (number, streaming, keep) {
            importedNumber = number;
            syncRequested = keep;
            expect(streaming, isTrue);
          },
          initialManifest: const PlaylistTransferManifest(
            playlistName: 'Fast mix',
            youtubeVideoIds: ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'aaaaaaaaaaa'],
          ),
        ),
      ),
    );
    Future<void> waitFor(String text) async {
      for (var attempt = 0; attempt < 40 && find.text(text).evaluate().isEmpty; attempt++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      await tester.pump();
      expect(
        find.text(text),
        findsOneWidget,
        reason: tester.allWidgets.whereType<Text>().map((widget) => widget.data).join(' | '),
      );
    }

    await waitFor('Stream From Playlist');
    await tester.ensureVisible(find.byType(SwitchListTile));
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.ensureVisible(find.text('Stream From Playlist'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Stream From Playlist'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await waitFor('Import complete');
    expect(backend.metadataRequests, 0);
    expect(tester.takeException(), isNull);
    expect(importedNumber, isNotNull);
    expect(syncRequested, isTrue);
  });

  test('ID-only streams are ready without metadata/network calls and keep duplicate order', () async {
    final backend = _DownloadBackend();
    final service = YoutubeTransferService(windowsDownloader: backend);
    const manifest = PlaylistTransferManifest(
      playlistName: 'Instant',
      youtubeVideoIds: ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'aaaaaaaaaaa'],
    );
    final resolved = await service.prepareStreams(manifest);
    expect(backend.metadataRequests, 0);
    expect(backend.downloadRequests, 0);
    final directory = await Directory.systemTemp.createTemp('resonance-fast-transfer-');
    addTearDown(() => directory.delete(recursive: true));
    final files = FileService(documentsPathOverride: directory.path);
    final playlist = await files.createImportedPlaylist(manifest.playlistName, [
      for (final id in manifest.youtubeVideoIds) resolved[id]!,
    ]);
    expect(await files.readPlaylistTracks(playlist.number), [
      'https://www.youtube.com/watch?v=aaaaaaaaaaa',
      'https://www.youtube.com/watch?v=bbbbbbbbbbb',
      'https://www.youtube.com/watch?v=aaaaaaaaaaa',
    ]);
  });
}

class _DownloadBackend extends MediaDownloader {
  int metadataRequests = 0, downloadRequests = 0;
  @override
  Future<void> initBinaries() async {}
  @override
  Future<YoutubeTrack> lookup(String url) {
    metadataRequests++;
    return Completer<YoutubeTrack>().future;
  }

  @override
  Future<void> downloadAudio({
    required String url,
    required Function(double, String) onProgress,
    required Function(String, String?) onTrackDownloaded,
    YoutubeRequest? request,
    String? historyTitle,
    String? historyArtist,
    FutureOr<void> Function(YoutubeDownloadResult track)? onTrackPrepared,
  }) async {
    downloadRequests++;
    await onTrackPrepared?.call(
      const YoutubeDownloadResult(
        localPath: 'song.mp3',
        youtubeVideoId: 'aaaaaaaaaaa',
        title: 'Ready',
        artist: 'Artist',
      ),
    );
    await onTrackDownloaded('song.mp3', 'aaaaaaaaaaa');
  }
}
