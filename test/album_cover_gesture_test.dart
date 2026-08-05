import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/player/album_cover.dart';

void main() {
  testWidgets('artwork and card body use separate Currently Playing actions', (tester) async {
    var artworkTaps = 0;
    var bodyTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 480,
              child: NowPlayingCard(
                title: 'Current track',
                artist: 'Artist',
                artworkUri: null,
                isPlaying: false,
                isLoading: false,
                hasTrack: true,
                isDark: false,
                onTap: () => bodyTaps++,
                onArtworkTap: () => artworkTaps++,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(pocketVinylKey), findsOneWidget);

    await tester.tap(find.byKey(nowPlayingArtworkTapKey));
    await tester.pump();
    expect(artworkTaps, 1);
    expect(bodyTaps, 0, reason: 'the artwork tap must not also navigate to the playlist');

    await tester.tap(find.byKey(nowPlayingCardTapKey));
    await tester.pump();
    expect(artworkTaps, 1);
    expect(bodyTaps, 1);
  });

  testWidgets('Pocket Vinyl rotates, reacts to playback, and slides out', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 480,
              child: NowPlayingCard(
                title: 'Current track',
                artist: 'Artist',
                artworkUri: null,
                isPlaying: true,
                isLoading: false,
                hasTrack: true,
                isDark: false,
                amplitudeProvider: () => 0.8,
                onTap: () {},
                onArtworkTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    final vinyl = find.byKey(pocketVinylKey);
    final rotation = find.descendant(of: vinyl, matching: find.byType(Transform)).first;
    final before = List<double>.from(tester.widget<Transform>(rotation).transform.storage);
    expect(
      tester.widget<AnimatedPositioned>(find.descendant(of: vinyl, matching: find.byType(AnimatedPositioned))).left,
      17,
    );

    await tester.pump(const Duration(milliseconds: 550));
    final after = tester.widget<Transform>(rotation).transform.storage;
    expect(after, isNot(equals(before)));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Pocket Vinyl remains static when reduced motion is enabled', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: NowPlayingCard(
              title: 'Current track',
              artist: 'Artist',
              artworkUri: null,
              isPlaying: true,
              isLoading: false,
              hasTrack: true,
              isDark: false,
              onTap: () {},
              onArtworkTap: () {},
            ),
          ),
        ),
      ),
    );

    final vinyl = find.byKey(pocketVinylKey);
    final rotation = find.descendant(of: vinyl, matching: find.byType(Transform)).first;
    final before = List<double>.from(tester.widget<Transform>(rotation).transform.storage);
    await tester.pump(const Duration(seconds: 1));
    final after = tester.widget<Transform>(rotation).transform.storage;
    expect(after, equals(before));
  });

  testWidgets('now-playing card gradient accepts three cover colors', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NowPlayingCard(
            title: 'Current track',
            artist: 'Artist',
            artworkUri: null,
            isPlaying: false,
            isLoading: false,
            hasTrack: true,
            isDark: true,
            tintSurface: true,
            playerGradientColors: const [Color(0xFFE24A62), Color(0xFF3478D4), Color(0xFFF2C14E)],
            onTap: () {},
            onArtworkTap: () {},
          ),
        ),
      ),
    );

    final containers = find.descendant(of: find.byKey(nowPlayingCardTapKey), matching: find.byType(AnimatedContainer));
    final decoration = tester.widget<AnimatedContainer>(containers.first).decoration! as BoxDecoration;
    expect((decoration.gradient! as LinearGradient).colors, hasLength(3));
  });
}
