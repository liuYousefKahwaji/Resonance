import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/listening_history_repository.dart';
import 'package:resonance/services/local_playback_history_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('records genuine local progress once and excludes streams', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = ListeningHistoryRepository.instance;
    await repository.initialize();
    await repository.clear();
    var now = DateTime.utc(2026, 9, 18);
    final coordinator = LocalPlaybackHistoryCoordinator(repository: repository, clock: () => now);
    const local = MediaItem(id: 'C:/Music/song.mp3', title: 'Song', artist: 'Artist');

    coordinator.onPlaybackSnapshot(item: local, playing: true, position: Duration.zero);
    for (var second = 1; second <= 3; second++) {
      now = now.add(const Duration(seconds: 1));
      coordinator.onPlaybackSnapshot(
        item: local,
        playing: true,
        position: Duration(seconds: second),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(repository.entries.single.title, 'Song');

    const stream = MediaItem(id: 'https://youtube.com/watch?v=abcdefghijk', title: 'Stream');
    coordinator.onPlaybackSnapshot(item: stream, playing: true, position: Duration.zero);
    for (var second = 1; second <= 5; second++) {
      now = now.add(const Duration(seconds: 1));
      coordinator.onPlaybackSnapshot(
        item: stream,
        playing: true,
        position: Duration(seconds: second),
      );
    }
    expect(repository.entries, hasLength(1));

    coordinator.onSessionEnded();
    now = now.add(const Duration(seconds: 1));
    coordinator.onPlaybackSnapshot(item: local, playing: true, position: Duration.zero);
    now = now.add(const Duration(seconds: 1));
    coordinator.onPlaybackSnapshot(item: local, playing: true, position: const Duration(seconds: 30));
    expect(repository.entries, hasLength(1), reason: 'A seek must not count as listening progress');
  });
}
