import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_envelope_analyzer.dart';

Uint8List _pcmFrames(List<int> levels, {int samplesPerFrame = 40}) {
  final output = BytesBuilder(copy: false);
  for (final level in levels) {
    for (var index = 0; index < samplesPerFrame; index++) {
      final data = ByteData(2)..setInt16(0, index.isEven ? level : -level, Endian.little);
      output.add(data.buffer.asUint8List());
    }
  }
  return output.takeBytes();
}

void main() {
  test('PCM envelope follows real quiet and loud sections', () {
    final envelope = audioEnvelopeFromPcm16(_pcmFrames([200, 14000, 1200, 9000]));

    expect(envelope.samples, hasLength(4));
    expect(envelope.samples[1], greaterThan(envelope.samples[0] + 0.4));
    expect(envelope.samples[2], lessThan(envelope.samples[1]));
    expect(envelope.amplitudeAt(const Duration(milliseconds: 75)), inInclusiveRange(0.0, 1.0));
  });

  test('empty PCM produces no visualizer envelope', () {
    final envelope = audioEnvelopeFromPcm16(Uint8List(0));

    expect(envelope.samples, isEmpty);
    expect(envelope.amplitudeAt(Duration.zero), 0);
  });
}
