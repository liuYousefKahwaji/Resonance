import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/screens/settings/i_dont_know_page.dart';

void main() {
  test('the version shortcut opens on the fifth tap', () {
    final taps = VersionTapTracker();
    for (var index = 0; index < 4; index++) {
      expect(taps.registerTap(), isFalse);
    }
    expect(taps.registerTap(), isTrue);
    expect(taps.registerTap(), isFalse);
  });

  test('the shortcut works again after another five taps', () {
    final taps = VersionTapTracker();
    for (var index = 0; index < 10; index++) {
      expect(taps.registerTap(), index == 4 || index == 9);
    }
  });

  testWidgets('the secret record responds to taps', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: IDontKnowPage()));
    expect(find.text('I DONT KNOW PAGE'), findsOneWidget);
    expect(find.text('The record is quiet. Suspiciously quiet.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('secret-record')));
    await tester.pumpAndSettle();
    expect(find.text('Have you tried turning the song off and on again?'), findsOneWidget);

    await tester.tap(find.text('Ask the record'));
    await tester.pumpAndSettle();
    expect(find.text('The record says your next song should be louder.'), findsOneWidget);
  });
}
