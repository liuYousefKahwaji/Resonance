import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';

void main() {
  test('resolved stream cache respects age and the media URL expiry', () {
    final now = DateTime.fromMillisecondsSinceEpoch(2_000_000_000_000);
    final fresh = ResolvedYoutubeStream(
      uri: Uri.parse(
        'https://cdn.example/audio?expire=${now.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000}',
      ),
      accessRevision: 1,
    );
    final expiring = ResolvedYoutubeStream(
      uri: Uri.parse(
        'https://cdn.example/audio?expire=${now.add(const Duration(seconds: 30)).millisecondsSinceEpoch ~/ 1000}',
      ),
      accessRevision: 1,
    );
    expect(
      resolvedStreamCacheIsFresh(fresh, now.subtract(const Duration(minutes: 2)), now, const Duration(minutes: 30)),
      isTrue,
    );
    expect(
      resolvedStreamCacheIsFresh(expiring, now.subtract(const Duration(minutes: 2)), now, const Duration(minutes: 30)),
      isFalse,
    );
    expect(
      resolvedStreamCacheIsFresh(fresh, now.subtract(const Duration(minutes: 31)), now, const Duration(minutes: 30)),
      isFalse,
    );
  });
}
