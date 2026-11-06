import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/download_queue_entry.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/widgets/youtube/download_queue_panel.dart';

void main() {
  testWidgets('one overlay queue opens over every tab and cancels active work', (tester) async {
    final release = Completer<void>();
    final queue = DownloadQueueController.forTesting(
      runner: (_, __) async {
        await release.future;
        return 'late.mp3';
      },
    );
    const track = YoutubeTrack(title: 'Pending song', artist: 'Artist', url: 'https://youtu.be/abcdefghijk');
    final download = queue.enqueue(track, 1);
    final tab = ValueNotifier('Discover');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(
              actions: [
                IconButton(
                  tooltip: 'Downloads',
                  icon: const Icon(Icons.download),
                  onPressed: () => showDownloadQueue(context, controller: queue),
                ),
              ],
            ),
            body: ValueListenableBuilder(valueListenable: tab, builder: (_, value, __) => Text(value)),
          ),
        ),
      ),
    );
    for (final page in ['Discover', 'Search', 'Library']) {
      tab.value = page;
      await tester.pump();
      await tester.tap(find.byTooltip('Downloads'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Download queue'), findsOneWidget);
      expect(find.text('Pending song'), findsOneWidget);
      if (page == 'Library') {
        await tester.tap(find.byTooltip('Cancel download'));
        await tester.pump();
        expect(await download, isNull);
        expect(queue.entries.single.status, DownloadQueueStatus.cancelled);
        expect(find.byTooltip('Retry'), findsOneWidget);
      }
      Navigator.of(tester.element(find.byType(DownloadQueuePanel))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    release.complete();
    await tester.pump();
    expect(queue.entries.single.localPath, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    queue.dispose();
    tab.dispose();
  });
}
