import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';

void main() {
  test('standalone swipe classification follows player semantics', () {
    expect(standalonePlayerSwipeAction(const Offset(-120, 0)), StandalonePlayerSwipeAction.next);
    expect(standalonePlayerSwipeAction(const Offset(120, 0)), StandalonePlayerSwipeAction.previous);
    expect(standalonePlayerSwipeAction(const Offset(0, 120)), StandalonePlayerSwipeAction.exit);
    expect(standalonePlayerSwipeAction(const Offset(0, -120)), StandalonePlayerSwipeAction.queue);
    expect(standalonePlayerSwipeAction(const Offset(30, 0)), isNull);
    expect(standalonePlayerSwipeAction(const Offset(80, 75)), isNull);
  });

  testWidgets('touch swipes invoke next, previous, queue, and exit exactly once', (tester) async {
    var nextCount = 0;
    var previousCount = 0;
    bool? previousRestartCurrent;
    var queueCount = 0;
    var exitCount = 0;
    await tester.pumpWidget(
      _GestureHarness(
        onNext: () => nextCount++,
        onPrevious: ({required restartCurrent}) {
          previousCount++;
          previousRestartCurrent = restartCurrent;
        },
        onQueue: () => queueCount++,
        onExit: () => exitCount++,
      ),
    );

    final surface = find.byKey(const Key('gesture-test-surface'));
    await tester.drag(surface, const Offset(-160, 0));
    await tester.drag(surface, const Offset(160, 0));
    await tester.drag(surface, const Offset(0, -160));
    await tester.drag(surface, const Offset(0, 160));
    await tester.pump();

    expect(nextCount, 1);
    expect(previousCount, 1);
    expect(previousRestartCurrent, isFalse);
    expect(queueCount, 1);
    expect(exitCount, 1);
  });

  testWidgets('mouse drag invokes the same swipe callbacks on Windows', (tester) async {
    var nextCount = 0;
    var queueCount = 0;
    await tester.pumpWidget(
      _GestureHarness(
        onNext: () => nextCount++,
        onPrevious: ({required restartCurrent}) {},
        onQueue: () => queueCount++,
        onExit: () {},
      ),
    );

    final center = tester.getCenter(find.byKey(const Key('gesture-test-surface')));
    final mouse = await tester.startGesture(center, kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(-160, 0));
    await mouse.up();
    final upwardMouse = await tester.startGesture(center, kind: PointerDeviceKind.mouse);
    await upwardMouse.moveBy(const Offset(0, -160));
    await upwardMouse.up();
    await tester.pump();

    expect(nextCount, 1);
    expect(queueCount, 1);
  });

  testWidgets('peer mode accepts only the upward queue gesture', (tester) async {
    var nextCount = 0;
    var previousCount = 0;
    var queueCount = 0;
    var exitCount = 0;
    await tester.pumpWidget(
      _GestureHarness(
        queueOnly: true,
        onNext: () => nextCount++,
        onPrevious: ({required restartCurrent}) => previousCount++,
        onQueue: () => queueCount++,
        onExit: () => exitCount++,
      ),
    );

    final surface = find.byKey(const Key('gesture-test-surface'));
    await tester.drag(surface, const Offset(-160, 0));
    await tester.drag(surface, const Offset(160, 0));
    await tester.drag(surface, const Offset(0, 160));
    await tester.drag(surface, const Offset(0, -160));
    await tester.pump();

    expect(nextCount, 0);
    expect(previousCount, 0);
    expect(exitCount, 0);
    expect(queueCount, 1);
  });
}

class _GestureHarness extends StatelessWidget {
  final VoidCallback onNext;
  final void Function({required bool restartCurrent}) onPrevious;
  final VoidCallback onQueue;
  final VoidCallback onExit;
  final bool queueOnly;

  const _GestureHarness({
    required this.onNext,
    required this.onPrevious,
    required this.onQueue,
    required this.onExit,
    this.queueOnly = false,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: StandalonePlayerGestureSurface(
        key: const Key('gesture-test-surface'),
        onNext: onNext,
        onPrevious: onPrevious,
        onQueue: onQueue,
        onExit: onExit,
        queueOnly: queueOnly,
        child: const SizedBox.expand(),
      ),
    ),
  );
}
