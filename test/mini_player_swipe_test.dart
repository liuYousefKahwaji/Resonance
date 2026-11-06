import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/player/mini_player_swipe_surface.dart';

void main() {
  for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
    testWidgets('mini player swipes skip tracks without expanding or triggering a button in $direction', (
      tester,
    ) async {
      var next = 0, previous = 0, expanded = 0, tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: MiniPlayerSwipeSurface(
                    onNext: () => next++,
                    onPrevious: () => previous++,
                    onExpand: () => expanded++,
                    child: SizedBox(
                      height: 70,
                      child: Row(
                        children: [
                          const Expanded(child: Text('Song')),
                          IconButton(onPressed: () => tapped++, icon: const Icon(Icons.play_arrow)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final surface = find.byKey(const Key('mini-player-swipe-surface'));
      await tester.fling(surface, const Offset(-110, 0), 700);
      await tester.pumpAndSettle();
      expect(next, 1);
      expect(previous, 0);
      expect(expanded, 0);
      expect(tapped, 0);
      await tester.fling(surface, const Offset(110, 0), 700);
      await tester.pumpAndSettle();
      expect(previous, 1);
      await tester.drag(surface, const Offset(-12, 0));
      await tester.pumpAndSettle();
      expect(next, 1, reason: 'Small drags must not skip songs');
      await tester.fling(surface, const Offset(0, -100), 700);
      await tester.pumpAndSettle();
      expect(expanded, 1);
      expect(next, 1);
      await tester.tap(find.byIcon(Icons.play_arrow));
      expect(tapped, 1);
    });
  }
}
