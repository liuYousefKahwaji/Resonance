import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/playback_queue_snapshot.dart';
import 'package:resonance/widgets/player/upcoming_queue.dart';

void main() {
  testWidgets('shows current and effective upcoming order', (tester) async {
    final revision = ValueNotifier<int>(0);
    const current = PlaybackQueueEntry(id: 'one', title: 'Current track', artist: 'Artist A');
    const next = PlaybackQueueEntry(id: 'two', title: 'Next track', artist: 'Artist B');
    const later = PlaybackQueueEntry(id: 'three', title: 'Later track', artist: 'Artist C');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 560,
            child: UpcomingQueuePanel(
              mediaItemStream: Stream.value(const MediaItem(id: 'one', title: 'Current track')),
              initialMediaItem: const MediaItem(id: 'one', title: 'Current track'),
              revision: revision,
              loadSnapshot: () async => const PlaybackQueueSnapshot(
                current: current,
                upcoming: [next, later],
                loopBehavior: QueueLoopBehavior.all,
                shuffled: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current track'), findsOneWidget);
    expect(find.text('Next track'), findsOneWidget);
    expect(find.text('Later track'), findsOneWidget);
    expect(find.text('NOW'), findsOneWidget);
    expect(find.text('Queue repeats after the final track'), findsOneWidget);
    expect(find.byIcon(Icons.shuffle_rounded), findsOneWidget);
  });

  testWidgets('can start an upcoming track when enabled', (tester) async {
    final revision = ValueNotifier<int>(0);
    const current = PlaybackQueueEntry(id: 'one', title: 'Current', artist: 'Artist');
    const next = PlaybackQueueEntry(id: 'two', title: 'Play me', artist: 'Artist');
    PlaybackQueueEntry? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 480,
            child: UpcomingQueuePanel(
              mediaItemStream: const Stream.empty(),
              initialMediaItem: const MediaItem(id: 'one', title: 'Current'),
              revision: revision,
              loadSnapshot: () async => const PlaybackQueueSnapshot(
                current: current,
                upcoming: [next],
                loopBehavior: QueueLoopBehavior.off,
                shuffled: false,
              ),
              onPlay: (entry) async => selected = entry,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play me'));
    await tester.pump();

    expect(selected?.id, 'two');
  });
}
