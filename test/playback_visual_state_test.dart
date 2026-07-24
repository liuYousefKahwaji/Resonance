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

  test('playback health requires meaningful forward progress', () {
    expect(
      playbackPositionAdvanced(const Duration(seconds: 10), const Duration(seconds: 10, milliseconds: 249)),
      isFalse,
    );
    expect(
      playbackPositionAdvanced(const Duration(seconds: 10), const Duration(seconds: 10, milliseconds: 250)),
      isTrue,
    );
  });

  test('failure recovery skips failed tracks without wrapping when loop is off', () {
    const playlist = ['one', 'two', 'three', 'four'];
    expect(
      nextPlayablePlaylistIndex(
        playlist: playlist,
        currentIndex: 0,
        allowWrap: false,
        hasFailed: (path) => path == 'two' || path == 'three',
      ),
      3,
    );
    expect(
      nextPlayablePlaylistIndex(playlist: playlist, currentIndex: 3, allowWrap: false, hasFailed: (_) => false),
      -1,
    );
  });

  test('failure recovery wraps once and stops when every alternative failed', () {
    const playlist = ['one', 'two', 'three'];
    expect(
      nextPlayablePlaylistIndex(
        playlist: playlist,
        currentIndex: 2,
        allowWrap: true,
        hasFailed: (path) => path == 'one',
      ),
      1,
    );
    expect(nextPlayablePlaylistIndex(playlist: playlist, currentIndex: 0, allowWrap: true, hasFailed: (_) => true), -1);
  });
}
