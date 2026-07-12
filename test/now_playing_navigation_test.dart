import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/app/now_playing_navigation.dart';

void main() {
  test('standalone playback resolves to the standalone player', () {
    expect(nowPlayingDestination(isStandalone: true), NowPlayingDestination.standalonePlayer);
    expect(nowPlayingDestination(isStandalone: false), NowPlayingDestination.playlist);
  });

  testWidgets('standalone Currently Playing tap pushes through the app navigator', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    var revealed = false;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Library')),
      ),
    );

    final navigation = navigateFromNowPlaying(
      navigator: navigatorKey.currentState!,
      isStandalone: true,
      trackPath: 'https://youtu.be/jNQXAC9IVRw',
      revealTrack: (_) => revealed = true,
      standaloneRouteBuilder: () =>
          MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Standalone player'))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Standalone player'), findsOneWidget);
    expect(revealed, isFalse);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await navigation;
  });

  testWidgets('playlist Currently Playing tap reveals without pushing a route', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    String? revealedPath;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Library')),
      ),
    );

    await navigateFromNowPlaying(
      navigator: navigatorKey.currentState!,
      isStandalone: false,
      trackPath: r'C:\Music\track.mp3',
      revealTrack: (path) => revealedPath = path,
    );
    await tester.pumpAndSettle();

    expect(revealedPath, r'C:\Music\track.mp3');
    expect(find.text('Library'), findsOneWidget);
  });
}
