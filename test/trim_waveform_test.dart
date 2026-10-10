import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/player/trim_waveform.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('edges, section movement and source cursor work in $direction', (tester) async {
      var selection = const RangeValues(2000, 7000);
      Duration? cursor;
      var changesEnded = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Directionality(
              textDirection: direction,
              child: Center(
                child: SizedBox(
                  width: 332,
                  child: StatefulBuilder(
                    builder: (context, setState) => TrimWaveform(
                      duration: const Duration(seconds: 10),
                      values: selection,
                      samples: List.generate(200, (i) => (i % 20) / 20),
                      position: Duration.zero,
                      startLabel: 'Start',
                      endLabel: 'End',
                      onChanged: (value) => setState(() => selection = value),
                      onSeek: (value) => cursor = value,
                      onChangeEnd: () => changesEnded++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final waveform = find.byKey(const Key('trim-waveform'));
      final origin = tester.getTopLeft(waveform);
      // 300px source axis, plus 16px padding. Drag start from 2 to 3 seconds.
      await tester.dragFrom(origin + const Offset(76, 58), const Offset(30, 0));
      await tester.pump();
      expect(selection.start, closeTo(3000, 1));
      expect(selection.end, 7000);
      // Move the whole 4-second section by 1 second.
      await tester.dragFrom(origin + const Offset(166, 58), const Offset(30, 0));
      await tester.pump();
      expect(selection.start, closeTo(4000, 1));
      expect(selection.end, closeTo(8000, 1));
      await tester.tapAt(origin + const Offset(46, 58));
      expect(cursor, const Duration(seconds: 1));
      expect(changesEnded, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('zoom retains original time and very short selections stay editable', (tester) async {
    var selection = const RangeValues(0, 50);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 332,
              child: StatefulBuilder(
                builder: (context, setState) => TrimWaveform(
                  duration: const Duration(seconds: 10),
                  values: selection,
                  samples: const [],
                  position: Duration.zero,
                  zoomed: true,
                  startLabel: 'Start',
                  endLabel: 'End',
                  onChanged: (value) => setState(() => selection = value),
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byKey(const Key('trim-waveform')));
    await tester.dragFrom(origin + const Offset(16, 58), const Offset(35, 0));
    await tester.pump();
    expect(selection.start, 0);
    expect(selection.end, 50);
    expect(tester.takeException(), isNull);
  });
}
