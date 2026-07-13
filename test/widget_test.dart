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

  test('deleting playlist 1 promotes the next playlist instead of creating an empty replacement', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-promote-playlist-');
    addTearDown(() => directory.delete(recursive: true));
    final service = FileService(documentsPathOverride: directory.path);

    await service.renamePlaylist(1, 'Old Main');
    final second = await service.createNextPlaylist();
    await service.renamePlaylist(second, 'Keep Me');
    await service.writeTextToPlaylist(second, '#\nsecond-track.mp3\n');
    final third = await service.createNextPlaylist();
    await service.renamePlaylist(third, 'Later');
    await service.setActivePlaylistNumber(1);

    final active = await service.deletePlaylist(1);

    expect(active, 1);
    expect(await service.listPlaylistNumbers(), [1, 3]);
    expect((await service.getPlaylistNames())[1], 'Keep Me');
    expect(await service.readTextFromPlaylist(1), contains('second-track.mp3'));
    expect(await service.readTextFromPlaylist(1), isNot(contains('Old Main')));
  });

  test('a track can be removed from every playlist while preserving other entries', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-remove-everywhere-');
    addTearDown(() => directory.delete(recursive: true));
    final service = FileService(documentsPathOverride: directory.path, isWindowsOverride: true);
    const target = r'C:\Music\Target.mp3';
    const alternateTarget = r'c:\music\.\TARGET.mp3';

    await service.writeTextToPlaylist(1, '#\n$target\nkeep-one.mp3\n$target\n');
    final second = await service.createNextPlaylist();
    await service.writeTextToPlaylist(second, '#\n$alternateTarget\nkeep-two.mp3\n');

    await service.removeTrackFromAllPlaylists(target);

    expect(await service.readTextFromPlaylist(1), '#\nkeep-one.mp3\n');
    expect(await service.readTextFromPlaylist(second), '#\nkeep-two.mp3\n');
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

  test('explicit playlist writes do not follow a later active-playlist change', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-explicit-playlist-');
    addTearDown(() => directory.delete(recursive: true));
    final service = FileService(documentsPathOverride: directory.path);

    final capturedPlaylist = await service.createNextPlaylist();
    await service.setActivePlaylistNumber(1);
    await service.addToPlaylist(capturedPlaylist, 'https://www.youtube.com/watch?v=aaaaaaaaaaa');

    expect(await service.readTextFromPlaylist(1), isNot(contains('aaaaaaaaaaa')));
    expect(await service.readTextFromPlaylist(capturedPlaylist), contains('aaaaaaaaaaa'));
  });

  test('track index lookup uses normalized Windows paths', () async {
    SharedPreferences.setMockInitialValues({});
    final service = FileService(isWindowsOverride: true);
    expect(
      service.findTrackIndex(const [
        r'C:\Music\First.mp3',
        r'C:\Music\Folder\Target.mp3',
      ], r'c:\music\folder\.\TARGET.mp3'),
      1,
    );
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
