import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/playback_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stable identity normalizes Windows paths and YouTube URL variants', () {
    expect(
      playbackTrackIdentity(r'C:\Music\Album\..\Track.mp3', isWindowsOverride: true),
      playbackTrackIdentity(r'c:\music\Track.mp3', isWindowsOverride: true),
    );
    expect(
      playbackTrackIdentity('https://youtu.be/abc123?t=90'),
      playbackTrackIdentity('https://www.youtube.com/watch?v=abc123&list=xyz'),
    );
  });

  test('only useful positions in tracks at least ten minutes are resumable', () {
    expect(isResumablePosition(const Duration(minutes: 2), const Duration(minutes: 9, seconds: 59)), isFalse);
    expect(isResumablePosition(const Duration(minutes: 2), const Duration(minutes: 10)), isTrue);
    expect(isResumablePosition(const Duration(minutes: 9, seconds: 58), const Duration(minutes: 10)), isFalse);
  });

  test('position saves replace the previous value and can be cleared', () async {
    final store = await PlaybackPreferenceStore.load();
    await store.savePosition('https://youtu.be/abc123', const Duration(minutes: 2));
    await store.savePosition('https://www.youtube.com/watch?v=abc123', const Duration(minutes: 3));

    expect(store.positionFor('https://youtu.be/abc123'), const Duration(minutes: 3));
    await store.clearPosition('https://youtu.be/abc123');
    expect(store.positionFor('https://www.youtube.com/watch?v=abc123'), isNull);
  });

  test('overlapping position saves retain every successful track update', () async {
    var store = await PlaybackPreferenceStore.load();

    await Future.wait([
      store.savePosition(r'C:\Music\first.mp3', const Duration(minutes: 2)),
      store.savePosition(r'C:\Music\second.mp3', const Duration(minutes: 4)),
    ]);

    store = await PlaybackPreferenceStore.load();
    expect(store.positionFor(r'C:\Music\first.mp3'), const Duration(minutes: 2));
    expect(store.positionFor(r'C:\Music\second.mp3'), const Duration(minutes: 4));
  });

  test('per-track adjustments persist without deleting neutral or global state', () async {
    var store = await PlaybackPreferenceStore.load();
    await store.saveAdjustments(r'C:\Music\podcast.mp3', const PlaybackAdjustments(speed: 1.4, pitch: 0.9, bass: 0.6));

    store = await PlaybackPreferenceStore.load();
    expect(store.adjustmentsFor(r'c:\music\podcast.mp3').speed, 1.4);
    expect(store.adjustmentsFor(r'c:\music\podcast.mp3').pitch, 0.9);
    expect(store.adjustmentsFor(r'c:\music\podcast.mp3').bass, 0.6);
    expect(store.adjustmentsFor(r'C:\Music\new.mp3'), PlaybackAdjustments.neutral);
    await store.clearAdjustments(r'c:\music\podcast.mp3');
    expect(store.adjustmentsFor(r'C:\Music\podcast.mp3'), PlaybackAdjustments.neutral);
  });
}
