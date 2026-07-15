import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/library/track_tile.dart';

void main() {
  test('track taps restart the active track and load a different track', () {
    expect(trackTapAction(activeTrackPath: 'active.mp3', tappedTrackPath: 'active.mp3'), TrackTapAction.restart);
    expect(trackTapAction(activeTrackPath: 'active.mp3', tappedTrackPath: 'other.mp3'), TrackTapAction.load);
  });

  testWidgets('touch scrolling over a track does not activate it', (tester) async {
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 160,
            child: ListView(
              children: [
                TrackTapRegion(
                  onTap: () => activations++,
                  onLongPress: null,
                  borderRadius: BorderRadius.zero,
                  child: const SizedBox(height: 600, child: Text('Track')),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final region = tester.getRect(find.byType(TrackTapRegion));
    final gesture = await tester.startGesture(Offset(region.center.dx, region.top + 60), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 30));
    expect(activations, 0, reason: 'pointer-down must not start playback');

    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(activations, 0, reason: 'the scroll gesture must cancel the tile tap');
  });

  testWidgets('each completed tap activates immediately, including rapid taps', (tester) async {
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackTapRegion(
            onTap: () => activations++,
            onLongPress: null,
            borderRadius: BorderRadius.zero,
            child: const SizedBox(width: 160, height: 80, child: Text('Track')),
          ),
        ),
      ),
    );

    final location = tester.getCenter(find.byType(TrackTapRegion));
    final firstTap = await tester.startGesture(location, kind: PointerDeviceKind.touch);
    expect(activations, 0);
    await firstTap.up();
    await tester.pump();
    expect(activations, 1);

    final secondTap = await tester.startGesture(location, kind: PointerDeviceKind.touch);
    await secondTap.up();
    await tester.pump();
    expect(activations, 2);
  });
}
