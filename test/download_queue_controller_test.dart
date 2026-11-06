import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/download_queue_entry.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('rapid duplicate queue taps share one pending download', () async {
    final release = Completer<void>();
    var runCount = 0;
    final controller = DownloadQueueController.forTesting(
      runner: (entry, onProgress) async {
        runCount++;
        onProgress(25, 'Downloading');
        await release.future;
        return 'downloaded.mp3';
      },
    );
    const track = YoutubeTrack(title: 'One song', artist: 'Artist', url: 'https://www.youtube.com/watch?v=duplicate01');

    final first = controller.enqueue(track, 1);
    final second = controller.enqueue(track, 1);
    expect(controller.entries, hasLength(1));
    expect(controller.pendingEntryFor(track.url, 1)?.status, DownloadQueueStatus.downloading);
    expect(runCount, 1);

    release.complete();
    expect(await first, 'downloaded.mp3');
    expect(await second, 'downloaded.mp3');
    expect(runCount, 1);
  });

  test('access failures retain a compact kind and explicit retry state', () async {
    final controller = DownloadQueueController.forTesting(
      runner: (_, __) async => throw const YoutubeFailure(
        kind: YoutubeFailureKind.verificationRequired,
        userMessage: 'YouTube verification is required.',
        technicalSummary: 'raw details which are not stored',
      ),
    );
    const track = YoutubeTrack(title: 'One song', artist: 'Artist', url: 'https://youtu.be/verification');

    await expectLater(controller.enqueue(track, 1), throwsA(isA<YoutubeFailure>()));
    expect(controller.entries.single.status, DownloadQueueStatus.failed);
    expect(controller.entries.single.failureKind, YoutubeFailureKind.verificationRequired);
    expect(controller.entries.single.error, 'YouTube verification is required.');
    expect(controller.entries.single.error, isNot(contains('raw details')));
  });
  test('stream replacement intent survives failure and retry', () async {
    var attempts = 0;
    final controller = DownloadQueueController.forTesting(
      maxAutomaticRetries: 0,
      runner: (entry, _) async {
        expect(entry.replaceStream, isTrue);
        expect(entry.playlistNumber, 3);
        if (attempts++ == 0) throw StateError('Temporary failure');
        return 'local.mp3';
      },
    );
    const track = YoutubeTrack(title: 'Song', artist: 'Artist', url: 'https://youtu.be/abcdefghijk');
    await expectLater(controller.enqueue(track, 3, replaceStream: true), throwsStateError);
    await controller.retry(controller.entries.single.id);
    expect(controller.entries.single.status, DownloadQueueStatus.completed);
    expect(controller.entries.single.replaceStream, isTrue);
    controller.dispose();
  });
  const track = YoutubeTrack(title: 'Song', artist: 'Artist', url: 'https://youtu.be/abcdefghijk');
  test('Drive failure has three retries, persists stop, and manual retry resets budget', () async {
    var attempts = 0;
    final first = DownloadQueueController.forTesting(
      persist: true,
      runner: (_, __) async {
        attempts++;
        throw StateError('Temporary failure');
      },
    );
    await expectLater(
      first.enqueue(track, 3, replaceStream: true, automaticKey: 'account/file/video'),
      throwsStateError,
    );
    expect(attempts, 4);
    expect(first.entries.single.attempts, 4);
    await first.flush();
    first.dispose();
    var succeeds = false;
    final restored = DownloadQueueController.forTesting(
      persist: true,
      runner: (entry, _) async {
        attempts++;
        expect(entry.replaceStream, isTrue);
        expect(entry.attempts, lessThanOrEqualTo(4));
        if (!succeeds) throw StateError('Temporary failure');
        return 'local.mp3';
      },
    );
    await restored.ready;
    expect(restored.entries.single.status, DownloadQueueStatus.failed);
    expect(await restored.enqueue(track, 3, automaticKey: 'account/file/video'), isNull);
    expect(attempts, 4);
    succeeds = true;
    await restored.retry(restored.entries.single.id);
    expect(attempts, 5);
    expect(restored.entries.single.attempts, 1);
    expect(restored.entries.single.status, DownloadQueueStatus.completed);
    await restored.flush();
    restored.dispose();
  });

  test('cancel settles promptly but holds worker until native acknowledgment', () async {
    final release = Completer<void>();
    final runs = <String>[];
    final controller = DownloadQueueController.forTesting(
      runner: (entry, progress) async {
        runs.add(entry.track.url);
        if (runs.length == 1) {
          await release.future;
          progress(90, 'Late progress');
        }
        return 'local.mp3';
      },
    );
    final first = controller.enqueue(track, 1, automaticKey: 'drive/song');
    const secondTrack = YoutubeTrack(title: 'Next', artist: 'Artist', url: 'https://youtu.be/secondtrack');
    final second = controller.enqueue(secondTrack, 1);
    final request = controller.activeRequest!;
    controller.cancel(controller.entries.first.id);
    expect(await first, isNull);
    expect(request.isCancelled, isTrue);
    expect(runs, [track.url]);
    expect(controller.entries.first.status, DownloadQueueStatus.cancelled);
    release.complete();
    expect(await second, 'local.mp3');
    expect(controller.entries.first.status, DownloadQueueStatus.cancelled);
    expect(controller.entries.first.localPath, isNull);
    expect(runs, [track.url, secondTrack.url]);
    controller.dispose();
  });

  test('clearing cancelled and queued Drive work keeps suppression after restart', () async {
    final release = Completer<void>();
    var runs = 0;
    final controller = DownloadQueueController.forTesting(
      persist: true,
      runner: (_, __) async {
        runs++;
        await release.future;
        return 'late.mp3';
      },
    );
    await controller.ready;
    final first = controller.enqueue(track, 1, automaticKey: 'drive/one');
    await Future<void>.delayed(Duration.zero);
    const other = YoutubeTrack(title: 'Other', artist: '', url: 'https://youtu.be/othertrack1');
    final second = controller.enqueue(other, 1, automaticKey: 'drive/two');
    controller.clearAll();
    expect(await first, isNull);
    expect(await second, isNull);
    release.complete();
    await Future<void>.delayed(Duration.zero);
    await controller.flush();
    controller.dispose();
    final restored = DownloadQueueController.forTesting(
      persist: true,
      runner: (_, __) async {
        runs++;
        return 'bad';
      },
    );
    await restored.ready;
    expect(restored.entries, isEmpty);
    expect(await restored.enqueue(track, 1, automaticKey: 'drive/one'), isNull);
    expect(await restored.enqueue(other, 1, automaticKey: 'drive/two'), isNull);
    expect(runs, 1);
    restored.dispose();
  });

  test('restart cannot reset the consumed retry budget', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      DownloadQueueController.storageKey,
      jsonEncode({
        'entries': [
          {
            'id': 'interrupted',
            'url': track.url,
            'playlist': 1,
            'status': 'downloading',
            'attempts': 3,
            'automaticKey': 'drive/interrupted',
          },
        ],
      }),
    );
    var runs = 0;
    final controller = DownloadQueueController.forTesting(
      persist: true,
      runner: (entry, _) async {
        runs++;
        expect(entry.attempts, 4);
        throw StateError('offline');
      },
    );
    await controller.ready;
    final job = controller.enqueue(track, 1, automaticKey: 'drive/interrupted');
    // Restored entries share the same completion and are explicitly resumed here.
    controller.resume();
    await expectLater(job, throwsStateError);
    expect(runs, 1);
    expect(controller.entries.single.status, DownloadQueueStatus.failed);
    await controller.flush();
    controller.dispose();
  });
}
