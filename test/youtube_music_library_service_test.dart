import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/services/youtube/youtube_music_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late YoutubeAccessService access;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'youtube_access.windows_browser_id': 'firefox',
      'youtube_access.windows_configured_at': '2026-10-04T00:00:00.000Z',
    });
    access = YoutubeAccessService(
      preferences: await SharedPreferences.getInstance(),
      isWindows: true,
      isAndroid: false,
    );
    await access.initialize();
    YoutubeMusicLibraryService.clearCache();
  });
  tearDown(() {
    YoutubeAccessService.active = null;
    YoutubeMusicLibraryService.clearCache();
    access.dispose();
  });

  String payload(int count) => jsonEncode({
    'shelves': [
      {
        'title': 'Playlist Library',
        'tracks': [],
        'items': [
          for (var i = 0; i < count; i++) {'title': 'Playlist $i', 'kind': 'playlist', 'playlistId': 'PL$i'},
        ],
      },
    ],
  });

  test('reads more than the default library page and deduplicates collection cards', () {
    final shelf = const YoutubeMusicLibraryService().decodeResponse(payload(60));
    expect(shelf.items, hasLength(60));
    expect(shelf.items.last.playlistUrl, 'https://music.youtube.com/playlist?list=PL59');
    expect(shelf.tracks, isEmpty);
    final duplicate = const YoutubeMusicLibraryService().decodeResponse('''{"shelves":[{"title":"Library","items":[
      {"title":"One","playlistId":"PL1"},{"title":"Duplicate","playlistId":"PL1"},{"title":"Invalid"}
    ]}]}''');
    expect(duplicate.items, hasLength(1));
    expect(const YoutubeMusicLibraryService().decodeResponse(payload(0)).items, isEmpty);
  });

  test('concurrent requests share a fetch, cache results and refresh explicitly', () async {
    var requests = 0;
    final response = Completer<String>();
    final service = YoutubeMusicLibraryService(
      loader: (_) async {
        requests++;
        return requests == 1 ? response.future : payload(2);
      },
    );
    final first = service.fetch();
    final second = service.fetch();
    expect(requests, 1);
    response.complete(payload(60));
    expect((await first).items, hasLength(60));
    expect((await second).items, hasLength(60));
    expect((await service.fetch()).items, hasLength(60));
    expect(requests, 1);
    expect((await service.fetch(forceRefresh: true)).items, hasLength(2));
    expect(requests, 2);
  });

  test('disk snapshot is scoped to the account and never survives clearing access', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'youtube_music_library.snapshot_v1',
      jsonEncode({
        'identity': 'windowsBrowser|firefox||2026-10-04T00:00:00.000Z',
        'storedAt': DateTime.now().toIso8601String(),
        'data': jsonDecode(payload(3)),
      }),
    );
    const service = YoutubeMusicLibraryService();
    expect((await service.loadCached())?.items, hasLength(3));
    await access.clear();
    expect(await service.loadCached(), isNull);
    expect(service.fetch(), throwsA(anything));
  });

  test('a late result from disconnected access is rejected without writing a snapshot', () async {
    final response = Completer<String>();
    final service = YoutubeMusicLibraryService(loader: (_) => response.future);
    final pending = service.fetch();
    final rejected = expectLater(pending, throwsStateError);
    await access.clear();
    response.complete(payload(4));
    await rejected;
    expect((await SharedPreferences.getInstance()).getString('youtube_music_library.snapshot_v1'), isNull);
  });
}
