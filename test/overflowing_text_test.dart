import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/common/overflowing_text.dart';

void main() {
  testWidgets('animates when text exceeds the available width', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 80,
            child: OverflowingText(
              text: 'A title that is much wider than its player controls',
              style: TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('overflowing-text-motion')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('overflowing-text-content'))).width, greaterThan(80));
  });

  testWidgets('stays still when text fits', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            child: OverflowingText(text: 'Short title', style: TextStyle(fontSize: 14)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('overflowing-text-motion')), findsNothing);
  });

  testWidgets('recalculates the full-width child when the viewport changes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final width = ValueNotifier<double>(90);
    addTearDown(width.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ValueListenableBuilder<double>(
            valueListenable: width,
            builder: (context, value, _) => SizedBox(
              key: const ValueKey('overflowing-text-viewport'),
              width: value,
              child: const OverflowingText(
                text: 'The complete title remains laid out beyond the clipped viewport',
                style: TextStyle(fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final contentWidth = tester.getSize(find.byKey(const ValueKey('overflowing-text-content'))).width;
    expect(contentWidth, greaterThan(90));

    width.value = contentWidth + 20;
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('overflowing-text-viewport'))).width, contentWidth + 20);
    expect(find.byKey(const ValueKey('overflowing-text-motion')), findsNothing);
  });
}
