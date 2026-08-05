import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/youtube_track.dart';

void main() {
  test('reads and caches YouTube engagement counts', () {
    final track = YoutubeTrack.fromJson({
      'id': 'abcdefghijk',
      'title': 'Track',
      'uploader': 'Artist',
      'view_count': 1234567,
      'like_count': 98765,
    });

    expect(track.formattedViewCount, '1.23M');
    expect(track.formattedLikeCount, '98.8K');
    final restored = YoutubeTrack.fromCacheJson(track.toJson());
    expect(restored.viewCount, 1234567);
    expect(restored.likeCount, 98765);
  });
}
