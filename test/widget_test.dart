import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('playlists can be created, renamed, and deleted', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-playlists-');
    addTearDown(() => directory.delete(recursive: true));
    final service = FileService(documentsPathOverride: directory.path);

    expect(await service.listPlaylistNumbers(), [1]);
    final created = await service.createNextPlaylist();
    expect(created, 2);
    expect(await service.getActivePlaylistNumber(), 2);

    await service.renamePlaylist(created, 'Night Drive');
    expect((await service.getPlaylistNames())[created], 'Night Drive');

    final activeAfterDelete = await service.deletePlaylist(created);
    expect(activeAfterDelete, 1);
    expect(await service.listPlaylistNumbers(), [1]);
  });

  test('track lookup prefers the active playlist when a track is duplicated', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-track-lookup-');
    addTearDown(() => directory.delete(recursive: true));
    final service = FileService(documentsPathOverride: directory.path);
    const track = r'C:\Music\Track.mp3';

    await service.writeTextToFile('#\n$track\n');
    final second = await service.createNextPlaylist();
    await service.writeTextToFile('#\n$track\n');

    expect(await service.findPlaylistContaining(track, preferredPlaylistNumber: second), second);
  });

  test('imported playlists preserve internal numbering, display names, order, and duplicates', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-imported-playlist-');
    addTearDown(() => directory.delete(recursive: true));
    final service = FileService(documentsPathOverride: directory.path);

    await service.renamePlaylist(1, 'Road Trip');
    final created = await service.createImportedPlaylist('Road Trip', const ['A.mp3', 'B.mp3', 'A.mp3']);

    expect(created.number, 2);
    expect(created.displayName, 'Road Trip (2)');
    expect((await service.getPlaylistNames())[2], 'Road Trip (2)');
    expect(await File('${directory.path}${Platform.pathSeparator}r_playlist_2.m3u8').readAsLines(), [
      '#',
      'A.mp3',
      'B.mp3',
      'A.mp3',
    ]);
  });
}
