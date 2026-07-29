import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/widgets/player/vinyl_disc.dart';

void main() {
  testWidgets('standalone artwork stays still while the shared vinyl slides out and retracts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 416,
              height: 320,
              child: StandaloneArtworkVinylReveal(
                item: const MediaItem(id: 'track.mp3', title: 'Track'),
                isPlaying: true,
                amplitudeProvider: () => 0.8,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ResonanceVinylDisc), findsOneWidget);
    final coverBefore = tester.getRect(find.byKey(standaloneArtworkCoverKey));
    final hiddenTransform = tester.widget<Transform>(find.byKey(standaloneVinylRevealTransformKey));
    expect(hiddenTransform.transform.storage[12], closeTo(0, 0.001));

    await tester.tap(find.byKey(standaloneArtworkRevealKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byKey(standaloneVinylKey), findsOneWidget);
    expect(find.byType(ResonanceVinylDisc), findsOneWidget);
    final revealedTransform = tester.widget<Transform>(find.byKey(standaloneVinylRevealTransformKey));
    expect(revealedTransform.transform.storage[12], greaterThan(80));
    expect(tester.getRect(find.byKey(standaloneArtworkCoverKey)), coverBefore);

    final rotation = find.descendant(of: find.byKey(standaloneVinylKey), matching: find.byType(Transform));
    final before = List<double>.from(tester.widget<Transform>(rotation).transform.storage);
    await tester.pump(const Duration(milliseconds: 550));
    final after = tester.widget<Transform>(rotation).transform.storage;
    expect(after, isNot(equals(before)));

    await tester.tap(find.byKey(standaloneArtworkRevealKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 520));
    final retractedTransform = tester.widget<Transform>(find.byKey(standaloneVinylRevealTransformKey));
    expect(retractedTransform.transform.storage[12], closeTo(0, 0.001));
    expect(tester.getRect(find.byKey(standaloneArtworkCoverKey)), coverBefore);
  });
}
