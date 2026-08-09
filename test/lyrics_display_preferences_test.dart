import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/lyrics_display_preferences.dart';

void main() {
  test('lyrics renderer supports only 30 and 120 FPS', () {
    expect(normalizeLyricsFramesPerSecond(30), 30);
    expect(normalizeLyricsFramesPerSecond(120), 120);
    expect(normalizeLyricsFramesPerSecond(null), 120);
    expect(normalizeLyricsFramesPerSecond(60), 120);
  });

  test('lyrics renderer frame intervals match the selected rate', () {
    expect(lyricsFrameInterval(30).inMicroseconds, 33333);
    expect(lyricsFrameInterval(120).inMicroseconds, 8333);
  });
}
