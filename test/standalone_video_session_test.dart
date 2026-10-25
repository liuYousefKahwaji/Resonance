import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:resonance/core/audio/standalone_video_session.dart';
import 'package:resonance/core/audio/media_source_readiness.dart';
import 'package:resonance/models/youtube_video_source.dart';

const track = 'https://www.youtube.com/watch?v=abcdefghijk';
const versions = YoutubeMediaVersions(originalId: 'abcdefghijk', songId: 'abcdefghijk', videoId: '01234567890');
final source = ResolvedYoutubeVideo(
  videoUri: Uri.parse('https://video.test/video'),
  audioUri: Uri.parse('https://audio.test/audio'),
);
StandaloneVideoFrame frame({int generation = 1, int seconds = 12, bool playing = true, int seek = 0}) =>
    StandaloneVideoFrame(
      trackId: track,
      generation: generation,
      position: Duration(seconds: seconds),
      playing: playing,
      rate: 1,
      seekRevision: seek,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('remote media readiness waits for metadata and promptly abandons a superseded source', () async {
    final player = _VideoPlayer();
    var current = true;
    final ready = waitForMediaSourceReady(player, () => current);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    player.state = player.state.copyWith(duration: const Duration(minutes: 3));
    expect(await ready, isTrue);
    player.state = const mk.PlayerState();
    final cancelled = waitForMediaSourceReady(player, () => current);
    current = false;
    expect(await cancelled, isFalse);
    await player.dispose();
  });
  test('silent video follows transport without continuous seeks and releases on Song', () async {
    var current = frame();
    final player = _VideoPlayer();
    var restored = 0, activated = 0;
    final session = StandaloneVideoSession(
      frame: () => current,
      versionsLoader: (_) async => versions,
      streamLoader: (_) async => source,
      createPlayer: () => player,
      createController: (_) => null,
      activateAudio: (_, _, owner, valid) async {
        expect(valid(), isTrue);
        activated++;
        return owner.position;
      },
      restoreAudio: (_, _, valid) async {
        if (valid()) restored++;
      },
    );
    addTearDown(session.close);
    await session.showVideo();
    expect(session.enabled, isTrue);
    expect(activated, 1);
    expect(player.state.volume, 0);
    expect(player.native.properties, containsPair('aid', 'no'));
    expect(player.native.properties, containsPair('ao', 'null'));
    expect(player.state.playing, isTrue);
    current = frame(seconds: 25);
    await Future<void>.delayed(const Duration(milliseconds: 240));
    expect(player.seeks, [const Duration(seconds: 12)], reason: 'Advancing clocks are not seek commands');
    player.state = player.state.copyWith(buffering: true);
    await Future<void>.delayed(const Duration(milliseconds: 140));
    player.state = player.state.copyWith(buffering: false);
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(player.seeks, [
      const Duration(seconds: 12),
    ], reason: 'Startup/seek buffering recovery must not cause another seek');
    current = frame(seconds: 35, playing: false, seek: 1);
    await Future<void>.delayed(const Duration(milliseconds: 240));
    expect(player.seeks.last, const Duration(seconds: 35));
    expect(player.state.playing, isFalse);
    await session.showSong();
    expect(session.wantsVideo, isFalse);
    expect(session.controller, isNull);
    expect(player.disposed, isTrue);
    expect(restored, 1);
  });

  for (final cancelBySelection in [false, true]) {
    test(
      'late video extraction cannot change audio after ${cancelBySelection ? 'new track' : 'Song selection'}',
      () async {
        var current = frame();
        final gate = Completer<ResolvedYoutubeVideo>();
        var activated = 0, created = 0;
        final session = StandaloneVideoSession(
          frame: () => current,
          versionsLoader: (_) async => versions,
          streamLoader: (_) => gate.future,
          createPlayer: () {
            created++;
            return _VideoPlayer();
          },
          createController: (_) => null,
          activateAudio: (_, _, owner, valid) async {
            activated++;
            return owner.position;
          },
          restoreAudio: (_, _, _) async {},
        );
        addTearDown(session.close);
        final loading = session.showVideo();
        await Future<void>.delayed(Duration.zero);
        if (cancelBySelection) {
          current = frame(generation: 2);
          session.sourceChanged();
        } else {
          await session.showSong();
        }
        gate.complete(source);
        await loading;
        expect(activated, 0);
        expect(created, 0);
        expect(session.enabled, isFalse);
      },
    );
  }

  test('Song with no linked video keeps audio available without opening a decoder', () async {
    var created = false;
    final session = StandaloneVideoSession(
      frame: () => frame(),
      versionsLoader: (_) async => const YoutubeMediaVersions(originalId: 'abcdefghijk', songId: 'abcdefghijk'),
      createPlayer: () {
        created = true;
        return _VideoPlayer();
      },
      createController: (_) => null,
      activateAudio: (_, _, _, _) async => throw StateError('Must not replace audio'),
      restoreAudio: (_, _, _) async {},
    );
    addTearDown(session.close);
    await session.showVideo();
    expect(created, isFalse);
    expect(session.wantsVideo, isFalse);
    expect(session.unavailable, isTrue);
    expect(session.error, contains('No video version'));
  });

  test('extraction preserves separate audio/video headers and rejects audio-only uploads', () {
    final result = ResolvedYoutubeVideo.fromExtraction({
      'requested_formats': [
        {
          'url': 'https://v.test/stream',
          'vcodec': 'avc1',
          'acodec': 'none',
          'http_headers': {'X-Video': 'yes'},
        },
        {
          'url': 'https://a.test/stream',
          'vcodec': 'none',
          'acodec': 'opus',
          'http_headers': {'X-Audio': 'yes'},
        },
      ],
    });
    expect(result.videoHeaders, {'X-Video': 'yes'});
    expect(result.audioHeaders, {'X-Audio': 'yes'});
    expect(
      () => ResolvedYoutubeVideo.fromExtraction({'url': 'https://a.test', 'vcodec': 'none', 'acodec': 'opus'}),
      throwsFormatException,
    );
    expect(() => YoutubeMediaVersions.fromJson({'originalId': 'not an id'}), throwsFormatException);
  });
}

class _Native extends Fake implements mk.NativePlayer {
  final properties = <String, String>{};
  @override
  Future<void> setProperty(String property, String value, {bool waitForInitialization = true}) async {
    properties[property] = value;
  }
}

class _VideoStream extends Fake implements mk.PlayerStream {
  @override
  Stream<String> get error => const Stream.empty();
}

class _VideoPlayer extends Fake implements mk.Player {
  final native = _Native();
  bool disposed = false;
  final seeks = <Duration>[];
  @override
  mk.PlayerState state = const mk.PlayerState();
  @override
  mk.PlatformPlayer get platform => native;
  @override
  mk.PlayerStream get stream => _VideoStream();
  @override
  Future<void> open(mk.Playable playable, {bool play = true}) async {
    state = state.copyWith(playing: play, duration: const Duration(minutes: 3));
  }

  @override
  Future<void> setVolume(double value) async {
    state = state.copyWith(volume: value);
  }

  @override
  Future<void> setRate(double value) async {
    state = state.copyWith(rate: value);
  }

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    state = state.copyWith(position: value);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
