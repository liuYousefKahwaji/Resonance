import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('local cut survives playlist reloads, maps seeking and resets without resuming pause', () async {
    final storage = await Directory.systemTemp.createTemp('resonance-range-player-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => storage.path,
    );
    SharedPreferences.setMockInitialValues({});
    final path = '${storage.path}/song.wav';
    await File(path).writeAsString('fixture');
    final player = _RangePlayer();
    final handler = PlayerHandler(windowsPlayer: player);
    addTearDown(() async {
      await handler.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
      await storage.delete(recursive: true);
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await handler.loadTrack(path, 'Song', 'Artist', standalone: true);
    await handler.pause();
    await handler.savePlaybackRange(
      path,
      const PlaybackRange(start: Duration(seconds: 10), end: Duration(seconds: 40)),
    );
    expect(player.state.playing, isFalse);
    expect(handler.currentDuration, const Duration(seconds: 30));
    expect(handler.mediaItem.value!.duration, const Duration(seconds: 30));
    expect(player.media.last.start, const Duration(seconds: 10));
    expect(player.media.last.end, const Duration(seconds: 40));
    expect(handler.currentPosition, Duration.zero);
    await handler.seek(const Duration(seconds: 8));
    expect(player.seeks.last, const Duration(seconds: 18));
    expect(handler.currentPosition, const Duration(seconds: 8));
    expect(handler.currentSourcePosition, const Duration(seconds: 18));
    await handler.loadTrack(path, 'Song in another playlist', 'Artist', playWhenReady: false);
    expect(player.media.last.start, const Duration(seconds: 10));
    expect(handler.currentDuration, const Duration(seconds: 30));
    await handler.savePlaybackRange(path, PlaybackRange.full);
    expect(player.media.last.start, Duration.zero);
    expect(player.media.last.end, isNull);
    expect(handler.currentDuration, const Duration(minutes: 3));
    expect(player.state.playing, isFalse);
    expect((await PlaybackPreferenceStore.load()).rangeFor(path), PlaybackRange.full);
  }, skip: !Platform.isWindows);
}

class _RangePlayer implements mk.Player {
  @override
  mk.PlayerState state = const mk.PlayerState(audioDevices: [mk.AudioDevice('speakers', 'Speakers')]);
  final opened = <String>[];
  final media = <mk.Media>[];
  final seeks = <Duration>[];
  int playCalls = 0;

  @override
  mk.PlayerStream get stream => const mk.PlayerStream(
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
  );

  @override
  mk.PlatformPlayer? get platform => null;

  @override
  Future<void> open(mk.Playable playable, {bool play = true}) async {
    opened.add((playable as mk.Media).uri);
    media.add(playable);
    state = state.copyWith(
      playing: play,
      duration: const Duration(minutes: 3),
      position: playable.start ?? Duration.zero,
    );
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    state = state.copyWith(position: position);
  }

  @override
  Future<void> play() async {
    playCalls++;
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async => state = state.copyWith(playing: false);

  @override
  Future<void> stop() async => state = state.copyWith(playing: false);

  @override
  Future<void> dispose() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
