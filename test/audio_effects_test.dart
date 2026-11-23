import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_preferences.dart';

void main() {
  test('Android equalizer interpolates logical bands in logarithmic frequency space', () {
    final settings = EqualizerSettings(gainsDb: const [10, 6, 0, -4, -8]);
    final subBass = interpolatedEqualizerGain(60, settings);
    final lowMid = interpolatedEqualizerGain(230, settings);
    final between = interpolatedEqualizerGain(465, settings);
    final treble = interpolatedEqualizerGain(12000, settings);

    expect(subBass, 10);
    expect(lowMid, 6);
    expect(between, inInclusiveRange(0, 6));
    expect(treble, -8);
  });

  test('Windows five-band filter uses one lavfi graph with explicit format conversion', () {
    expect(buildWindowsAudioFilter(PlaybackAdjustments.neutral), isEmpty);
    expect(
      buildWindowsAudioFilter(PlaybackAdjustments(speed: 1.5, pitch: 0.75)),
      'scaletempo:scale=2.00000000',
      reason: 'pitch correction still applies with a flat equalizer when speed and pitch differ',
    );

    final filter = buildWindowsAudioFilter(
      PlaybackAdjustments(speed: 1.5, pitch: 0.75, equalizer: EqualizerSettings.forPreset(EqualizerPreset.bassBoost)),
    );
    expect(
      filter,
      'scaletempo:scale=2.00000000,'
      'format=format=floatp,'
      'lavfi=['
      'equalizer=f=60:t=q:w=0.70:g=7.00,'
      'equalizer=f=230:t=q:w=0.70:g=4.00,'
      'equalizer=f=910:t=q:w=0.70:g=0.00,'
      'equalizer=f=3600:t=q:w=0.70:g=-1.00,'
      'equalizer=f=12000:t=q:w=0.70:g=-2.00'
      '],'
      'format=format=float',
    );
  });

  test('equalizer reserves extra headroom only above the boosted output ceiling', () {
    final boosted = EqualizerSettings.forPreset(EqualizerPreset.bassBoost);
    expect(boosted.automaticPreampDb, -7);
    expect(equalizerOutputHeadroomMultiplier(boosted, effectApplied: true, outputGain: 0.25), 1.0);
    expect(equalizerOutputHeadroomMultiplier(boosted, effectApplied: true, outputGain: 1.0), closeTo(0.447, 0.001));
    expect(equalizerOutputHeadroomMultiplier(boosted, effectApplied: false, outputGain: 1.0), 1.0);
  });
}
