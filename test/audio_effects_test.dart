import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_preferences.dart';

void main() {
  test('Android bass curve follows the device-reported band ranges', () {
    final subBass = androidBassBandWeight(lowerFrequency: 30, upperFrequency: 120, centerFrequency: 60);
    final lowMid = androidBassBandWeight(lowerFrequency: 120, upperFrequency: 460, centerFrequency: 230);
    final treble = androidBassBandWeight(lowerFrequency: 3600, upperFrequency: 14000, centerFrequency: 7000);

    expect(subBass, 1.0);
    expect(lowMid, greaterThan(0));
    expect(lowMid, lessThan(subBass));
    expect(treble, 0.0);
  });

  test('Windows bass filter uses a strong low shelf and peak limiter', () {
    expect(
      buildWindowsAudioFilter(PlaybackAdjustments.neutral),
      'scaletempo:scale=1.00000000',
      reason: 'the pitch-correction filter must remain installed even at 0% bass',
    );

    final filter = buildWindowsAudioFilter(const PlaybackAdjustments(speed: 1.5, pitch: 0.75, bass: 1.0));
    expect(
      filter,
      'scaletempo:scale=2.00000000,'
      'lavfi=[bass=g=14.00:f=105:t=q:w=0.75,'
      'alimiter=limit=0.95:attack=5:release=50:level=false]',
    );
  });

  test('bass headroom is modest and accounts for a downstream limiter', () {
    expect(bassOutputHeadroomMultiplier(0, limiterAvailable: false), 1.0);
    final android = bassOutputHeadroomMultiplier(1, limiterAvailable: false);
    final windows = bassOutputHeadroomMultiplier(1, limiterAvailable: true);

    expect(android, greaterThan(0.8));
    expect(windows, greaterThan(android));
    expect(windows, 1.0, reason: 'Windows uses a downstream peak limiter instead of lowering all audio');
  });
}
