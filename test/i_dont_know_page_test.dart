import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/screens/settings/i_dont_know_page.dart';

void main() {
  testWidgets('the thirteenth ask exits once after three seconds', (tester) async {
    var exits = 0;
    await tester.pumpWidget(MaterialApp(home: IDontKnowPage(onExit: () => exits++)));
    for (var ask = 1; ask <= 13; ask++) {
      await tester.tap(find.byKey(const Key('secret-record')));
      await tester.pump();
      if (ask >= 10) {
        final answer = [
          'You should stop now.',
          'Stop now.',
          'Do it again, I dare you.',
          'Okay, you asked for it.',
        ][ask - 10];
        expect(find.text(answer), findsOneWidget);
      }
      expect(exits, 0);
    }
    await tester.tap(find.byKey(const Key('secret-record')));
    await tester.pump(const Duration(milliseconds: 2999));
    expect(exits, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(exits, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(exits, 1);
  });

  testWidgets('leaving the secret page cancels its pending exit', (tester) async {
    var exits = 0;
    await tester.pumpWidget(MaterialApp(home: IDontKnowPage(onExit: () => exits++)));
    for (var ask = 0; ask < 13; ask++) {
      await tester.tap(find.byKey(const Key('secret-record')));
      await tester.pump();
    }
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 4));
    expect(exits, 0);
  });

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
