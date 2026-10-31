import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_failure.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/widgets/player/playback_recovery_banner.dart';
import 'package:resonance/widgets/common/resonance_dialog.dart';

const failedUrl = 'https://www.youtube.com/watch?v=abcdefghijk';
const failure = PlaybackFailure(
  generation: 1,
  track: MediaItem(id: failedUrl, title: 'Unavailable', artist: 'Artist'),
  error: YoutubeFailure(kind: YoutubeFailureKind.unavailable, userMessage: 'This YouTube video is unavailable.'),
);

void main() {
  testWidgets('failure is non-modal, Retry and Dismiss remain accessible', (tester) async {
    final handler = _Handler();
    final nav = GlobalKey<NavigatorState>();
    var otherSelected = false;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        builder: (context, child) => Column(
          children: [
            Expanded(child: child!),
            PlaybackRecoveryBanner(handler: handler, navigatorKey: nav),
          ],
        ),
        home: Scaffold(
          body: TextButton(onPressed: () => otherSelected = true, child: const Text('Another song')),
        ),
      ),
    );
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('Another song'));
    expect(otherSelected, isTrue);
    await tester.tap(find.text('Retry'));
    expect(handler.retries, 1);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(find.text('Find another upload'), findsNothing);
    handler.playbackFailureNotifier.dispose();
  });
  testWidgets('Drive failures offer retry without misleading YouTube actions', (tester) async {
    final handler = _Handler(
      const PlaybackFailure(
        generation: 1,
        track: MediaItem(id: 'https://drive.google.com/file/d/example/view', title: 'Drive song'),
        error: YoutubeFailure(kind: YoutubeFailureKind.unknown, userMessage: 'The YouTube request failed. Try again.'),
      ),
    );
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: Scaffold(
          body: PlaybackRecoveryBanner(handler: handler, navigatorKey: nav),
        ),
      ),
    );
    expect(find.text('Find another upload'), findsNothing);
    expect(find.text('The YouTube request failed. Try again.'), findsNothing);
    expect(find.text('Playback stopped. Check your connection and try again.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    handler.playbackFailureNotifier.dispose();
  });
  for (final locale in ['en', 'ar']) {
    testWidgets('alternative chooser requires an explicit selection at phone width in $locale', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      YoutubeTrack? selected;
      var searches = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('Open'),
                onPressed: () async {
                  selected = await showResonanceDialog<YoutubeTrack>(
                    context: context,
                    builder: (_) => PlaybackAlternativeDialog(
                      failed: failedUrl,
                      query: 'Artist Song',
                      search: (query, source) async {
                        searches++;
                        return const [
                          YoutubeTrack(title: 'Unavailable', artist: 'Artist', url: failedUrl),
                          YoutubeTrack(
                            title: 'Other upload',
                            artist: 'Artist',
                            url: 'https://www.youtube.com/watch?v=12345678901',
                          ),
                        ];
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(searches, 1);
      expect(selected, isNull);
      expect(find.text('Unavailable'), findsNothing);
      expect(find.text('Other upload'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Other upload'));
      await tester.pumpAndSettle();
      expect(selected?.videoId, '12345678901');
    });
  }
  testWidgets('closing a pending alternative search ignores its late failure', (tester) async {
    // Future completes with an error after navigation; the disposed widget must
    // not publish a dialog or call setState, nor choose an upload automatically.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaybackAlternativeDialog(failed: failedUrl, query: 'Artist', search: _lateSearch),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

Future<List<YoutubeTrack>> _lateSearch(String query, dynamic source) =>
    Future.delayed(const Duration(milliseconds: 50), () => throw StateError('Offline'));

class _Handler extends Fake implements PlayerHandler {
  @override
  final ValueNotifier<PlaybackFailure?> playbackFailureNotifier;
  _Handler([PlaybackFailure initial = failure]) : playbackFailureNotifier = ValueNotifier(initial);
  int retries = 0;
  @override
  Future<void> retryFailedPlayback(PlaybackFailure failure) async {
    retries++;
  }

  @override
  void dismissPlaybackFailure(PlaybackFailure failure) {
    playbackFailureNotifier.value = null;
  }
}
