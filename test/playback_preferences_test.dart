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
    final equalizer = EqualizerSettings.forPreset(EqualizerPreset.vocal);
    await store.saveAdjustments(
      r'C:\Music\podcast.mp3',
      PlaybackAdjustments(speed: 1.4, pitch: 0.9, equalizer: equalizer),
    );

    store = await PlaybackPreferenceStore.load();
    expect(store.adjustmentsFor(r'c:\music\podcast.mp3').speed, 1.4);
    expect(store.adjustmentsFor(r'c:\music\podcast.mp3').pitch, 0.9);
    expect(store.adjustmentsFor(r'c:\music\podcast.mp3').equalizer, equalizer);
    expect(store.adjustmentsFor(r'C:\Music\new.mp3'), PlaybackAdjustments.neutral);
    await store.clearAdjustments(r'c:\music\podcast.mp3');
    expect(store.adjustmentsFor(r'C:\Music\podcast.mp3'), PlaybackAdjustments.neutral);
  });

  test('per-track adjustments persist a remembered Custom curve behind another preset', () async {
    var store = await PlaybackPreferenceStore.load();
    final equalizer = EqualizerSettings.flat.withBandGain(3, 5).selectPreset(EqualizerPreset.rock);
    await store.saveAdjustments(r'C:\Music\custom.mp3', PlaybackAdjustments(equalizer: equalizer));

    store = await PlaybackPreferenceStore.load();
    final restored = store.adjustmentsFor(r'C:\Music\custom.mp3').equalizer;
    expect(restored.preset, EqualizerPreset.rock);
    expect(restored.selectPreset(EqualizerPreset.custom).gainsDb, [0, 0, 0, 5, 0]);
  });

  test('v1 bass preferences migrate to a two-band custom equalizer', () async {
    SharedPreferences.setMockInitialValues({
      'per_track_playback_settings_v1': '{"c:\\\\music\\\\old.mp3":{"speed":1.0,"pitch":1.0,"bass":0.6}}',
    });
    final store = await PlaybackPreferenceStore.load();
    final equalizer = store.adjustmentsFor(r'c:\music\old.mp3').equalizer;

    expect(equalizer.preset, EqualizerPreset.custom);
    expect(equalizer.gainsDb[0], 6);
    expect(equalizer.gainsDb[1], closeTo(3.6, 0.0001));
    expect(equalizer.gainsDb.skip(2), everyElement(0));
  });
}
