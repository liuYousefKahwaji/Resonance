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
}
