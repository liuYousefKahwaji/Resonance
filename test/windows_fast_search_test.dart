import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/windows_fast_search.dart';

void main() {
  test('parses playable video results from the public search page', () {
    const html =
        '''<script>var ytInitialData = {"contents":{"videoRenderer":{"videoId":"jNQXAC9IVRw","title":{"runs":[{"text":"Me at the zoo"}]},"ownerText":{"runs":[{"text":"jawed"}]},"lengthText":{"simpleText":"0:19"},"thumbnail":{"thumbnails":[{"url":"https://img.example/small"},{"url":"https://img.example/large"}]}}}};</script>''';
    final tracks = const WindowsFastSearch().parseHtml(html);
    expect(tracks, hasLength(1));
    expect(tracks.single.title, 'Me at the zoo');
    expect(tracks.single.artist, 'jawed');
    expect(tracks.single.durationSeconds, 19);
    expect(tracks.single.thumbnailUrl, 'https://img.example/large');
    expect(tracks.single.videoId, 'jNQXAC9IVRw');
  });

  test('returns no results when search data is absent', () {
    expect(const WindowsFastSearch().parseHtml('<html>Sign in</html>'), isEmpty);
  });
}
