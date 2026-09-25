import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/youtube_music_related_service.dart';

void main() {
  test('related response keeps only playable unique songs and excludes the seed', () {
    final tracks = YoutubeMusicRelatedService.decodeResponse('''
      {"tracks": [
        {"title":"Seed","artist":"A","url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
        {"title":"Next","artist":"B","url":"https://www.youtube.com/watch?v=yPYZpwSpKmA"},
        {"title":"Duplicate","artist":"B","url":"https://www.youtube.com/watch?v=yPYZpwSpKmA"},
        {"title":"Broken","artist":"C","url":"https://example.com/no-video"}
      ]}
    ''', 'dQw4w9WgXcQ');

    expect(tracks.map((track) => track.title), ['Next']);
  });
}
