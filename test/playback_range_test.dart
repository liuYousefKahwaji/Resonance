import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/audio/playback_preferences.dart';
import 'package:resonance/widgets/player/playback_range_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('cut uses relative seek time while preserving the source lyric clock', () {
    const range = PlaybackRange(start: Duration(seconds: 30), end: Duration(seconds: 90));
    expect(range.durationOf(const Duration(minutes: 3)), const Duration(minutes: 1));
    expect(range.relative(const Duration(seconds: 40)), const Duration(seconds: 10));
    expect(range.source(const Duration(seconds: 10)), const Duration(seconds: 40));
    expect(range.relative(const Duration(seconds: 10)), Duration.zero);
    expect(range.relative(const Duration(minutes: 2)), const Duration(minutes: 1));
    expect(range.source(Duration.zero), range.start, reason: 'Repeat and seek to zero start at the cut');
  });

  test('open end follows file duration and stale bounds cannot create an empty track', () {
    const range = PlaybackRange(start: Duration(seconds: 30));
    expect(range.durationOf(const Duration(minutes: 3)), const Duration(seconds: 150));
    expect(range.bounded(const Duration(seconds: 20)), PlaybackRange.full);
    expect(const PlaybackRange(end: Duration(minutes: 5)).bounded(const Duration(minutes: 2)), PlaybackRange.full);
    expect(
      const PlaybackRange(
        start: Duration(seconds: 40),
        end: Duration(seconds: 50),
      ).bounded(const Duration(seconds: 45)),
      const PlaybackRange(start: Duration(seconds: 40)),
    );
    expect(
      const PlaybackRange(start: Duration(seconds: 10), end: Duration(seconds: 5)).bounded(null),
      PlaybackRange.full,
    );
  });

  test('ranges persist independently of effects, through serialized edits and reset', () async {
    var store = await PlaybackPreferenceStore.load();
    const a = PlaybackRange(start: Duration(seconds: 4), end: Duration(seconds: 15));
    const b = PlaybackRange(start: Duration(seconds: 8));
    await Future.wait([
      store.saveRange('song.mp3', a),
      store.saveRange('other.mp3', b),
      store.saveRange('song.mp3', b),
      store.saveAdjustments('song.mp3', PlaybackAdjustments(speed: 1.3)),
    ]);
    store = await PlaybackPreferenceStore.load();
    expect(store.rangeFor('song.mp3'), b);
    expect(store.rangeFor('other.mp3'), b);
    await store.clearAdjustments('song.mp3');
    expect(store.rangeFor('song.mp3'), b);
    await store.saveRange('song.mp3', PlaybackRange.full);
    store = await PlaybackPreferenceStore.load();
    expect(store.rangeFor('song.mp3'), PlaybackRange.full);
    expect(store.rangeFor('other.mp3'), b);
    await expectLater(store.saveRange('https://youtu.be/abcdef', a), throwsArgumentError);
  });

  test('malformed saved ranges fall back without dropping valid entries', () async {
    final identity = playbackTrackIdentity('good.mp3');
    SharedPreferences.setMockInitialValues({
      PlaybackPreferenceStore.rangesKey: jsonEncode({
        identity: {'startMs': 1000, 'endMs': 2000},
        playbackTrackIdentity('bad.mp3'): {'startMs': '1000', 'endMs': 2000},
        playbackTrackIdentity('backwards.mp3'): {'startMs': 3000, 'endMs': 2000},
      }),
    });
    final store = await PlaybackPreferenceStore.load();
    expect(store.rangeFor('good.mp3'), const PlaybackRange(start: Duration(seconds: 1), end: Duration(seconds: 2)));
    expect(store.rangeFor('bad.mp3'), PlaybackRange.full);
    expect(store.rangeFor('backwards.mp3'), PlaybackRange.full);
  });

  test('timestamps accept precise minutes or hours and reject ambiguous input', () {
    expect(parsePlaybackTimestamp('1:02.125'), const Duration(minutes: 1, seconds: 2, milliseconds: 125));
    expect(parsePlaybackTimestamp('1:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(parsePlaybackTimestamp('25'), const Duration(seconds: 25));
    for (final value in ['-10', '1:99', '1:60:00', 'hello', '1:2:3:4', '1.1234']) {
      expect(parsePlaybackTimestamp(value), isNull);
    }
    const time = Duration(hours: 2, minutes: 4, seconds: 5, milliseconds: 123);
    expect(parsePlaybackTimestamp(playbackTimestamp(time)), time);
  });
}
