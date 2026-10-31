import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FileService files;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('resonance-undo-');
    files = FileService(documentsPathOverride: directory.path);
    await files.replacePlaylistTracks(1, ['a', 'b', 'a', 'c']);
  });
  tearDown(() => directory.delete(recursive: true));

  test('undo restores duplicate occurrences, exact order and sort settings once', () async {
    final before = await files.playlistSortState(1);
    final undo = await files.editPlaylistsWithUndo(
      {
        1: ['a', 'a', 'c'],
      },
      expected: {
        1: ['a', 'b', 'a', 'c'],
      },
    );
    expect(await undo!.undo(), isTrue);
    expect(await files.readPlaylistTracks(1), ['a', 'b', 'a', 'c']);
    expect((await files.playlistSortState(1)).toJson(), before.toJson());
    expect(await undo.undo(), isFalse);
  });
  test('clear and manual reordering are undoable', () async {
    final undo = await files.editPlaylistsWithUndo({1: []});
    expect(await files.readPlaylistTracks(1), isEmpty);
    expect(await undo!.undo(), isTrue);
    final reorder = await files.editPlaylistsWithUndo({
      1: ['c', 'a', 'b', 'a'],
    }, manual: true);
    expect((await files.playlistSortState(1)).mode, PlaylistSortMode.custom);
    expect(await reorder!.undo(), isTrue);
    expect(await files.readPlaylistTracks(1), ['a', 'b', 'a', 'c']);
    expect((await files.playlistSortState(1)).mode, PlaylistSortMode.dateAdded);
  });
  test('undo refuses a later edit or sync change without discarding it', () async {
    final undo = await files.editPlaylistsWithUndo({
      1: ['a', 'c'],
    });
    await files.appendTrack(1, 'synced');
    expect(await undo!.undo(), isFalse);
    expect(await files.readPlaylistTracks(1), ['a', 'c', 'synced']);
  });
  test('a move restores both lists and refuses partial undo on conflict', () async {
    await files.replacePlaylistTracks(2, ['target']);
    final undo = await files.editPlaylistsWithUndo({
      1: ['a', 'a', 'c'],
      2: ['target', 'b'],
    });
    expect(await undo!.undo(), isTrue);
    expect(await files.readPlaylistTracks(2), ['target']);
    final conflict = await files.editPlaylistsWithUndo({
      1: ['a', 'c'],
      2: ['target', 'b', 'a'],
    });
    await files.appendTrack(2, 'new');
    expect(await conflict!.undo(), isFalse);
    expect(await files.readPlaylistTracks(1), ['a', 'c']);
    expect(await files.readPlaylistTracks(2), ['target', 'b', 'a', 'new']);
  });
  test('stale selection validates all lists before writing', () async {
    await files.replacePlaylistTracks(2, ['target']);
    await expectLater(
      files.editPlaylistsWithUndo(
        {
          1: [],
          2: ['a'],
        },
        expected: {
          1: ['stale'],
        },
      ),
      throwsStateError,
    );
    expect(await files.readPlaylistTracks(2), ['target']);
    expect(await files.readPlaylistTracks(1), ['a', 'b', 'a', 'c']);
  });
  test('undoing deletion of primary playlist keeps promoted list and later edits', () async {
    await files.renamePlaylist(1, 'Removed');
    await files.replacePlaylistTracks(2, ['kept']);
    await files.renamePlaylist(2, 'Promoted');
    final undo = await files.deletePlaylistWithUndo(1);
    await files.appendTrack(1, 'later');
    expect(await undo!.undo(), isTrue);
    expect(await files.readPlaylistTracks(1), ['kept', 'later']);
    final names = await files.getPlaylistNames();
    final restored = names.entries.singleWhere((e) => e.value == 'Removed').key;
    expect(restored, isNot(1));
    expect(await files.readPlaylistTracks(restored), ['a', 'b', 'a', 'c']);
    expect(names[1], 'Promoted');
  });
  test('Favorites is protected; bulk favorites undo preserves earlier favorites', () async {
    await files.setTracksFavorite(['a'], true);
    final undo = await files.setTracksFavoriteWithUndo(['b', 'c'], true);
    expect(await undo!.undo(), isTrue);
    expect(await files.readPlaylistTracks(0), ['a']);
    expect(await files.deletePlaylistWithUndo(0), isNull);
    expect(await files.readPlaylistTracks(0), ['a']);
  });
  test('sorting undo restores previous insertion order', () async {
    final state = (await files.playlistSortState(1)).copyWith(mode: PlaylistSortMode.random, seed: 123);
    final undo = await files.editPlaylistsWithUndo({1: await files.readPlaylistTracks(1)}, sortStates: {1: state});
    expect(await undo!.undo(), isTrue);
    expect(await files.readPlaylistTracks(1), ['a', 'b', 'a', 'c']);
  });
  test('primary promotion waits for an in-flight edit of the promoted list', () async {
    await files.replacePlaylistTracks(2, ['kept']);
    final gated = _GatedFiles(directory.path)..gate = true;
    final edit = gated.editPlaylistsWithUndo({
      2: ['newly edited'],
    });
    await gated.entered.future;
    var deleted = false;
    final deletion = gated.deletePlaylistWithUndo(1).then((value) {
      deleted = true;
      return value;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(deleted, isFalse);
    expect(await File('${directory.path}/r_playlist_1.m3u8').exists(), isTrue);
    gated.release.complete();
    await edit;
    await deletion;
    expect(await files.readPlaylistTracks(1), ['newly edited']);
  });
}

class _GatedFiles extends FileService {
  _GatedFiles(String root) : super(documentsPathOverride: root);
  bool gate = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<List<String>> readPlaylistTracks(int number) async {
    if (gate && number == 2) {
      gate = false;
      entered.complete();
      await release.future;
    }
    return super.readPlaylistTracks(number);
  }
}
