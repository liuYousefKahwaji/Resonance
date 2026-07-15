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

    await tester.tap(find.byKey(nowPlayingArtworkTapKey));
    await tester.pump();
    expect(artworkTaps, 1);
    expect(bodyTaps, 0, reason: 'the artwork tap must not also navigate to the playlist');

    await tester.tap(find.byKey(nowPlayingCardTapKey));
    await tester.pump();
    expect(artworkTaps, 1);
    expect(bodyTaps, 1);
  });
}
