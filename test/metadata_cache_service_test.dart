import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the metadata cache version affected by cross-playlist contamination is discarded', () async {
    final directory = await Directory.systemTemp.createTemp('resonance_metadata_cache_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}new-track.mp3');
    await file.writeAsBytes(const [0]);
    final modified = (await file.lastModified()).millisecondsSinceEpoch;

    SharedPreferences.setMockInitialValues({
      'track_metadata_cache_v1': jsonEncode({
        file.path: {
          'title': 'Wrong title from Playlist 1',
          'artist': 'Wrong artist from Playlist 1',
          'mtime': modified,
          'isStream': false,
        },
        'https://www.youtube.com/watch?v=aaaaaaaaaaa': {
          'title': 'Existing stream title',
          'artist': 'Existing stream artist',
          'mtime': 0,
          'isStream': true,
        },
      }),
    });

    expect(await MetadataCacheService.get(file.path), isNull);
    final stream = await MetadataCacheService.get('https://www.youtube.com/watch?v=aaaaaaaaaaa');
    expect(stream?.title, 'Existing stream title');
    expect(stream?.artist, 'Existing stream artist');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('track_metadata_cache_v1'), isFalse);
  });

  test('stream artwork persists and legacy YouTube streams derive a thumbnail', () async {
    await MetadataCacheService.clear();
    SharedPreferences.setMockInitialValues({});
    const url = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';

    await MetadataCacheService.set(url, 'Stream title', 'Stream artist', artworkUrl: 'https://img.test/cover.jpg');
    expect((await MetadataCacheService.get(url))?.artworkUrl, 'https://img.test/cover.jpg');

    await MetadataCacheService.set(url, 'Updated title', 'Stream artist');
    expect((await MetadataCacheService.get(url))?.artworkUrl, 'https://img.test/cover.jpg');

    await MetadataCacheService.set('https://www.youtube.com/watch?v=ccccccccccc', 'Legacy title', 'Legacy artist');
    expect(
      (await MetadataCacheService.get('https://www.youtube.com/watch?v=ccccccccccc'))?.artworkUrl,
      'https://i.ytimg.com/vi/ccccccccccc/hqdefault.jpg',
    );
  });
}
