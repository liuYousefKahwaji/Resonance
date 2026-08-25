import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/models/playback_queue_snapshot.dart';

void main() {
  test('standalone stream queue wraps forward and backward', () {
    expect(loopingStandaloneQueueIndex(currentIndex: 2, offset: 1, length: 3), 0);
    expect(loopingStandaloneQueueIndex(currentIndex: 0, offset: -1, length: 3), 2);
    expect(loopingStandaloneQueueIndex(currentIndex: 1, offset: 1, length: 3), 2);
  });

  test('standalone stream queue rejects missing current entries', () {
    expect(loopingStandaloneQueueIndex(currentIndex: -1, offset: 1, length: 3), -1);
    expect(loopingStandaloneQueueIndex(currentIndex: 0, offset: 1, length: 0), -1);
  });

  test('standalone stream snapshot exposes the full looping session order', () {
    const items = [
      StandaloneStreamQueueItem(url: 'one', title: 'One', artist: 'A'),
      StandaloneStreamQueueItem(url: 'two', title: 'Two', artist: 'B'),
      StandaloneStreamQueueItem(url: 'three', title: 'Three', artist: 'C'),
    ];

    final snapshot = standaloneStreamQueueSnapshot(items: items, currentIndex: 1, loopBehavior: QueueLoopBehavior.all);

    expect(snapshot.current?.id, 'two');
    expect(snapshot.upcoming.map((entry) => entry.id), ['three', 'one']);
    expect(snapshot.shuffled, isFalse);
  });

  test('Windows streams participate in playback health recovery', () {
    expect(supportsPlaybackHealthMonitoring(isWindows: true, isStream: true), isTrue);
    expect(supportsPlaybackHealthMonitoring(isWindows: false, isStream: true), isFalse);
    expect(supportsPlaybackHealthMonitoring(isWindows: false, isStream: false), isTrue);
  });
}
