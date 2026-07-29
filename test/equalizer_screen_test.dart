import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/equalizer_settings.dart';
import 'package:resonance/screens/settings/equalizer_screen.dart';

void main() {
  testWidgets('Custom remains selectable after choosing a built-in preset', (tester) async {
    final handler = _FakePlayerHandler(EqualizerSettings.flat.withBandGain(0, 6));
    await tester.pumpWidget(MaterialApp(home: EqualizerScreen(handler: handler)));

    await tester.tap(find.text('Rock'));
    await tester.pumpAndSettle();
    expect(find.text('Custom'), findsOneWidget);

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    expect(handler.equalizerNotifier.value.preset, EqualizerPreset.custom);
    expect(handler.equalizerNotifier.value.gainsDb, [6, 0, 0, 0, 0]);
    expect(find.text('+6.0 dB'), findsOneWidget);
  });

  testWidgets('external scope updates replace the Custom curve shown on screen', (tester) async {
    final handler = _FakePlayerHandler(EqualizerSettings.flat.withBandGain(0, 7));
    await tester.pumpWidget(MaterialApp(home: EqualizerScreen(handler: handler)));

    handler.equalizerNotifier.value = EqualizerSettings.flat.withBandGain(4, -5);
    await tester.pump();

    expect(find.text('-5.0 dB'), findsOneWidget);
    expect(find.text('+7.0 dB'), findsNothing);
  });
}

class _FakePlayerHandler extends Fake implements PlayerHandler {
  _FakePlayerHandler(EqualizerSettings settings) : equalizerNotifier = ValueNotifier<EqualizerSettings>(settings);

  @override
  final ValueNotifier<EqualizerSettings> equalizerNotifier;

  @override
  Future<void> setEqualizer(EqualizerSettings settings) async {
    equalizerNotifier.value = settings;
  }
}
