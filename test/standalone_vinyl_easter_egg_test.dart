import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/widgets/player/vinyl_disc.dart';

void main() {
  testWidgets('standalone artwork flips into the shared spinning vinyl', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 320,
              child: StandaloneArtworkFlip(
                item: const MediaItem(id: 'track.mp3', title: 'Track'),
                isPlaying: true,
                amplitudeProvider: () => 0.8,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ResonanceVinylDisc), findsNothing);
    await tester.tap(find.byKey(standaloneArtworkFlipKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 340));

    expect(find.byKey(standaloneVinylKey), findsOneWidget);
    expect(find.byType(ResonanceVinylDisc), findsOneWidget);

    final rotation = find.descendant(of: find.byKey(standaloneVinylKey), matching: find.byType(Transform));
    final before = List<double>.from(tester.widget<Transform>(rotation).transform.storage);
    await tester.pump(const Duration(milliseconds: 550));
    final after = tester.widget<Transform>(rotation).transform.storage;
    expect(after, isNot(equals(before)));

    await tester.tap(find.byKey(standaloneArtworkFlipKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.byType(ResonanceVinylDisc), findsNothing);
  });
}
