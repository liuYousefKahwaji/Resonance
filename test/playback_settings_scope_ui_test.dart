import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_preferences.dart';
import 'package:resonance/widgets/player/playback_settings.dart';

void main() {
  testWidgets('track volume remains separate from scope and explains booster interaction', (tester) async {
    final handler = _FakePlayerHandler();
    await tester.pumpWidget(
      Provider<PlayerHandler>.value(
        value: handler,
        child: const MaterialApp(home: Scaffold(body: PlaybackSettings())),
      ),
    );
    await tester.tap(find.byTooltip('Playback Settings'));
    await tester.pumpAndSettle();
    expect(find.text('First song'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byKey(const Key('track-volume-slider')));
    slider.onChanged!(65);
    await tester.pump();
    expect(find.text('+65%'), findsOneWidget);
    await tester.tap(find.text('Per track'));
    await tester.pumpAndSettle();
    expect(handler.trackVolumePercentNotifier.value, 65);
    handler.volumeNotifier.value = 1.5;
    await tester.pump();
    expect(find.textContaining('Positive track boosts are paused'), findsOneWidget);
    handler.trackVolumePercentNotifier.value = -20;
    handler.mediaItem.add(const MediaItem(id: 'song2', title: 'Second song'));
    await tester.pump();
    expect(find.text('Second song'), findsOneWidget);
    expect(find.text('-20%'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Reset track volume'));
    await tester.tap(find.byTooltip('Reset track volume'));
    await tester.pump();
    expect(handler.trackVolumePercentNotifier.value, 0);
  });
  testWidgets('quick playback settings changes scope and refreshes active values', (tester) async {
    final handler = _FakePlayerHandler();
    await tester.pumpWidget(
      Provider<PlayerHandler>.value(
        value: handler,
        child: const MaterialApp(home: Scaffold(body: PlaybackSettings())),
      ),
    );

    await tester.tap(find.byTooltip('Playback Settings'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('playback-scope-selector')), findsOneWidget);
    expect(find.text('All tracks'), findsOneWidget);
    expect(find.text('1.0x'), findsNWidgets(2));

    await tester.tap(find.text('Per track'));
    await tester.pumpAndSettle();

    expect(handler.playbackSettingsScopeNotifier.value, PlaybackSettingsScope.perTrack);
    expect(find.text('1.4x'), findsOneWidget);
    expect(find.text('0.9x'), findsOneWidget);
    expect(find.text('Remember these settings separately for each track.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FakePlayerHandler extends Fake implements PlayerHandler {
  @override
  final mediaItem = (BaseAudioHandler()..mediaItem.add(const MediaItem(id: 'song1', title: 'First song'))).mediaItem;
  @override
  final ValueNotifier<double> volumeNotifier = ValueNotifier<double>(1);
  @override
  final ValueNotifier<double> trackVolumePercentNotifier = ValueNotifier<double>(0);
  @override
  Future<void> setTrackVolumePercent(double percent) async => trackVolumePercentNotifier.value = percent;
  @override
  final ValueNotifier<double> speedNotifier = ValueNotifier<double>(1);

  @override
  final ValueNotifier<double> pitchNotifier = ValueNotifier<double>(1);

  @override
  final ValueNotifier<EqualizerSettings> equalizerNotifier = ValueNotifier<EqualizerSettings>(EqualizerSettings.flat);

  @override
  final ValueNotifier<PlaybackSettingsScope> playbackSettingsScopeNotifier = ValueNotifier<PlaybackSettingsScope>(
    PlaybackSettingsScope.global,
  );

  @override
  Future<void> setPlaybackSettingsScope(PlaybackSettingsScope scope) async {
    playbackSettingsScopeNotifier.value = scope;
    if (scope == PlaybackSettingsScope.perTrack) {
      speedNotifier.value = 1.4;
      pitchNotifier.value = 0.9;
    }
  }

  @override
  Future<void> setSpeed(double speed) async => speedNotifier.value = speed;

  @override
  Future<void> setPitch(double pitch) async => pitchNotifier.value = pitch;

  @override
  Future<void> resetPlaybackAdjustments() async {
    speedNotifier.value = 1;
    pitchNotifier.value = 1;
  }
}
