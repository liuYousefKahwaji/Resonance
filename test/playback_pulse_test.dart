import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/player/audio_visualizer.dart';

void main() {
  testWidgets('active playback pulse samples live amplitude', (tester) async {
    var amplitudeReads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: PlaybackPulse(
            active: true,
            borderRadius: 16,
            amplitudeProvider: () {
              amplitudeReads++;
              return 0.8;
            },
            child: const SizedBox(width: 120, height: 48),
          ),
        ),
      ),
    );

    final finder = find.byKey(const ValueKey('playback-pulse'));
    final before = tester.widget<CustomPaint>(finder).painter;
    await tester.pump(const Duration(milliseconds: 300));
    final after = tester.widget<CustomPaint>(finder).painter;

    expect(before, isNot(same(after)));
    expect(amplitudeReads, greaterThan(1));
  });

  testWidgets('paused playback pulse remains settled', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: PlaybackPulse(active: false, borderRadius: 16, child: SizedBox(width: 120, height: 48))),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playback-pulse')), findsOneWidget);
  });
}
