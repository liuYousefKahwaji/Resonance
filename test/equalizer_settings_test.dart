import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/equalizer_settings.dart';

void main() {
  test('custom curve remains available while built-in presets are selected', () {
    final custom = EqualizerSettings.flat.withBandGain(0, 6).withBandGain(1, 3);
    final rock = custom.selectPreset(EqualizerPreset.rock);

    expect(rock.preset, EqualizerPreset.rock);
    expect(rock.hasRememberedCustom, isTrue);
    expect(rock.selectPreset(EqualizerPreset.custom).gainsDb, custom.gainsDb);
  });

  test('global and per-track settings keep independent custom curves', () {
    final global = EqualizerSettings.flat.withBandGain(0, 7).selectPreset(EqualizerPreset.pop);
    final perTrack = EqualizerSettings.flat.withBandGain(4, -5).selectPreset(EqualizerPreset.vocal);

    expect(global.selectPreset(EqualizerPreset.custom).gainsDb, [7, 0, 0, 0, 0]);
    expect(perTrack.selectPreset(EqualizerPreset.custom).gainsDb, [0, 0, 0, 0, -5]);
  });

  test('remembered custom curve survives JSON persistence and older custom JSON migrates', () {
    final source = EqualizerSettings.flat.withBandGain(2, 4).selectPreset(EqualizerPreset.electronic);
    final restored = EqualizerSettings.fromJson(source.toJson());
    final migrated = EqualizerSettings.fromJson({
      'enabled': true,
      'preset': 'custom',
      'gainsDb': [1, 2, 3, 4, 5],
    });

    expect(restored, source);
    expect(restored.selectPreset(EqualizerPreset.custom).gainsDb, [0, 0, 4, 0, 0]);
    expect(migrated.customGainsDb, [1, 2, 3, 4, 5]);
  });

  test('zeroing every custom band removes the remembered curve', () {
    final customized = EqualizerSettings.flat.withBandGain(0, 5);
    final zeroed = customized.withBandGain(0, 0);

    expect(zeroed.preset, EqualizerPreset.custom);
    expect(zeroed.hasRememberedCustom, isFalse);
    expect(zeroed.gainsDb, everyElement(0));
  });
}
