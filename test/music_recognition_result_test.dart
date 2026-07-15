import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/music_recognition/music_recognition_service.dart';

void main() {
  test('parses Shazam metadata and creates the YouTube query', () {
    final result = MusicRecognitionResult.fromShazamResponse({
      'matches': [
        {'id': 'match'},
      ],
      'track': {
        'title': 'Judas',
        'subtitle': 'Lady Gaga',
        'url': 'https://www.shazam.com/track/example',
        'images': {'coverart': 'https://example.test/cover.jpg'},
        'sections': [
          {
            'metadata': [
              {'title': 'Album', 'text': 'Born This Way'},
            ],
          },
        ],
      },
    });

    expect(result, isNotNull);
    expect(result!.title, 'Judas');
    expect(result.artist, 'Lady Gaga');
    expect(result.album, 'Born This Way');
    expect(result.artworkUrl, 'https://example.test/cover.jpg');
    expect(result.youtubeQuery, 'Lady Gaga Judas');
  });

  test('returns no result when the response has no usable track', () {
    expect(MusicRecognitionResult.fromShazamResponse({'matches': []}), isNull);
    expect(
      MusicRecognitionResult.fromShazamResponse({
        'track': {'title': '  '},
      }),
      isNull,
    );
  });
}
