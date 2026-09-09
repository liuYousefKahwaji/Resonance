import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/youtube_history_service.dart';
import 'package:resonance/services/youtube/youtube_playback_history_coordinator.dart';

class _Reporter implements YoutubeHistoryReporter {
  final List<String> calls = [];
  bool throwOnWrite = false;

  @override
  Future<YoutubeHistoryWriteResult> reportVideoId(String videoId) async {
    calls.add(videoId);
    if (throwOnWrite) throw StateError('network unavailable');
    return YoutubeHistoryWriteResult(YoutubeHistoryWriteStatus.written, videoId: videoId);
  }
}

void main() {
  const first = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
  const second = 'https://www.youtube.com/watch?v=UWt4fIDMJ00';

  test('reports once after three seconds of genuine forward playback', () async {
    final reporter = _Reporter();
    var now = DateTime(2026);
    final coordinator = YoutubePlaybackHistoryCoordinator(reporter: reporter, isEnabled: () => true, clock: () => now);
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: Duration.zero);
    now = now.add(const Duration(milliseconds: 2900));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: const Duration(milliseconds: 2900));
    await Future<void>.delayed(Duration.zero);
    expect(reporter.calls, isEmpty);

    now = now.add(const Duration(milliseconds: 100));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: const Duration(seconds: 3));
    await Future<void>.delayed(Duration.zero);
    expect(reporter.calls, ['jNQXAC9IVRw']);
  });

  test('does not count paused wall-clock time', () async {
    final reporter = _Reporter();
    var now = DateTime(2026);
    final coordinator = YoutubePlaybackHistoryCoordinator(reporter: reporter, isEnabled: () => true, clock: () => now);
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: Duration.zero);
    now = now.add(const Duration(milliseconds: 1500));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: const Duration(milliseconds: 1500));
    now = now.add(const Duration(seconds: 10));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: false, position: const Duration(milliseconds: 1500));
    now = now.add(const Duration(milliseconds: 1500));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: const Duration(seconds: 3));
    await Future<void>.delayed(Duration.zero);

    expect(reporter.calls, ['jNQXAC9IVRw']);
  });

  test('skips early tracks and creates a new session for a later track', () async {
    final reporter = _Reporter();
    var now = DateTime(2026);
    final coordinator = YoutubePlaybackHistoryCoordinator(reporter: reporter, isEnabled: () => true, clock: () => now);
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: Duration.zero);
    now = now.add(const Duration(seconds: 1));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: const Duration(seconds: 1));
    coordinator.onPlaybackSnapshot(mediaIdentity: second, playing: true, position: Duration.zero);
    now = now.add(const Duration(seconds: 3));
    coordinator.onPlaybackSnapshot(mediaIdentity: second, playing: true, position: const Duration(seconds: 3));
    await Future<void>.delayed(Duration.zero);

    expect(reporter.calls, ['UWt4fIDMJ00']);
  });

  test('seek jumps and local media never create a history write', () async {
    final reporter = _Reporter();
    var now = DateTime(2026);
    final coordinator = YoutubePlaybackHistoryCoordinator(reporter: reporter, isEnabled: () => true, clock: () => now);
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: Duration.zero);
    now = now.add(const Duration(seconds: 1));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: const Duration(seconds: 1));
    now = now.add(const Duration(milliseconds: 100));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: const Duration(seconds: 120));
    now = now.add(const Duration(seconds: 1));
    coordinator.onPlaybackSnapshot(mediaIdentity: r'C:\Music\local.flac', playing: true, position: Duration.zero);
    now = now.add(const Duration(seconds: 4));
    coordinator.onPlaybackSnapshot(
      mediaIdentity: r'C:\Music\local.flac',
      playing: true,
      position: const Duration(seconds: 4),
    );
    await Future<void>.delayed(Duration.zero);

    expect(reporter.calls, isEmpty);
  });

  test('deduplicates repeat loops and remains stable when reporting fails', () async {
    final reporter = _Reporter()..throwOnWrite = true;
    var now = DateTime(2026);
    final coordinator = YoutubePlaybackHistoryCoordinator(reporter: reporter, isEnabled: () => true, clock: () => now);
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: Duration.zero);
    now = now.add(const Duration(seconds: 3));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: const Duration(seconds: 3));
    now = now.add(const Duration(seconds: 30));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: const Duration(seconds: 33));
    now = now.add(const Duration(seconds: 1));
    coordinator.onPlaybackSnapshot(mediaIdentity: first, playing: true, position: Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(reporter.calls, ['jNQXAC9IVRw']);
  });
}
