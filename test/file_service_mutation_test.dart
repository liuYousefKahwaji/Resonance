import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rapid explicit playlist appends are serialized without lost tracks', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-playlist-mutations-');
    addTearDown(() => directory.delete(recursive: true));
    final service = FileService(documentsPathOverride: directory.path);
    final mutations = <PlaylistMutation>[];
    final subscription = FileService.mutations.listen(mutations.add);
    addTearDown(subscription.cancel);

    await Future.wait([
      for (var index = 0; index < 25; index++)
        service.appendTrack(1, 'https://www.youtube.com/watch?v=queue${index.toString().padLeft(6, '0')}'),
    ]);

    final tracks = await service.readPlaylistTracks(1);
    expect(tracks, hasLength(25));
    expect(tracks.toSet(), hasLength(25));
    expect(
      mutations.where((mutation) => mutation.playlistNumber == 1 && mutation.kind == PlaylistMutationKind.appended),
      hasLength(25),
    );
  });

  test('replace and remove target an explicit playlist', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-playlist-explicit-');
    addTearDown(() => directory.delete(recursive: true));
    final service = FileService(documentsPathOverride: directory.path);

    await service.replacePlaylistTracks(2, const ['one', 'two', 'three']);
    expect(await service.removeOccurrence(2, 'two', playlistIndex: 1), isTrue);
    expect(await service.readPlaylistTracks(2), const ['one', 'three']);
    expect(await service.readPlaylistTracks(1), isEmpty);
  });
}
