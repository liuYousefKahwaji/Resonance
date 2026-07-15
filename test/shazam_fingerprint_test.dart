import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/music_recognition/shazam_fingerprint.dart';

void main() {
  test('generates a deterministic Shazam signature with a valid header and CRC', () {
    final pcm = _synthesizedMusic(const Duration(seconds: 5));
    final signature = ShazamFingerprint.generate(pcm);

    expect(signature.peakCount, greaterThan(0));
    expect(signature.sampleCount, 5 * 16000);
    expect(signature.durationMilliseconds, 5000);

    final encoded = signature.dataUri.split(',').last;
    final binary = base64Decode(encoded);
    final data = ByteData.sublistView(binary);
    expect(data.getUint32(0, Endian.little), 0xcafe2580);
    expect(data.getUint32(8, Endian.little), binary.length - 48);
    expect(data.getUint32(12, Endian.little), 0x94119c00);
    expect(data.getUint32(28, Endian.little), 3 << 27);
    expect(data.getUint32(40, Endian.little), signature.sampleCount + 3840);
    expect(data.getUint32(4, Endian.little), _crc32(binary, start: 8));

    expect(ShazamFingerprint.generate(pcm).dataUri, signature.dataUri);
  });

  test('rejects recordings shorter than one second', () {
    expect(() => ShazamFingerprint.generate(Uint8List(100)), throwsFormatException);
  });
}

Uint8List _synthesizedMusic(Duration duration) {
  const sampleRate = 16000;
  final sampleCount = duration.inMilliseconds * sampleRate ~/ 1000;
  final bytes = Uint8List(sampleCount * 2);
  final data = ByteData.sublistView(bytes);
  var phaseA = 0.0;
  var phaseB = 0.0;
  var phaseC = 0.0;
  for (var index = 0; index < sampleCount; index++) {
    final time = index / sampleRate;
    phaseA += 2 * math.pi * (310 + 520 * ((time * 0.41) % 1)) / sampleRate;
    phaseB += 2 * math.pi * (930 + 1700 * ((time * 0.23) % 1)) / sampleRate;
    phaseC += 2 * math.pi * (2800 + 1900 * ((time * 0.17) % 1)) / sampleRate;
    final envelope = 0.55 + 0.45 * math.sin(2 * math.pi * time * 1.7).abs();
    final value = (math.sin(phaseA) * 9000 + math.sin(phaseB) * 6500 + math.sin(phaseC) * 4200) * envelope;
    data.setInt16(index * 2, value.round().clamp(-32768, 32767), Endian.little);
  }
  return bytes;
}

int _crc32(Uint8List bytes, {required int start}) {
  var crc = 0xffffffff;
  for (var index = start; index < bytes.length; index++) {
    crc ^= bytes[index];
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
