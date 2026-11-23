import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/models/playback_queue_snapshot.dart';
import 'package:resonance/widgets/common/play_next_button.dart';

void main() {
  testWidgets('only the active surface exposes Play Next and its width animates', (tester) async {
    final handler = _Handler();
    addTearDown(handler.activeQueueSurface.dispose);
    const entry = PlaybackQueueEntry(id: 'one', title: 'Track', artist: 'Artist');
    final library = find.byKey(const Key('library-play-next'));
    final discover = find.byKey(const Key('discover-play-next'));
    await tester.pumpWidget(
      Provider<PlayerHandler>.value(
        value: handler,
        child: const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                PlayNextButton(key: Key('library-play-next'), entry: entry, surface: PlaybackQueueSurface.library),
                PlayNextButton(key: Key('discover-play-next'), entry: entry, surface: PlaybackQueueSurface.discover),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('Play next'), findsNothing);
    handler.activeQueueSurface.value = PlaybackQueueSurface.library;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(tester.getSize(library).width, inExclusiveRange(0, 42));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: library, matching: find.byTooltip('Play next')));
    expect(handler.queuedSurface, PlaybackQueueSurface.library);
    handler.activeQueueSurface.value = PlaybackQueueSurface.discover;
    await tester.pumpAndSettle();
    expect(tester.getSize(library).width, 0);
    expect(find.descendant(of: discover, matching: find.byTooltip('Play next')), findsOneWidget);
  });
}

class _Handler extends Fake implements PlayerHandler {
  @override
  final activeQueueSurface = ValueNotifier<PlaybackQueueSurface?>(null);
  PlaybackQueueSurface? queuedSurface;

  @override
  bool playNext(PlaybackQueueEntry entry, {required PlaybackQueueSurface surface}) {
    queuedSurface = surface;
    return true;
  }
}
