import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/download_queue_entry.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/download/download_queue_controller.dart';

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
}
