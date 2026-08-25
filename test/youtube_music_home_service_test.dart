import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/youtube_music_home_service.dart';

void main() {
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
