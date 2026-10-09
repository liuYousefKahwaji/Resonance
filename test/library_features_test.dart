import 'dart:io';
import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/smart_playlist.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/services/library_catalog.dart';
import 'package:resonance/services/listening_statistics.dart';
import 'package:resonance/services/playlist_offline_service.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/services/track_source_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('statistics count real forward wall time, qualified plays and canonical sources', () async {
    final directory = await Directory.systemTemp.createTemp('resonance-stats-');
    addTearDown(() => directory.delete(recursive: true));
    final local = p.join(directory.path, 'download.mp3');
    await const TrackSourceRepository().saveSource(
      localPath: local,
      youtubeVideoId: 'abcdefghijk',
      method: TrackSourceMethod.downloadedByResonance,
    );
    var now = DateTime(2026, 10, 9, 12);
    final stats = ListeningStatistics(clock: () => now);
    addTearDown(stats.dispose);
    await stats.initialize();
    MediaItem item(String path) =>
        MediaItem(id: path, title: 'Track', artist: 'Artist', duration: const Duration(minutes: 3));
    var position = Duration.zero;
    void tick({bool playing = true, bool loading = false, Duration? seek}) {
      now = now.add(const Duration(seconds: 1));
      position = seek ?? position + const Duration(seconds: 1);
      stats.observe(
        item: item('https://www.youtube.com/watch?v=abcdefghijk'),
        playing: playing,
        position: position,
        loading: loading,
        playlist: 1,
      );
    }

    stats.observe(item: item('https://www.youtube.com/watch?v=abcdefghijk'), playing: true, position: Duration.zero);
    for (var i = 0; i < 31; i++) {
      tick();
    }
    expect(stats.aggregate().values.single['ms'], 31000);
    expect(stats.aggregate().values.single['plays'], 1);
    stats.observe(item: item('https://www.youtube.com/watch?v=abcdefghijk'), playing: true, position: position);
    tick(playing: false);
    tick(playing: false);
    tick();
    tick(loading: true);
    tick();
    tick(seek: const Duration(minutes: 2));
    expect(stats.aggregate().values.single['ms'], 31000);
    stats.onSessionEnded();
    position = Duration.zero;
    stats.observe(item: item(local), playing: true, position: Duration.zero, playlist: 2);
    now = now.add(const Duration(seconds: 2));
    stats.observe(item: item(local), playing: true, position: const Duration(seconds: 2), playlist: 2);
    final result = stats.aggregate();
    expect(result.keys, ['youtube:abcdefghijk']);
    expect(result.values.single['ms'], 33000);
    expect(result.values.single['localMs'], 2000);
    expect(result.values.single['streamMs'], 31000);
    expect(result.values.single['playlists'], {'1': 31000, '2': 2000});
    await stats.setEnabled(false);
    now = now.add(const Duration(seconds: 2));
    stats.observe(item: item(local), playing: true, position: const Duration(seconds: 4));
    expect(stats.aggregate().values.single['ms'], 33000);
    await stats.flush();
    final loaded = ListeningStatistics(clock: () => now);
    addTearDown(loaded.dispose);
    await loaded.initialize();
    expect(loaded.aggregate().values.single['ms'], 33000);
    await loaded.clear();
    expect(loaded.aggregate(), isEmpty);
  });
  test('smart rules deduplicate, exclude, distinguish never played and update locally', () {
    final now = DateTime(2026, 10, 9);
    final a = LibraryTrack(
      id: 'youtube:abcdefghijk',
      path: 'a.mp3',
      title: 'Zulu',
      artist: 'Artist',
      favorite: true,
      available: true,
      addedAt: now,
      playlists: {1},
      durationSeconds: 1500,
    );
    const b = LibraryTrack(id: 'b', path: 'b.mp3', title: 'Alpha', artist: 'Other', favorite: true, playlists: {2});
    const c = LibraryTrack(id: 'c', path: 'https://example.com/c', title: 'Beta', artist: 'Artist');
    final library = [a, b, c, a];
    const offline = SmartPlaylist(
      id: '1',
      name: 'Offline',
      rules: [SmartRule(SmartField.favorite, ''), SmartRule(SmartField.offline, '')],
    );
    expect(offline.evaluate(library, {}).map((track) => track.id), [a.id]);
    const recent = SmartPlaylist(id: '2', name: 'Recent', rules: [SmartRule(SmartField.addedDays, '30')]);
    expect(recent.evaluate(library, {}, now: now).map((track) => track.id), [a.id]);
    final stats = <String, Map<String, dynamic>>{
      a.id: {'lastPlayed': now.subtract(const Duration(days: 60)).toIso8601String(), 'plays': 20},
      'b': {'plays': 3},
    };
    const rediscover = SmartPlaylist(id: '3', name: 'Old', rules: [SmartRule(SmartField.lastPlayedDays, '30')]);
    expect(rediscover.evaluate(library, stats, now: now).map((track) => track.id), [a.id]);
    final never = SmartPlaylist.fromJson(rediscover.toJson()..['includeNeverPlayed'] = true);
    expect(never.evaluate(library, stats, now: now).length, 3);
    final most = SmartPlaylist(
      id: '4',
      name: 'Most',
      rules: const [SmartRule(SmartField.playCount, '1')],
      sort: 'plays',
      descending: true,
      limit: 1,
    );
    expect(most.evaluate(library, stats).first.id, a.id);
    final exclusion = SmartPlaylist.fromJson(most.toJson()..['exclusions'] = [a.id]);
    expect(exclusion.evaluate(library, stats).first.id, 'b');
    const any = SmartPlaylist(
      id: '5',
      name: 'Either',
      rules: [SmartRule(SmartField.artist, 'artist'), SmartRule(SmartField.playlist, '2')],
      matchAny: true,
    );
    expect(any.evaluate(library, {}).length, 3);
  });
  test('offline download preserves order, favorites, failures and retries only remaining streams', () async {
    final directory = await Directory.systemTemp.createTemp('resonance-offline-');
    addTearDown(() => directory.delete(recursive: true));
    final files = FileService(documentsPathOverride: directory.path);
    final local = await File(p.join(directory.path, 'import.mp3')).writeAsString('import');
    const first = 'https://www.youtube.com/watch?v=aaaaaaaaaaa', second = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';
    await files.replacePlaylistTracks(1, [first, local.path, second, first]);
    await files.setTracksFavorite([first], true);
    var failSecond = true;
    final calls = <String>[];
    final queue = DownloadQueueController.forTesting(
      runner: (entry, progress) async {
        calls.add(entry.track.url);
        if (entry.track.url == second && failSecond) throw StateError('Unavailable');
        final path = p.join(directory.path, '${entry.track.videoId}.mp3');
        await File(path).writeAsString('download');
        await const TrackSourceRepository().saveSource(
          localPath: path,
          youtubeVideoId: entry.track.videoId!,
          method: TrackSourceMethod.downloadedByResonance,
        );
        await files.replaceStreamWithDownload(entry.playlistNumber, entry.track.url, path);
        return path;
      },
    );
    final offline = PlaylistOfflineService(files: files, queue: queue);
    addTearDown(offline.dispose);
    addTearDown(queue.dispose);
    await offline.makeOffline(1);
    expect(calls, [first, second]);
    expect(offline.progress[1]!.failures.keys, [second]);
    final downloaded = p.join(directory.path, 'aaaaaaaaaaa.mp3');
    expect(await files.readPlaylistTracks(1), [downloaded, local.path, second, downloaded]);
    expect(await files.readPlaylistTracks(0), [downloaded]);
    failSecond = false;
    await offline.makeOffline(1);
    expect(calls, [first, second, second]);
    expect(offline.progress[1]!.failures, isEmpty);
    final other = p.join(directory.path, 'bbbbbbbbbbb.mp3');
    await files.replacePlaylistTracks(2, [other]);
    await offline.removeManagedDownloads(1);
    expect(await local.exists(), isTrue);
    expect(await File(downloaded).exists(), isTrue);
    expect(await File(other).exists(), isTrue);
    expect(await files.readPlaylistTracks(1), [first, local.path, second, first]);
  });
  test('offline cancellation finishes its current file and leaves the rest for retry', () async {
    final directory = await Directory.systemTemp.createTemp('resonance-offline-cancel-');
    addTearDown(() => directory.delete(recursive: true));
    final files = FileService(documentsPathOverride: directory.path);
    const first = 'https://www.youtube.com/watch?v=aaaaaaaaaaa', second = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';
    await files.replacePlaylistTracks(1, [first, second]);
    final started = Completer<void>(), continueFirst = Completer<void>();
    final calls = <String>[];
    final queue = DownloadQueueController.forTesting(
      runner: (entry, _) async {
        calls.add(entry.track.url);
        if (calls.length == 1) {
          started.complete();
          await continueFirst.future;
        }
        final path = p.join(directory.path, '${entry.track.videoId}.mp3');
        await File(path).writeAsString('audio');
        await const TrackSourceRepository().saveSource(
          localPath: path,
          youtubeVideoId: entry.track.videoId!,
          method: TrackSourceMethod.downloadedByResonance,
        );
        await files.replaceStreamWithDownload(1, entry.track.url, path);
        return path;
      },
    );
    final service = PlaylistOfflineService(files: files, queue: queue);
    addTearDown(service.dispose);
    addTearDown(queue.dispose);
    final operation = service.makeOffline(1);
    await started.future;
    service.cancel(1);
    continueFirst.complete();
    await operation;
    expect(calls, [first]);
    expect((await files.readPlaylistTracks(1)).last, second);
    expect(service.progress[1]!.running, isFalse);
    await service.makeOffline(1);
    expect(calls, [first, second]);
  });
  test('persistent random sorting keeps a converted stream in the same position', () async {
    final directory = await Directory.systemTemp.createTemp('resonance-offline-random-');
    addTearDown(() => directory.delete(recursive: true));
    final files = FileService(documentsPathOverride: directory.path);
    final tracks = [
      'https://www.youtube.com/watch?v=aaaaaaaaaaa',
      'https://www.youtube.com/watch?v=bbbbbbbbbbb',
      'https://www.youtube.com/watch?v=ccccccccccc',
    ];
    await files.replacePlaylistTracks(1, tracks);
    await files.sortPlaylist(1, PlaylistSortMode.random);
    final before = await files.readPlaylistTracks(1), local = p.join(directory.path, 'download.mp3');
    await File(local).writeAsString('audio');
    await const TrackSourceRepository().saveSource(
      localPath: local,
      youtubeVideoId: 'bbbbbbbbbbb',
      method: TrackSourceMethod.downloadedByResonance,
    );
    await files.replaceStreamWithDownload(1, tracks[1], local);
    expect(await files.readPlaylistTracks(1), before.map((path) => path == tracks[1] ? local : path).toList());
  });
}
