import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/download_queue_entry.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';

void main() {
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
}
