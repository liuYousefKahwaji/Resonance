import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/listening_history_entry.dart';
import 'package:resonance/services/listening_history_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recent local plays are unique, ordered, bounded, and persistent', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = ListeningHistoryRepository.instance;
    await repository.initialize();
    await repository.clear();
    final origin = DateTime.utc(2026, 9, 18);
    for (var index = 0; index < 105; index++) {
      await repository.record(
        ListeningHistoryEntry(
          trackPath: 'track-$index.mp3',
          title: 'Track $index',
          artist: 'Artist',
          playedAt: origin.add(Duration(minutes: index)),
        ),
      );
    }
    expect(repository.entries, hasLength(100));
    expect(repository.entries.first.trackPath, 'track-104.mp3');
    expect(repository.entries.last.trackPath, 'track-5.mp3');

    await repository.record(
      ListeningHistoryEntry(
        trackPath: 'track-50.mp3',
        title: 'Updated title',
        artist: 'Updated artist',
        playedAt: origin.add(const Duration(days: 1)),
      ),
    );
    expect(repository.entries, hasLength(100));
    expect(repository.entries.first.title, 'Updated title');
    expect(repository.entries.where((entry) => entry.trackPath == 'track-50.mp3'), hasLength(1));

    await repository.initialize();
    expect(repository.entries.first.trackPath, 'track-50.mp3');
  });
}
