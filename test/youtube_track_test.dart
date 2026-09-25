import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/youtube_track.dart';

void main() {
  test('search result parses complete metadata and canonicalizes a video id', () {
    final track = YoutubeTrack.fromJson({
      'id': 'aaaaaaaaaaa',
      'url': 'aaaaaaaaaaa',
      'title': 'A complete title',
      'uploader': 'An artist',
      'duration_seconds': 3661,
      'thumbnail': 'https://img.example/cover.jpg',
    });

    expect(track.url, 'https://www.youtube.com/watch?v=aaaaaaaaaaa');
    expect(track.artist, 'An artist');
    expect(track.formattedDuration, '1:01:01');
    expect(track.thumbnailUrl, 'https://img.example/cover.jpg');
  });

  test('search result uses the best thumbnail and channel fallback', () {
    final track = YoutubeTrack.fromJson({
      'webpage_url': 'https://www.youtube.com/watch?v=bbbbbbbbbbb',
      'title': 'Track',
      'channel': 'Channel',
      'duration': 62,
      'thumbnails': [
        {'url': 'small.jpg'},
        {'url': 'large.jpg'},
      ],
    });

    expect(track.artist, 'Channel');
    expect(track.thumbnailUrl, 'large.jpg');
    expect(track.formattedDuration, '1:02');
  });

  test('copied YouTube and YouTube Music links produce immediate playable results', () {
    for (final link in [
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=shared',
      'https://youtu.be/dQw4w9WgXcQ?si=shared',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
    ]) {
      final track = YoutubeTrack.fromVideoLink(link);
      expect(track?.videoId, 'dQw4w9WgXcQ');
      expect(track?.url, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(track?.thumbnailUrl, contains('dQw4w9WgXcQ'));
    }
    expect(YoutubeTrack.fromVideoLink('https://example.com/watch?v=dQw4w9WgXcQ'), isNull);
    expect(YoutubeTrack.fromVideoLink('https://youtube.com/watch?v=invalid'), isNull);
  });
}
