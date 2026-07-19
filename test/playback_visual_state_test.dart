import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';

void main() {
  test('local tracks never expose loading or buffering UI states', () {
    expect(visibleProcessingState(AudioProcessingState.loading, isStream: false), AudioProcessingState.ready);
    expect(visibleProcessingState(AudioProcessingState.buffering, isStream: false), AudioProcessingState.ready);
  });

  test('stream tracks retain genuine loading feedback', () {
    expect(visibleProcessingState(AudioProcessingState.loading, isStream: true), AudioProcessingState.loading);
    expect(visibleProcessingState(AudioProcessingState.buffering, isStream: true), AudioProcessingState.buffering);
  });

  test('missing envelopes use a stable non-zero playback pulse', () {
    final first = fallbackVisualizerAmplitude('https://youtube.test/watch?v=abcdefghijk', const Duration(seconds: 12));
    final repeated = fallbackVisualizerAmplitude(
      'https://youtube.test/watch?v=abcdefghijk',
      const Duration(seconds: 12),
    );
    expect(first, greaterThan(0));
    expect(repeated, first);
    expect(first, lessThanOrEqualTo(0.82));
  });
}
