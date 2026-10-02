import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FileService service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('resonance-sort-test-');
    service = FileService(documentsPathOverride: directory.path);
  });
  tearDown(() => directory.delete(recursive: true));

  test('unsorted replacements retain producer order until sorting is explicitly selected', () async {
    await service.replacePlaylistTracks(1, ['a', 'b', 'c']);
    await service.replacePlaylistTracks(1, ['c', 'a', 'b']);
    expect(await service.readPlaylistTracks(1), ['c', 'a', 'b']);
    await service.sortPlaylist(1, PlaylistSortMode.dateAdded);
    expect(await service.readPlaylistTracks(1), ['a', 'b', 'c']);
  });

  test('alphanumeric order handles numbers, case, descending and duplicates', () async {
    await service.replacePlaylistTracks(1, ['Track 10.mp3', 'track 2.mp3', 'Alpha.mp3', 'track 2.mp3']);
    await service.sortPlaylist(1, PlaylistSortMode.title);
    expect(await service.readPlaylistTracks(1), ['Alpha.mp3', 'track 2.mp3', 'track 2.mp3', 'Track 10.mp3']);
    await service.sortPlaylist(1, PlaylistSortMode.title, descending: true);
    expect(await service.readPlaylistTracks(1), ['Track 10.mp3', 'track 2.mp3', 'track 2.mp3', 'Alpha.mp3']);
  });

  test('date added survives sorting, manual reorder, deletions and re-adds', () async {
    await service.replacePlaylistTracks(1, ['c', 'a', 'b']);
    await service.sortPlaylist(1, PlaylistSortMode.title);
    await service.reorderPlaylistNumber(1, ['b', 'a', 'c']);
    expect((await service.playlistSortState(1)).mode, PlaylistSortMode.custom);
    await service.removeOccurrence(1, 'a');
    await service.appendTrack(1, 'a');
    await service.sortPlaylist(1, PlaylistSortMode.dateAdded);
    expect(await service.readPlaylistTracks(1), ['c', 'b', 'a']);
    await service.sortPlaylist(1, PlaylistSortMode.dateAdded, descending: true);
    expect(await service.readPlaylistTracks(1), ['a', 'b', 'c']);
    await service.appendTrack(1, 'd');
    expect(await service.readPlaylistTracks(1), ['d', 'a', 'b', 'c']);
  });

  test('random is repeatable after reload and preserves existing order on append', () async {
    final tracks = [for (var i = 0; i < 30; i++) 'song$i'];
    await service.replacePlaylistTracks(1, tracks);
    await service.sortPlaylist(1, PlaylistSortMode.random);
    final first = await service.readPlaylistTracks(1);
    final reloaded = FileService(documentsPathOverride: directory.path);
    await reloaded.sortPlaylist(1, PlaylistSortMode.random);
    expect(await reloaded.readPlaylistTracks(1), first);
    await reloaded.appendTrack(1, 'new song');
    final withNew = await reloaded.readPlaylistTracks(1);
    expect(withNew.where((track) => track != 'new song').toList(), first);
    expect(withNew.toSet(), {...tracks, 'new song'});
    await reloaded.sortPlaylist(1, PlaylistSortMode.random, reroll: true);
    expect(await reloaded.readPlaylistTracks(1), isNot(withNew));
  });

  test('concurrent sorted imports retain all songs and follow selected order', () async {
    await service.sortPlaylist(1, PlaylistSortMode.title);
    await Future.wait([for (var i = 20; i > 0; i--) service.appendTrack(1, 'song$i')]);
    expect(await service.readPlaylistTracks(1), [for (var i = 1; i <= 20; i++) 'song$i']);
  });

  test('stream replacement retains date slot and playlist promotion retains preferences', () async {
    await service.replacePlaylistTracks(1, ['primary']);
    await service.replacePlaylistTracks(2, ['before', 'https://stream', 'after']);
    await service.sortPlaylist(2, PlaylistSortMode.dateAdded, descending: true);
    await service.replaceStreamWithDownload(2, 'https://stream', 'local.mp3');
    expect(await service.readPlaylistTracks(2), ['after', 'local.mp3', 'before']);
    await service.deletePlaylist(1);
    expect((await service.playlistSortState(1)).descending, isTrue);
    await service.sortPlaylist(1, PlaylistSortMode.dateAdded);
    expect(await service.readPlaylistTracks(1), ['before', 'local.mp3', 'after']);
  });
}
