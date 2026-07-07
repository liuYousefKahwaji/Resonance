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
}
