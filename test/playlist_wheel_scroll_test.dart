import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/library/playlist_scroll_controller.dart';

void main() {
  Future<void> showList(WidgetTester tester, ScrollController controller, {bool reducedMotion = false}) =>
      tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
            child: child!,
          ),
          home: Scaffold(
            body: ReorderableListView.builder(
              scrollController: controller,
              itemExtent: 70,
              itemCount: 200,
              itemBuilder: (_, index) => SizedBox(key: ValueKey(index), child: Text('Track $index')),
              onReorder: (_, _) {},
            ),
          ),
        ),
      );

  Future<void> wheel(WidgetTester tester, double delta) => tester.sendEventToBinding(
    PointerScrollEvent(
      kind: PointerDeviceKind.mouse,
      device: 1,
      position: tester.getCenter(find.byType(ReorderableListView)),
      scrollDelta: Offset(0, delta),
    ),
  );

  testWidgets('Windows wheel motion progresses on 120 Hz frames and preserves repeated ticks', (tester) async {
    final controller = PlaylistScrollController();
    addTearDown(controller.dispose);
    await showList(tester, controller);
    await wheel(tester, 120);
    expect(controller.offset, 0);
    await tester.pump();
    await tester.pump(const Duration(microseconds: 8333));
    expect(controller.offset, inExclusiveRange(0, 120));
    await wheel(tester, 120);
    final offsets = <double>[controller.offset];
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
      offsets.add(controller.offset);
    }
    for (var frame = 1; frame < offsets.length; frame++) {
      expect(offsets[frame], greaterThan(offsets[frame - 1]));
    }
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(240, .01));
  });

  testWidgets('a reverse tick or a programmatic jump interrupts pending wheel travel', (tester) async {
    final controller = PlaylistScrollController();
    addTearDown(controller.dispose);
    await showList(tester, controller);
    controller.jumpTo(500);
    await wheel(tester, 120);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final turn = controller.offset;
    await wheel(tester, -120);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(turn - 120, .01));

    await wheel(tester, 120);
    controller.jumpTo(900);
    await wheel(tester, -120);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(780, .01));
  });

  testWidgets('reduced motion retains immediate native wheel scrolling', (tester) async {
    final controller = PlaylistScrollController();
    addTearDown(controller.dispose);
    await showList(tester, controller, reducedMotion: true);
    await wheel(tester, 120);
    expect(controller.offset, 120);
  });
}
