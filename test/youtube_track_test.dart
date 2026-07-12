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
}
