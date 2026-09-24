import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/youtube_music_home_service.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('cached Home is available immediately only for the configured account', () async {
    SharedPreferences.setMockInitialValues({
      'youtube_access.windows_browser_id': 'firefox',
      'youtube_access.windows_configured_at': '2026-09-24T00:00:00.000Z',
      'youtube_music_home.snapshot_v1': jsonEncode({
        'identity': 'windowsBrowser|firefox||2026-09-24T00:00:00.000Z',
        'storedAt': DateTime.now().toIso8601String(),
        'home': {
          'shelves': [
            {
              'title': 'Quick picks',
              'tracks': [
                {'title': 'Cached song', 'artist': 'Artist', 'url': 'https://www.youtube.com/watch?v=jNQXAC9IVRw'},
              ],
            },
          ],
        },
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final access = YoutubeAccessService(preferences: prefs, isWindows: true, isAndroid: false);
    await access.initialize();
    addTearDown(() => YoutubeAccessService.active = null);

    final cached = await const YoutubeMusicHomeService().loadCached();
    expect(cached?.shelves.single.tracks.single.title, 'Cached song');
    await access.clear();
    expect(await const YoutubeMusicHomeService().loadCached(), isNull);
  });

  test('Home decoder preserves playable tracks and collection cards', () {
    final home = const YoutubeMusicHomeService().decodeResponse('''
      {"shelves":[{"title":"New releases","tracks":[],"items":[
        {"title":"An album","subtitle":"Album artist","kind":"Album","thumbnail":"https://img/album","playlistId":"OLAK5uy_test","track":null},
        {"title":"A song","subtitle":"Song artist","kind":"track","track":{
          "title":"A song","artist":"Song artist","url":"https://www.youtube.com/watch?v=homeitem001"
        }}
      ]}]}
    ''');

    expect(home.isEmpty, isFalse);
    expect(home.shelves.single.displayItems, hasLength(2));
    expect(home.shelves.single.displayItems.first.track, isNull);
    expect(home.shelves.single.displayItems.first.playlistUrl, 'https://music.youtube.com/playlist?list=OLAK5uy_test');
    expect(home.shelves.single.tracks.single.videoId, 'homeitem001');
  });

  test('Home album browse IDs remain actionable when no audio playlist ID is exposed', () {
    final home = const YoutubeMusicHomeService().decodeResponse('''
      {"shelves":[{"title":"Albums","items":[
        {"title":"Browse-only album","kind":"Album","browseId":"MPREb_test"}
      ]}]}
    ''');

    expect(home.shelves.single.displayItems.single.playlistUrl, 'https://music.youtube.com/browse/MPREb_test');
  });
}
