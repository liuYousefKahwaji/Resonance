import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/android_auto_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('car catalog browses playlists and resolves a selected local track', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-car-catalog-');
    addTearDown(() => directory.delete(recursive: true));
    final audio = File('${directory.path}/Song.mp3')..writeAsBytesSync([1, 2, 3]);
    final files = FileService(documentsPathOverride: directory.path, isWindowsOverride: false);
    await files.addToPlaylist(1, audio.path);
    final catalog = AndroidAutoCatalog(files: files);

    final root = await catalog.children(AudioService.browsableRootId);
    expect(root, hasLength(2));
    expect(root.first.title, 'Favorites');
    final ordinary = root.last;
    expect(ordinary.playable, isFalse);
    expect((await catalog.item(ordinary.id))?.title, ordinary.title);
    final tracks = await catalog.children(ordinary.id);
    expect(tracks, hasLength(1));
    expect(tracks.single.title, 'Song');
    expect((await catalog.item(tracks.single.id))?.title, 'Song');
    expect((await catalog.resolve(tracks.single.id))?.path, audio.path);

    final other = File('${directory.path}/Other.mp3')..writeAsBytesSync([4, 5, 6]);
    await files.reorderPlaylistNumber(1, [other.path, audio.path]);
    expect((await catalog.resolve(tracks.single.id))?.index, 1);

    await files.reorderPlaylistNumber(1, [audio.path, other.path, audio.path]);
    final duplicateRows = await catalog.children(ordinary.id);
    expect(duplicateRows[0].id, isNot(duplicateRows[2].id));
    expect((await catalog.resolve(duplicateRows[2].id))?.index, 2);

    await audio.delete();
    expect(await catalog.resolve(tracks.single.id), isNull);
  });

  test('car media IDs reject malformed locations', () {
    final valid = AndroidAutoCatalog.trackId(1, 'https://example.com/song?a=1');
    expect(AndroidAutoCatalog.parseTrackId(valid), (
      playlist: 1,
      source: 'https://example.com/song?a=1',
      occurrence: 0,
    ));
    expect(
      AndroidAutoCatalog.parseTrackId(valid.replaceFirst('track:1:', 'track:0:'))?.playlist,
      FileService.favoritesPlaylistNumber,
    );
    expect(AndroidAutoCatalog.parseTrackId(valid.replaceFirst('track:1:', 'track:-1:')), isNull);
    expect(AndroidAutoCatalog.parseTrackId('resonance:track:1:-1'), isNull);
    expect(AndroidAutoCatalog.parseTrackId('$valid:extra'), isNull);
  });
}
