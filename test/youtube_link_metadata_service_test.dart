import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/youtube/youtube_link_metadata_service.dart';

void main() {
  test('small public metadata response supplies the visible title and author', () {
    final link = YoutubeTrack.fromVideoLink('https://music.youtube.com/watch?v=dQw4w9WgXcQ')!;
    final metadata = YoutubeLinkMetadataService.parseResponse(
      '{"title":"Real song","author_name":"Real artist"}',
      link,
    );
    expect(metadata?.title, 'Real song');
    expect(metadata?.artist, 'Real artist');
    expect(metadata?.url, link.url);
    expect(metadata?.thumbnailUrl, link.thumbnailUrl);
  });

  test('incomplete public metadata leaves the full extractor fallback available', () {
    final link = YoutubeTrack.fromVideoLink('https://youtu.be/dQw4w9WgXcQ')!;
    expect(YoutubeLinkMetadataService.parseResponse('{"title":"Real song"}', link), isNull);
  });
}
