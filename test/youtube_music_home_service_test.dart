import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/youtube_music_home_service.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(YoutubeMusicHomeService.clearCache);
  tearDown(YoutubeMusicHomeService.clearCache);

  test('English and Arabic Home requests and snapshots stay separate even with late results', () async {
    SharedPreferences.setMockInitialValues({
      'youtube_access.windows_browser_id': 'firefox',
      'youtube_access.windows_configured_at': '2026-09-24T00:00:00.000Z',
    });
    final prefs = await SharedPreferences.getInstance();
    final access = YoutubeAccessService(preferences: prefs, isWindows: true, isAndroid: false);
    await access.initialize();
    addTearDown(() {
      YoutubeAccessService.active = null;
      access.dispose();
    });
    final responses = {'en': Completer<String>(), 'ar': Completer<String>()};
    final requests = <String>[];
    Future<String> load(int limit, String language) {
      requests.add(language);
      return responses[language]!.future;
    }

    final english = YoutubeMusicHomeService(loader: load);
    final arabic = YoutubeMusicHomeService(language: 'ar', loader: load);
    final en = english.fetch();
    final ar = arabic.fetch();
    final arAgain = arabic.fetch();
    expect(requests, ['en', 'ar']);
    String payload(String title) => jsonEncode({
      'shelves': [
        {
          'title': title,
          'kind': 'quickPicks',
          'tracks': [
            {'title': 'Original song', 'artist': 'Artist', 'url': 'https://www.youtube.com/watch?v=jNQXAC9IVRw'},
          ],
        },
      ],
    });
    responses['ar']!.complete(payload('اختيارات سريعة'));
    final localized = await ar;
    expect(identical(await arAgain, localized), isTrue);
    expect(localized.shelves.single.kind, 'quickPicks');
    responses['en']!.complete(payload('Quick picks'));
    await en;
    expect(identical(await arabic.fetch(), localized), isTrue);
    expect((await english.fetch()).shelves.single.title, 'Quick picks');
    await Future<void>.delayed(Duration.zero);
    YoutubeMusicHomeService.clearCache();
    expect((await arabic.loadCached())!.shelves.single.title, 'اختيارات سريعة');
    expect((await english.loadCached())!.shelves.single.title, 'Quick picks');
    await prefs.remove('youtube_music_home.snapshot_v1.ar');
    YoutubeMusicHomeService.clearCache();
    expect(await arabic.loadCached(), isNull);
  });

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
