import 'package:resonance/services/track_artwork_service.dart';
import 'package:resonance/core/audio/playback_session.dart';
import 'package:resonance/models/youtube_track.dart';
import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/audio/shuffle_order.dart';
import 'package:resonance/core/storage/file_service.dart';

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

  test('a second stream takes ownership while the first network response is still pending', () async {
    SharedPreferences.setMockInitialValues({});
    final pending = Completer<ResolvedYoutubeStream>(), started = Completer<void>();
    final player = _RetainingPlayer();
    final handler = PlayerHandler(
      windowsPlayer: player,
      streamResolver: (url) {
        if (url == unavailableUrl) {
          started.complete();
          return pending.future;
        }
        return Future.value(ResolvedYoutubeStream(uri: Uri.parse('https://audio.test/second'), accessRevision: 0));
      },
    );
    addTearDown(handler.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final first = handler.playStandaloneStream(
      url: unavailableUrl,
      title: 'First',
      artist: 'Artist',
      relatedQueue: false,
    );
    await started.future;
    await handler.playStandaloneStream(url: previousUrl, title: 'Second', artist: 'Artist', relatedQueue: false);
    await first.timeout(const Duration(milliseconds: 250));
    expect(handler.mediaItem.value?.id, previousUrl);
    expect(handler.mediaItem.value?.title, 'Second');
    expect(player.opened, ['https://audio.test/second']);
    pending.completeError(StateError('late connection failure'));
    await Future<void>.delayed(Duration.zero);
    expect(handler.playbackVisualNotifier.value.loading, isFalse);
    expect(player.state.playing, isTrue);
  }, skip: !Platform.isWindows);

  test('Shuffle wraps into a complete new cycle; Random refreshes only on track actions', () async {
    SharedPreferences.setMockInitialValues({});
    final files = FileService();
    final tracks = List.generate(12, (i) => 'https://www.youtube.com/watch?v=track${i.toString().padLeft(6, '0')}');
    await files.writeTextToPlaylist(1, '#\n${tracks.join('\n')}\n');
    await files.setActivePlaylistNumber(1);
    final player = _RetainingPlayer();
    final handler = PlayerHandler(
      windowsPlayer: player,
      streamResolver: (url) async => ResolvedYoutubeStream(
        uri: Uri.parse('https://audio.test/${Uri.parse(url).queryParameters['v']}'),
        accessRevision: 0,
      ),
    );
    addTearDown(handler.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await handler.loadTrack(tracks.first, 'First', 'Artist');
    expect(handler.playbackOrderMode, PlaybackOrderMode.off);
    await handler.toggleShuffle();
    expect(handler.playbackOrderMode, PlaybackOrderMode.shuffle);
    final cycle = <String>[handler.mediaItem.value!.id];
    for (var i = 1; i < tracks.length; i++) {
      await handler.next();
      cycle.add(handler.mediaItem.value!.id);
    }
    expect(cycle.toSet(), tracks.toSet());
    await handler.next();
    expect(handler.mediaItem.value!.id, isNot(cycle.last));
    final second = [handler.mediaItem.value!.id, ...(await handler.playbackQueueSnapshot()).upcoming.map((e) => e.id)];
    expect(second.toSet(), tracks.toSet());
    expect(second, isNot(cycle));
    await handler.toggleShuffle();
    expect(handler.playbackOrderMode, PlaybackOrderMode.random);
    final initial = (await handler.playbackQueueSnapshot()).upcoming.map((e) => e.id).toList();
    expect(
      (await handler.playbackQueueSnapshot()).upcoming.map((e) => e.id),
      initial,
      reason: 'Opening the queue is read-only',
    );
    final before = handler.mediaItem.value!.id;
    await handler.next();
    expect(handler.mediaItem.value!.id, isNot(before));
    final next = handler.mediaItem.value!.id;
    await handler.previous();
    expect(handler.mediaItem.value!.id, isNot(next));
    await handler.loadTrack(tracks[3], 'Manual', 'Artist');
    final manual = (await handler.playbackQueueSnapshot()).upcoming.map((e) => e.id).toList();
    expect(manual.toSet(), tracks.where((e) => e != tracks[3]).toSet());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('last_shuffle_random'), isTrue);
    await handler.toggleShuffle();
    expect(handler.playbackOrderMode, PlaybackOrderMode.off);
    expect(prefs.getBool('last_shuffle_random'), isFalse);
  }, skip: !Platform.isWindows);

  test('standalone stream shuffle visits its whole queue and Off restores collection order', () async {
    SharedPreferences.setMockInitialValues({});
    final handler = PlayerHandler(
      windowsPlayer: _RetainingPlayer(),
      streamResolver: (url) async => ResolvedYoutubeStream(
        uri: Uri.parse('https://audio.test/${Uri.parse(url).queryParameters['v']}'),
        accessRevision: 0,
      ),
    );
    addTearDown(handler.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final items = List.generate(
      8,
      (i) => StandaloneStreamQueueItem(
        url: 'https://www.youtube.com/watch?v=track${i.toString().padLeft(6, '0')}',
        title: 'Track $i',
        artist: 'Artist',
      ),
    );
    await handler.playStandaloneStream(
      url: items.first.url,
      title: 'First',
      artist: 'Artist',
      queueItems: items,
      queueIndex: 0,
      relatedQueue: false,
    );
    await handler.toggleShuffle();
    final cycle = <String>[handler.mediaItem.value!.id];
    Future<void> next() async {
      final previous = handler.mediaItem.value!.id;
      await handler.next();
      final end = DateTime.now().add(const Duration(seconds: 3));
      while (handler.mediaItem.value?.id == previous || handler.playbackVisualNotifier.value.loading) {
        if (DateTime.now().isAfter(end)) fail('Standalone navigation did not complete');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    for (var i = 1; i < items.length; i++) {
      await next();
      cycle.add(handler.mediaItem.value!.id);
    }
    expect(cycle.toSet(), items.map((e) => e.url).toSet());
    await next();
    expect(handler.mediaItem.value!.id, isNot(cycle.last));
    expect((await handler.playbackQueueSnapshot()).shuffled, isTrue);
    await handler.toggleShuffle(); // Random.
    await next();
    await handler.toggleShuffle(); // Off.
    final index = items.indexWhere((e) => e.url == handler.mediaItem.value!.id);
    expect(
      (await handler.playbackQueueSnapshot()).upcoming.map((e) => e.id),
      [...items.skip(index + 1), ...items.take(index)].map((e) => e.url),
    );
    expect((await handler.playbackQueueSnapshot()).shuffled, isFalse);
  }, skip: !Platform.isWindows);

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
  test('failed stream retry is explicit and obsolete recovery cannot replace a newer selection', () async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    final player = _RetainingPlayer();
    final handler = PlayerHandler(
      windowsPlayer: player,
      streamResolver: (url) async {
        if (url == unavailableUrl && ++attempts == 1) throw unavailable;
        return ResolvedYoutubeStream(
          uri: Uri.parse('https://audio.test/${Uri.parse(url).queryParameters['v']}'),
          accessRevision: 0,
        );
      },
    );
    addTearDown(handler.dispose);
    await handler.initialization;
    await handler.loadTrack(unavailableUrl, 'Failed', 'Artist', standalone: true);
    final failed = handler.playbackFailureNotifier.value!;
    expect(failed.track.id, unavailableUrl);
    expect(handler.playbackVisualNotifier.value.loading, isFalse);
    await handler.retryFailedPlayback(failed);
    expect(attempts, 2);
    expect(handler.playbackFailureNotifier.value, isNull);
    expect(player.state.playing, isTrue);
    await handler.loadTrack(previousUrl, 'New selection', 'Artist', standalone: true);
    await handler.retryFailedPlayback(failed);
    await handler.playFailureAlternative(
      failed,
      const YoutubeTrack(title: 'Obsolete', artist: 'Artist', url: unavailableUrl),
    );
    expect(handler.mediaItem.value?.id, previousUrl);
    expect(attempts, 2);
  }, skip: !Platform.isWindows);

  test('approved alternative preserves the library and next songs in a temporary queue', () async {
    SharedPreferences.setMockInitialValues({});
    final files = FileService();
    await files.replacePlaylistTracks(1, [unavailableUrl, previousUrl]);
    await files.setActivePlaylistNumber(1);
    final handler = PlayerHandler(
      windowsPlayer: _RetainingPlayer(),
      streamResolver: (url) async {
        if (url == unavailableUrl) throw unavailable;
        return ResolvedYoutubeStream(uri: Uri.parse('https://audio.test/valid'), accessRevision: 0);
      },
    );
    addTearDown(handler.dispose);
    await handler.initialization;
    await handler.loadTrack(unavailableUrl, 'Failed', 'Artist');
    final failure = handler.playbackFailureNotifier.value!;
    const alternative = YoutubeTrack(
      title: 'Chosen version',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=12345678901',
    );
    await handler.playFailureAlternative(failure, alternative);
    expect(handler.mediaItem.value?.id, alternative.url);
    expect(await files.readPlaylistTracks(1), [unavailableUrl, previousUrl]);
    expect((await handler.playbackQueueSnapshot()).upcoming.map((e) => e.id), [previousUrl]);
    expect(handler.playbackFailureNotifier.value, isNull);
  }, skip: !Platform.isWindows);

  test('restart restores a stream queue and position paused without resolving any audio', () async {
    SharedPreferences.setMockInitialValues({});
    var resolutions = 0;
    Future<ResolvedYoutubeStream> resolve(String url) async {
      resolutions++;
      return ResolvedYoutubeStream(
        uri: Uri.parse('https://audio.test/cdn?private=never-persist'),
        headers: const {'Authorization': 'never-persist'},
        accessRevision: 0,
      );
    }

    final first = PlayerHandler(windowsPlayer: _RetainingPlayer(), streamResolver: resolve);
    await first.initialization;
    await first.playStandaloneStream(
      url: previousUrl,
      title: 'Current',
      artist: 'Artist',
      relatedQueue: false,
      queueItems: const [
        StandaloneStreamQueueItem(url: previousUrl, title: 'Current', artist: 'Artist'),
        StandaloneStreamQueueItem(url: unavailableUrl, title: 'Next', artist: 'Artist'),
      ],
      queueIndex: 0,
    );
    await first.seek(const Duration(seconds: 42));
    await first.saveState();
    await first.dispose();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PlaybackSession.preferenceKey), isNot(contains('never-persist')));
    final count = resolutions;
    final player = _RetainingPlayer();
    final second = PlayerHandler(windowsPlayer: player, streamResolver: resolve);
    addTearDown(second.dispose);
    await second.initialization;
    expect(second.mediaItem.value?.id, previousUrl);
    expect(second.currentPosition, const Duration(seconds: 42));
    expect(second.currentDuration, const Duration(minutes: 3));
    expect(second.playbackState.value.playing, isFalse);
    expect(player.opened, isEmpty);
    expect(resolutions, count);
    expect((await second.playbackQueueSnapshot()).upcoming.map((e) => e.id), [unavailableUrl]);
    await second.seek(const Duration(seconds: 55));
    expect(second.currentPosition, const Duration(seconds: 55));
    expect(player.opened, isEmpty);
    await second.play();
    expect(resolutions, greaterThan(count));
    expect(player.opened, hasLength(1));
    expect(second.currentPosition, const Duration(seconds: 55));
    expect(player.state.playing, isTrue);
    expect((await second.playbackQueueSnapshot()).upcoming.map((e) => e.id), [unavailableUrl]);
  }, skip: !Platform.isWindows);
  test('library shuffle order and short-track position survive restart', () async {
    SharedPreferences.setMockInitialValues({});
    final files = FileService();
    final paths = List.generate(8, (i) => 'https://www.youtube.com/watch?v=track00000$i');
    await files.replacePlaylistTracks(1, paths);
    await files.setActivePlaylistNumber(1);
    Future<ResolvedYoutubeStream> resolve(String url) async =>
        ResolvedYoutubeStream(uri: Uri.parse('https://audio.test/good'), accessRevision: 0);
    final first = PlayerHandler(windowsPlayer: _RetainingPlayer(), streamResolver: resolve);
    await first.initialization;
    await first.loadTrack(paths.first, 'Current', 'Artist');
    await first.toggleShuffle();
    await first.seek(const Duration(seconds: 23));
    final expected = (await first.playbackQueueSnapshot()).upcoming.map((e) => e.id).toList();
    await first.saveState();
    await first.dispose();
    final player = _RetainingPlayer();
    final second = PlayerHandler(windowsPlayer: player, streamResolver: resolve);
    addTearDown(second.dispose);
    await second.initialization;
    expect(second.isShuffle, isTrue);
    expect(second.currentPosition, const Duration(seconds: 23));
    expect((await second.playbackQueueSnapshot()).upcoming.map((e) => e.id), expected);
    expect(player.opened, isEmpty);
    await second.play();
    expect(second.currentPosition, const Duration(seconds: 23));
    expect((await second.playbackQueueSnapshot()).upcoming.map((e) => e.id), expected);
  }, skip: !Platform.isWindows);

  test('missing restored local file clears unusable session without opening a decoder', () async {
    final missing = '${storage.path}/removed.mp3';
    final saved = PlaybackSession(
      current: SavedPlaybackEntry(id: missing, title: 'Gone', artist: 'Artist'),
      position: const Duration(seconds: 8),
      standalone: false,
      playlistNumber: 1,
    );
    SharedPreferences.setMockInitialValues({PlaybackSession.preferenceKey: saved.encode()});
    final player = _RetainingPlayer();
    final handler = PlayerHandler(windowsPlayer: player);
    addTearDown(handler.dispose);
    await handler.initialization;
    expect(handler.mediaItem.value, isNull);
    expect(player.opened, isEmpty);
    expect((await SharedPreferences.getInstance()).getString(PlaybackSession.preferenceKey), isNull);
  }, skip: !Platform.isWindows);
  test(
    'cover edits refresh the current media item without restarting audio; removal clears every player',
    () async {
      SharedPreferences.setMockInitialValues({});
      final path = '${storage.path}/cover-test.webm';
      await File(path).writeAsBytes([0]);
      final player = _RetainingPlayer();
      final handler = PlayerHandler(windowsPlayer: player);
      addTearDown(handler.dispose);
      await handler.initialization;
      final artwork = TrackArtworkService(directory: Directory('${storage.path}/covers'));
      await artwork.saveCover(path, Uint8List.fromList([1, 2, 3]));
      final previous = await artwork.resolve(path);
      handler.mediaItem.add(MediaItem(id: path, title: 'Song', artist: 'Artist', artUri: previous));
      await artwork.saveCover(path, Uint8List.fromList([4, 5, 6]));
      await handler.refreshTrackArtwork(path);
      expect(handler.mediaItem.value!.artUri, isNot(previous));
      expect(handler.mediaItem.value!.title, 'Song');
      expect(player.opened, isEmpty, reason: 'Artwork updates must not touch the decoder.');
      await artwork.embeddedChanged(path, removed: true);
      await handler.refreshTrackArtwork(path);
      expect(handler.mediaItem.value!.artUri, isNull);
      expect(player.opened, isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test('a late artwork refresh cannot overwrite a newly selected song', () async {
    SharedPreferences.setMockInitialValues({});
    final path = '${storage.path}/old.webm';
    await File(path).writeAsBytes([0]);
    final player = _RetainingPlayer();
    final handler = PlayerHandler(windowsPlayer: player);
    addTearDown(handler.dispose);
    await handler.initialization;
    final artwork = TrackArtworkService(directory: Directory('${storage.path}/covers'));
    await artwork.saveCover(path, Uint8List.fromList([1, 2, 3]));
    handler.mediaItem.add(MediaItem(id: path, title: 'Old'));
    final refresh = handler.refreshTrackArtwork(path);
    final newest = MediaItem(id: 'new', title: 'New', artUri: Uri.parse('https://example.com/new.jpg'));
    handler.mediaItem.add(newest);
    await refresh;
    expect(handler.mediaItem.value, newest);
    expect(player.opened, isEmpty);
  }, skip: !Platform.isWindows);
  test('metadata edits preserve standalone presentation and a paused source position', () async {
    SharedPreferences.setMockInitialValues({});
    final path = '${storage.path}/edit.wav';
    await File(path).writeAsBytes([0]);
    final player = _RetainingPlayer();
    final handler = PlayerHandler(windowsPlayer: player);
    addTearDown(handler.dispose);
    await handler.initialization;
    await handler.loadTrack(
      path,
      'Before',
      'Artist',
      standalone: true,
      playWhenReady: false,
      initialPosition: const Duration(seconds: 12),
    );
    await handler.withTrackFileReleased(path, () async {}, updatedTitle: 'After', updatedArtist: 'Artist');
    expect(handler.mediaItem.value!.title, 'After');
    expect(handler.isStandaloneMode, isTrue);
    expect(player.state.playing, isFalse);
    expect(player.state.position, const Duration(seconds: 12));
  }, skip: !Platform.isWindows);
  test('metadata completion cannot reload a track the user has moved away from', () async {
    SharedPreferences.setMockInitialValues({});
    final first = '${storage.path}/first.wav', second = '${storage.path}/second.wav';
    await File(first).writeAsBytes([0]);
    await File(second).writeAsBytes([0]);
    final player = _RetainingPlayer();
    final handler = PlayerHandler(windowsPlayer: player);
    addTearDown(handler.dispose);
    await handler.initialization;
    await handler.loadTrack(first, 'First', 'Artist', playWhenReady: false);
    final started = Completer<void>(), finish = Completer<void>();
    final edit = handler.withTrackFileReleased(
      first,
      () {
        started.complete();
        return finish.future;
      },
      updatedTitle: 'Edited',
      updatedArtist: 'Artist',
    );
    await started.future;
    await handler.loadTrack(second, 'Second', 'Artist', playWhenReady: false);
    finish.complete();
    await edit;
    expect(handler.mediaItem.value!.id, second);
    expect(player.opened.length, 2);
  }, skip: !Platform.isWindows);
  test('delayed load hydration cannot restore a cover edited just after opening', () async {
    SharedPreferences.setMockInitialValues({});
    final path = '${storage.path}/quick-cover-edit.webm';
    await File(path).writeAsBytes([0]);
    final player = _RetainingPlayer();
    final handler = PlayerHandler(windowsPlayer: player);
    addTearDown(handler.dispose);
    await handler.initialization;
    final artwork = TrackArtworkService(directory: Directory('${storage.path}/covers'));
    await artwork.saveCover(path, Uint8List.fromList([1, 2, 3]));
    final old = await artwork.resolve(path);
    await handler.loadTrack(path, 'Song', 'Artist', artworkUri: old, playWhenReady: false);
    await artwork.saveCover(path, Uint8List.fromList([4, 5, 6]));
    await handler.refreshTrackArtwork(path);
    final newest = handler.mediaItem.value!.artUri;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(handler.mediaItem.value!.artUri, newest);
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
  Future<void> seek(Duration position) async => state = state.copyWith(position: position);

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
