import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_download_result.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/youtube_playlist_import_service.dart';
import 'package:resonance/services/youtube_transfer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stream imports preserve source order and duplicate playlist entries', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-stream-import-');
    addTearDown(() => directory.delete(recursive: true));
    final fileService = FileService(documentsPathOverride: directory.path);
    final service = YoutubePlaylistImportService(fileService: fileService);

    final result = await service.importPlaylist(
      playlistName: 'Imported Mix',
      mode: YoutubePlaylistImportMode.stream,
      entries: const [
        YoutubePlaylistImportEntry(videoId: 'aaaaaaaaaaa', title: 'First', artist: 'Artist A'),
        YoutubePlaylistImportEntry(videoId: 'bbbbbbbbbbb', title: 'Second', artist: 'Artist B'),
        YoutubePlaylistImportEntry(videoId: 'aaaaaaaaaaa', title: 'First', artist: 'Artist A'),
      ],
    );

    expect(result.streamed, 2);
    expect(result.playlistEntries, 3);
    expect(
      await File('${directory.path}${Platform.pathSeparator}r_playlist_${result.playlistNumber}.m3u8').readAsLines(),
      [
        '#',
        TrackSourceRepository.canonicalUrlFor('aaaaaaaaaaa'),
        TrackSourceRepository.canonicalUrlFor('bbbbbbbbbbb'),
        TrackSourceRepository.canonicalUrlFor('aaaaaaaaaaa'),
      ],
    );
    final cached = await MetadataCacheService.get(TrackSourceRepository.canonicalUrlFor('aaaaaaaaaaa'));
    expect(cached?.title, 'First');
    expect(cached?.artist, 'Artist A');
  });

  test('download imports fetch duplicate YouTube IDs only once and preserve their positions', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-download-import-');
    addTearDown(() => directory.delete(recursive: true));
    final fileService = FileService(documentsPathOverride: directory.path);
    final youtube = _FakeYoutubeTransferService(directory.path);
    final service = YoutubePlaylistImportService(fileService: fileService, youtube: youtube);

    final result = await service.importPlaylist(
      playlistName: 'Downloaded Mix',
      mode: YoutubePlaylistImportMode.download,
      entries: const [
        YoutubePlaylistImportEntry(videoId: 'aaaaaaaaaaa', title: 'First', artist: 'Artist A'),
        YoutubePlaylistImportEntry(videoId: 'bbbbbbbbbbb', title: 'Second', artist: 'Artist B'),
        YoutubePlaylistImportEntry(videoId: 'aaaaaaaaaaa', title: 'First', artist: 'Artist A'),
      ],
    );

    expect(youtube.downloadedIds, ['aaaaaaaaaaa', 'bbbbbbbbbbb']);
    expect(youtube.downloadedTitles, ['First', 'Second']);
    expect(youtube.downloadedArtists, ['Artist A', 'Artist B']);
    expect(result.downloaded, 2);
    expect(result.playlistEntries, 3);
    expect(
      await File('${directory.path}${Platform.pathSeparator}r_playlist_${result.playlistNumber}.m3u8').readAsLines(),
      [
        '#',
        '${directory.path}${Platform.pathSeparator}aaaaaaaaaaa.mp3',
        '${directory.path}${Platform.pathSeparator}bbbbbbbbbbb.mp3',
        '${directory.path}${Platform.pathSeparator}aaaaaaaaaaa.mp3',
      ],
    );
  });
}

class _FakeYoutubeTransferService extends YoutubeTransferService {
  final String directory;
  final List<String> downloadedIds = [];
  final List<String?> downloadedTitles = [];
  final List<String?> downloadedArtists = [];

  _FakeYoutubeTransferService(this.directory);

  @override
  Future<YoutubeDownloadResult> downloadVideo(
    String videoId, {
    required void Function(double percentage, String status) onProgress,
    TrackSourceMethod sourceMethod = TrackSourceMethod.importedFromQrTransfer,
    String? historyTitle,
    String? historyArtist,
  }) async {
    downloadedIds.add(videoId);
    downloadedTitles.add(historyTitle);
    downloadedArtists.add(historyArtist);
    onProgress(100, 'Done');
    return YoutubeDownloadResult(localPath: '$directory${Platform.pathSeparator}$videoId.mp3', youtubeVideoId: videoId);
  }
}
