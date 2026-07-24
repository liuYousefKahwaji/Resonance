import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/loudness_normalization.dart';

void main() {
  test('EBU R128 summary parser reads final integrated loudness and true peak', () {
    const output = '''
Integrated loudness:
    I:          -7.1 LUFS

True peak:
    Peak:        1.9 dBFS
''';
    final measurement = parseEbur128Summary(output);

    expect(measurement?.integratedLufs, -7.1);
    expect(measurement?.truePeakDb, 1.9);
  });

  test('normalization gain obeys loudness target, peak ceiling, and clamps', () {
    expect(calculateNormalizationGainDb(integratedLufs: -7.1, truePeakDb: 1.9), closeTo(-6.9, 0.001));
    expect(calculateNormalizationGainDb(integratedLufs: -30, truePeakDb: -20), 6);
    expect(calculateNormalizationGainDb(integratedLufs: 2, truePeakDb: 0), -12);
  });
}
