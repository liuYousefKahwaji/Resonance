import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/widgets/player/seek_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('streams only dim and disable the seekbar while loading a source', (tester) async {
    final handler = _FakePlayerHandler();
    await _showSeekBar(tester, handler);
    final primary = Theme.of(tester.element(find.byType(Slider))).colorScheme.primary;
    void expectPlayable() {
      final theme = tester.widget<SliderTheme>(find.byType(SliderTheme));
      expect(theme.data.activeTrackColor, primary);
      expect(theme.data.thumbColor, primary);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }

    expectPlayable();
    handler.setProcessingState(AudioProcessingState.buffering);
    await tester.pump();
    await tester.pump();
    expectPlayable();
    handler.positions.add(const Duration(seconds: 35));
    await tester.pump();
    expectPlayable();
    handler.setProcessingState(AudioProcessingState.loading);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<SliderTheme>(find.byType(SliderTheme)).data.activeTrackColor, isNot(primary));
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    handler.setProcessingState(AudioProcessingState.ready);
    await tester.pump();
    await tester.pump();
    expectPlayable();
    await tester.pumpWidget(const SizedBox());
    await handler.disposeTest();
  });

  testWidgets('a failed seek restores the live position rather than freezing the preview', (tester) async {
    final handler = _FakePlayerHandler();
    await _showSeekBar(tester, handler);
    handler.seekError = StateError('stream seek failed');
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(0.8);
    slider.onChangeEnd!(0.8);
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, closeTo(0.15, 0.001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await handler.disposeTest();
  });
}

Future<void> _showSeekBar(WidgetTester tester, _FakePlayerHandler handler) async {
  await tester.pumpWidget(
    Provider<PlayerHandler>.value(
      value: handler,
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(
          body: Center(child: SizedBox(width: 700, child: SeekBar())),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _FakePlayerHandler extends Fake implements PlayerHandler {
  final _base = BaseAudioHandler();
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration?>.broadcast();
  Object? seekError;

  _FakePlayerHandler() {
    mediaItem.add(const MediaItem(id: 'https://youtube.test/watch?v=abcdefghijk', title: 'Stream'));
    setProcessingState(AudioProcessingState.ready);
  }

  void setProcessingState(AudioProcessingState state) =>
      playbackState.add(PlaybackState(processingState: state, playing: true));

  @override
  get mediaItem => _base.mediaItem;
  @override
  get playbackState => _base.playbackState;
  @override
  Duration get currentPosition => const Duration(seconds: 30);
  @override
  Duration? get currentDuration => const Duration(seconds: 200);
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  final uiVisibleNotifier = ValueNotifier<bool>(true);
  @override
  final seekStepNotifier = ValueNotifier<int>(5);

  @override
  Future<void> seek(Duration position) async {
    if (seekError != null) throw seekError!;
    positions.add(position);
  }

  Future<void> disposeTest() async {
    await positions.close();
    await durations.close();
    uiVisibleNotifier.dispose();
    seekStepNotifier.dispose();
  }
}
