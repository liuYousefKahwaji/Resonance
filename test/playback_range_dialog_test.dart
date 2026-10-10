import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_range.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/widgets/player/playback_range_dialog.dart';

class _Handler extends Fake implements PlayerHandler {
  @override
  final playbackRangePreviewNotifier = ValueNotifier<PlaybackRangePreviewState?>(null);
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  final mediaItem = (BaseAudioHandler()..mediaItem.add(const MediaItem(id: 'song.mp3', title: 'Song'))).mediaItem;
  @override
  Duration get currentSourcePosition => const Duration(seconds: 30);
  PlaybackRange? saved;
  PlaybackRange? preview;
  int stopCalls = 0;
  @override
  Future<Duration?> originalDurationFor(String path) async => const Duration(minutes: 3);
  @override
  Future<PlaybackRange> playbackRangeFor(String path) async =>
      const PlaybackRange(start: Duration(seconds: 10), end: Duration(seconds: 90));
  @override
  Future<void> savePlaybackRange(String path, PlaybackRange range) async {
    saved = range;
  }

  @override
  Future<void> previewPlaybackRange(String path, PlaybackRange range) async {
    preview = range;
    playbackRangePreviewNotifier.value = PlaybackRangePreviewState(path: path, position: range.start, playing: true);
  }

  @override
  Future<void> stopPlaybackRangePreview({bool resume = true}) async {
    stopCalls++;
    playbackRangePreviewNotifier.value = null;
  }
}

void main() {
  testWidgets('use current position sets the edge without typing a time', (tester) async {
    final handler = _Handler();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showPlaybackRangeDialog(context, handler, 'song.mp3', 'Song', waveformLoader: (_) async => null),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trim-start-here')));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('trim-start-time'))).controller!.text, '00:30');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(handler.saved!.start, const Duration(seconds: 30));
  });
  testWidgets('reset saves the whole song and closes the editor', (tester) async {
    final handler = _Handler();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showPlaybackRangeDialog(context, handler, 'song.mp3', 'Song', waveformLoader: (_) async => null),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to full song'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(handler.saved, PlaybackRange.full);
    expect(find.byType(PlaybackRangeDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final language in ['en', 'ar']) {
    testWidgets('range editor validates and previews without saving on a narrow $language screen', (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final handler = _Handler();
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showPlaybackRangeDialog(context, handler, 'song.mp3', 'A song', waveformLoader: (_) async => null),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.first).controller!.text, '00:10');
      await tester.enterText(fields.last, '00:05');
      await tester.ensureVisible(find.byType(FilledButton));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(handler.saved, isNull);
      await tester.enterText(fields.first, '00:30');
      await tester.enterText(fields.last, '01:00');
      await tester.ensureVisible(find.byKey(const Key('trim-preview')));
      await tester.tap(find.byKey(const Key('trim-preview')));
      await tester.pumpAndSettle();
      expect(handler.preview, const PlaybackRange(start: Duration(seconds: 30), end: Duration(minutes: 1)));
      expect(handler.saved, isNull);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text(language == 'ar' ? 'إلغاء' : 'Cancel'));
      await tester.tap(find.text(language == 'ar' ? 'إلغاء' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(handler.stopCalls, greaterThan(0));
    });
  }
}
