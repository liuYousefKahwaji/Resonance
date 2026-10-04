import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/services/favorites_repository.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FileService files;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('resonance-favorites-');
    files = FileService(documentsPathOverride: directory.path);
  });
  tearDown(() => directory.delete(recursive: true));

  test('Favorites is permanent, named independently and never promoted over a normal playlist', () async {
    expect(await files.listPlaylistNumbers(), [0, 1]);
    expect((await files.getPlaylistNames())[0], 'Favorites');
    await files.renamePlaylist(0, 'Changed');
    await files.setActivePlaylistNumber(0);
    await files.deletePlaylist(0);
    expect(await files.getActivePlaylistNumber(), 0);
    expect((await files.getPlaylistNames())[0], 'Favorites');
    await files.replacePlaylistTracks(2, ['second']);
    await files.setTrackFavorite('favorite', true);
    await files.deletePlaylist(1);
    expect(await files.readPlaylistTracks(1), ['second']);
    expect(await files.readPlaylistTracks(0), ['favorite']);
    expect(await files.getActivePlaylistNumber(), 0);
    await files.deletePlaylist(1);
    expect(await files.readPlaylistTracks(1), ['second'], reason: 'Keep the last normal playlist as well.');
    expect(await files.createNextPlaylist(), 2);
  });

  test('favorites persist globally, canonicalize URLs and do not alter unrelated membership', () async {
    const youtube = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
    const music = 'https://music.youtube.com/watch?v=jNQXAC9IVRw&list=other';
    await files.replacePlaylistTracks(1, [youtube, 'other']);
    await files.replacePlaylistTracks(2, [music]);
    await files.favoriteTracks([youtube, music, youtube]);
    expect(await files.readPlaylistTracks(0), [youtube]);
    final repository = FavoritesRepository(files: FileService(documentsPathOverride: directory.path));
    addTearDown(repository.dispose);
    await repository.refresh();
    expect(repository.isFavorite(youtube), isTrue);
    expect(repository.isFavorite(music), isTrue);
    await repository.toggle(music);
    expect(repository.isFavorite(youtube), isFalse);
    expect(await files.readPlaylistTracks(1), [youtube, 'other']);
    expect(await files.readPlaylistTracks(2), [music]);
  });

  test('concurrent toggles and bulk additions preserve membership without duplicates', () async {
    await Future.wait([for (var i = 0; i < 12; i++) files.setTrackFavorite('song$i.mp3', true)]);
    expect(await files.readPlaylistTracks(0), hasLength(12));
    await Future.wait([files.toggleTrackFavorite('same.mp3'), files.toggleTrackFavorite('same.mp3')]);
    expect(await files.readPlaylistTracks(0), isNot(contains('same.mp3')));
    await files.favoriteTracks(['song1.mp3', 'new.mp3', 'new.mp3']);
    expect(await files.readPlaylistTracks(0), hasLength(13));
    await files.removeOccurrence(0, 'song1.mp3');
    final reloaded = FavoritesRepository(files: files);
    addTearDown(reloaded.dispose);
    await reloaded.refresh();
    expect(reloaded.isFavorite('song1.mp3'), isFalse);
  });

  test('favorites-first partitions before sorting direction and updates when favorites change', () async {
    await files.replacePlaylistTracks(1, ['D.mp3', 'A.mp3', 'C.mp3', 'B.mp3']);
    await files.favoriteTracks(['A.mp3', 'C.mp3']);
    await files.sortPlaylist(1, PlaylistSortMode.title, favoritesFirst: true);
    expect(await files.readPlaylistTracks(1), ['A.mp3', 'C.mp3', 'B.mp3', 'D.mp3']);
    await files.sortPlaylist(1, PlaylistSortMode.title, descending: true);
    expect(await files.readPlaylistTracks(1), ['C.mp3', 'A.mp3', 'D.mp3', 'B.mp3']);
    await files.setTrackFavorite('A.mp3', false);
    expect(await files.readPlaylistTracks(1), ['C.mp3', 'D.mp3', 'B.mp3', 'A.mp3']);
    final reloaded = FileService(documentsPathOverride: directory.path);
    expect((await reloaded.playlistSortState(1)).favoritesFirst, isTrue);
    await reloaded.sortPlaylist(1, PlaylistSortMode.title, descending: true, favoritesFirst: false);
    expect(await files.readPlaylistTracks(1), ['D.mp3', 'C.mp3', 'B.mp3', 'A.mp3']);
  });

  test('bulk unfavorite removes canonical aliases, preserves other favorites and refreshes sorted playlists', () async {
    const stream = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
    const alias = 'https://music.youtube.com/watch?v=jNQXAC9IVRw&list=other';
    await files.replacePlaylistTracks(1, ['a', stream, 'b']);
    await files.favoriteTracks([stream, 'b', 'outside']);
    await files.sortPlaylist(1, PlaylistSortMode.dateAdded, favoritesFirst: true);
    expect(await files.readPlaylistTracks(1), [stream, 'b', 'a']);
    await files.setTracksFavorite([alias, 'b'], false);
    expect(await files.readPlaylistTracks(0), ['outside']);
    expect(await files.readPlaylistTracks(1), ['a', stream, 'b']);
    final repository = FavoritesRepository(files: files);
    addTearDown(repository.dispose);
    await repository.refresh();
    expect(repository.allFavorite([]), isFalse);
    expect(repository.allFavorite(['outside']), isTrue);
    await repository.setTracks([alias, 'b'], true);
    expect(repository.allFavorite([stream, 'b']), isTrue);
    await repository.setTracks([stream, 'b'], false);
    expect(repository.isFavorite('outside'), isTrue);
    expect(repository.allFavorite([stream, 'b']), isFalse);
  });

  test('date, random and manual sorts preserve their order inside the favorite groups', () {
    const tracks = ['d', 'a', 'c', 'b'];
    for (final mode in PlaylistSortMode.values) {
      for (final descending in [false, true]) {
        final base = PlaylistSortState(mode: mode, descending: descending, seed: 42, addedOrder: tracks);
        final ordinary = base.sorted(tracks);
        final grouped = base.copyWith(favoritesFirst: true).sorted(tracks, favorites: {'a', 'c'});
        expect(grouped, [
          ...ordinary.where((track) => {'a', 'c'}.contains(track)),
          ...ordinary.where((track) => !{'a', 'c'}.contains(track)),
        ]);
      }
    }
  });

  test('download conversion keeps favorite identity and sorting across stream and file playlists', () async {
    const stream = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
    const music = 'https://music.youtube.com/watch?v=jNQXAC9IVRw';
    final local = '${directory.path}/download.mp3';
    await files.replacePlaylistTracks(1, ['a', stream]);
    await files.replacePlaylistTracks(2, ['a', music]);
    await files.setTrackFavorite(stream, true);
    await files.sortPlaylist(1, PlaylistSortMode.dateAdded, favoritesFirst: true);
    await files.sortPlaylist(2, PlaylistSortMode.dateAdded, favoritesFirst: true);
    await const TrackSourceRepository().saveSource(
      localPath: local,
      youtubeVideoId: 'jNQXAC9IVRw',
      method: TrackSourceMethod.downloadedByResonance,
    );
    await files.replaceStreamWithDownload(1, stream, local);
    expect(await files.readPlaylistTracks(0), [local]);
    expect(await files.readPlaylistTracks(1), [local, 'a']);
    expect(await files.readPlaylistTracks(2), [music, 'a']);
    final repository = FavoritesRepository(files: files);
    addTearDown(repository.dispose);
    await repository.refresh();
    expect(repository.isFavorite(stream), isTrue);
    expect(repository.isFavorite(local), isTrue);
    await repository.toggle(music);
    expect(await files.readPlaylistTracks(0), isEmpty);
  });
}
