import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const unavailableUrl = 'https://www.youtube.com/watch?v=KCeYsyYo2gc';
const previousUrl = 'https://www.youtube.com/watch?v=abcdefghijk';
const unavailable = YoutubeFailure(
  kind: YoutubeFailureKind.unavailable,
  userMessage: 'This YouTube video is unavailable.',
  sourceUrl: unavailableUrl,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    storage = await Directory.systemTemp.createTemp('resonance-failed-stream-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => storage.path,
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    await storage.delete(recursive: true);
  });

  for (final standalone in [false, true]) {
    test(
      'failed ${standalone ? 'standalone' : 'library'} stream retries selection instead of old audio',
      () async {
        SharedPreferences.setMockInitialValues({});
        final player = _RetainingPlayer();
        var failedResolutions = 0;
        final handler = PlayerHandler(
          windowsPlayer: player,
          streamResolver: (url) async {
            if (url == unavailableUrl) {
              failedResolutions++;
              throw unavailable;
            }
            return ResolvedYoutubeStream(uri: Uri.parse('https://audio.example.test/previous'), accessRevision: 0);
          },
        );
        addTearDown(handler.dispose);
        // Allow startup preference restoration to finish before selecting music.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await handler.loadTrack(previousUrl, 'Previous', 'Artist', standalone: true);
        expect(player.state.playing, isTrue);
        final previousAudio = player.opened.single;

        if (standalone) {
          await expectLater(
            handler.playStandaloneStream(
              url: unavailableUrl,
              title: 'Haunted House',
              artist: 'Neoni',
              thumbnailUrl: 'https://image.example.test/haunted',
              queueItems: const [
                StandaloneStreamQueueItem(url: unavailableUrl, title: 'Haunted House', artist: 'Neoni'),
                StandaloneStreamQueueItem(url: previousUrl, title: 'Previous', artist: 'Artist'),
              ],
              queueIndex: 0,
              relatedQueue: false,
            ),
            throwsA(isA<YoutubeFailure>()),
          );
          final queue = await handler.playbackQueueSnapshot();
          expect(queue.current?.id, unavailableUrl);
          expect(queue.upcoming.single.id, previousUrl);
        } else {
          await handler.loadTrack(
            unavailableUrl,
            'Haunted House',
            'Neoni',
            artworkUri: Uri.parse('https://image.example.test/haunted'),
          );
        }
        expect(player.state.playing, isFalse);
        expect(handler.mediaItem.value?.id, unavailableUrl);
        expect(handler.mediaItem.value?.title, 'Haunted House');
        expect(handler.mediaItem.value?.artUri.toString(), 'https://image.example.test/haunted');
        expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
        expect(handler.playbackVisualNotifier.value.loading, isFalse);
        expect(handler.currentDuration, isNull, reason: 'Do not expose the outgoing source duration after failure');
        expect(handler.currentPosition, Duration.zero);
        expect(handler.isStandaloneMode, standalone);
        if (!standalone) expect(handler.youtubeFailureNotifier.value?.kind, YoutubeFailureKind.unavailable);

        await handler.play();
        expect(failedResolutions, 2);
        expect(player.playCalls, 0, reason: 'Play must not resume the retained outgoing native source');
        expect(player.opened, [previousAudio]);
        expect(player.state.playing, isFalse);

        await handler.loadTrack(previousUrl, 'Previous', 'Artist', standalone: true);
        expect(player.state.playing, isTrue, reason: 'A failed item must not block another selection');
        await handler.pause();
        await handler.play();
        expect(player.playCalls, 1, reason: 'Normal resume still uses the loaded source');
      },
      skip: !Platform.isWindows,
    );
  }

  test('a late unavailable response does not stop the newly selected song', () async {
    SharedPreferences.setMockInitialValues({});
    final failedRequest = Completer<ResolvedYoutubeStream>();
    final started = Completer<void>();
    final player = _RetainingPlayer();
    final handler = PlayerHandler(
      windowsPlayer: player,
      streamResolver: (url) {
        if (url == unavailableUrl) {
          started.complete();
          return failedRequest.future;
        }
        return Future.value(
          ResolvedYoutubeStream(uri: Uri.parse('https://audio.example.test/selected'), accessRevision: 0),
        );
      },
    );
    addTearDown(handler.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final obsolete = handler.loadTrack(unavailableUrl, 'Haunted House', 'Neoni', standalone: true);
    await started.future;
    await handler.loadTrack(previousUrl, 'Selected', 'Artist', standalone: true);
    failedRequest.completeError(unavailable);
    await obsolete;
    expect(handler.mediaItem.value?.id, previousUrl);
    expect(player.state.playing, isTrue);
    expect(handler.playbackVisualNotifier.value.playing, isTrue);
    expect(handler.youtubeFailureNotifier.value, isNull);
  }, skip: !Platform.isWindows);
}

// Mimics native stop retaining its last source, the condition that previously
// let Play restart the wrong audio after replacement extraction failed.
class _RetainingPlayer implements mk.Player {
  @override
  mk.PlayerState state = const mk.PlayerState(audioDevices: [mk.AudioDevice('speakers', 'Speakers')]);
  final opened = <String>[];
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
    state = state.copyWith(playing: play, duration: const Duration(minutes: 3));
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
