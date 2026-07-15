// The fingerprint format and peak-picking constants in this file are based on
// shazamio-core 1.0.7 (MIT, Copyright 2024 dotX12). See
// THIRD_PARTY_NOTICES.md for attribution. Audio remains local; only this
// irreversible signature is sent to the matching service.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

const int _sampleRate = 16000;
const int _fftSize = 2048;
const int _fftHop = 128;
const int _fftBins = 1025;
const int _historySize = 256;

final Float64List _hannWindow = Float64List.fromList([
  for (var index = 0; index < _fftSize; index++) 0.5 - 0.5 * math.cos(2 * math.pi * (index + 1) / 2049),
]);

enum _FrequencyBand { hz250To520, hz520To1450, hz1450To3500, hz3500To5500 }

class _FrequencyPeak {
  final int fftPassNumber;
  final int magnitude;
  final int correctedFrequencyBin;

  const _FrequencyPeak({required this.fftPassNumber, required this.magnitude, required this.correctedFrequencyBin});
}

class ShazamSignature {
  final String dataUri;
  final int sampleCount;
  final int peakCount;

  const ShazamSignature({required this.dataUri, required this.sampleCount, required this.peakCount});

  int get durationMilliseconds => sampleCount * 1000 ~/ _sampleRate;
}

/// Creates a Shazam-compatible query signature from PCM16 LE, mono, 16 kHz.
class ShazamFingerprint {
  const ShazamFingerprint._();

  static ShazamSignature generate(Uint8List pcm16le) {
    if (pcm16le.lengthInBytes < _sampleRate * 2) {
      throw const FormatException('At least one second of PCM audio is required.');
    }

    final evenLength = pcm16le.lengthInBytes & ~1;
    final sampleData = ByteData.sublistView(pcm16le, 0, evenLength);
    final availableSamples = evenLength ~/ 2;
    final cappedSamples = math.min(availableSamples, _sampleRate * 12);
    final samples = Int16List(cappedSamples);
    for (var index = 0; index < cappedSamples; index++) {
      samples[index] = sampleData.getInt16(index * 2, Endian.little);
    }

    final generator = _SignatureGenerator(samples);
    final peaks = generator.generate();
    final peakCount = peaks.values.fold<int>(0, (total, bandPeaks) => total + bandPeaks.length);
    if (peakCount == 0) {
      throw const FormatException('The recording did not contain enough recognizable audio.');
    }

    final binary = _encodeSignature(generator.processedSamples, peaks);
    return ShazamSignature(
      dataUri: 'data:audio/vnd.shazam.sig;base64,${base64Encode(binary)}',
      sampleCount: generator.processedSamples,
      peakCount: peakCount,
    );
  }
}

class _SignatureGenerator {
  final Int16List samples;
  final Int16List _sampleRing = Int16List(_fftSize);
  final Float64List _windowedSamples = Float64List(_fftSize);
  final List<Float32List> _fftOutputs = List.generate(_historySize, (_) => Float32List(_fftBins));
  final List<Float32List> _spreadOutputs = List.generate(_historySize, (_) => Float32List(_fftBins));
  final FFT _fft = FFT(_fftSize);
  final Map<_FrequencyBand, List<_FrequencyPeak>> _peaks = {};

  int _sampleRingIndex = 0;
  int _fftOutputIndex = 0;
  int _spreadOutputIndex = 0;
  int _spreadFftsDone = 0;
  int processedSamples = 0;

  _SignatureGenerator(this.samples);

  Map<_FrequencyBand, List<_FrequencyPeak>> generate() {
    final fullChunkCount = samples.length ~/ _fftHop;
    for (var chunkIndex = 0; chunkIndex < fullChunkCount; chunkIndex++) {
      final start = chunkIndex * _fftHop;
      _doFft(samples, start);
      _doPeakSpreading();
      _spreadFftsDone++;
      processedSamples += _fftHop;
      if (_spreadFftsDone >= 46) _doPeakRecognition();
    }
    return _peaks;
  }

  void _doFft(Int16List input, int start) {
    _sampleRing.setRange(_sampleRingIndex, _sampleRingIndex + _fftHop, input, start);
    _sampleRingIndex = (_sampleRingIndex + _fftHop) & (_fftSize - 1);

    for (var index = 0; index < _fftSize; index++) {
      _windowedSamples[index] = _sampleRing[(index + _sampleRingIndex) & (_fftSize - 1)] * _hannWindow[index];
    }

    final complex = _fft.realFft(_windowedSamples);
    final output = _fftOutputs[_fftOutputIndex];
    for (var index = 0; index < _fftBins; index++) {
      final value = complex[index];
      final magnitude = (value.x * value.x + value.y * value.y) / 131072.0;
      output[index] = math.max(magnitude, 0.0000000001);
    }
    _fftOutputIndex = (_fftOutputIndex + 1) & (_historySize - 1);
  }

  void _doPeakSpreading() {
    final source = _fftOutputs[(_fftOutputIndex - 1) & (_historySize - 1)];
    final spread = _spreadOutputs[_spreadOutputIndex];
    spread.setAll(0, source);

    for (var position = 0; position <= 1022; position++) {
      spread[position] = math.max(spread[position], math.max(spread[position + 1], spread[position + 2]));
    }

    final current = Float32List.fromList(spread);
    for (final formerDistance in const [1, 3, 6]) {
      final former = _spreadOutputs[(_spreadOutputIndex - formerDistance) & (_historySize - 1)];
      for (var position = 0; position < _fftBins; position++) {
        if (current[position] > former[position]) former[position] = current[position];
      }
    }

    _spreadOutputIndex = (_spreadOutputIndex + 1) & (_historySize - 1);
  }

  void _doPeakRecognition() {
    final candidate = _fftOutputs[(_fftOutputIndex - 46) & (_historySize - 1)];
    final spread = _spreadOutputs[(_spreadOutputIndex - 49) & (_historySize - 1)];

    for (var bin = 10; bin <= 1014; bin++) {
      final candidateMagnitude = candidate[bin];
      if (candidateMagnitude < 1 / 64 || candidateMagnitude < spread[bin - 1]) continue;

      var neighborMaximum = 0.0;
      for (final offset in const [-10, -7, -4, -3, 1, 2, 5, 8]) {
        neighborMaximum = math.max(neighborMaximum, spread[bin + offset]);
      }
      if (candidateMagnitude <= neighborMaximum) continue;

      var adjacentMaximum = neighborMaximum;
      for (final offset in const [-53, -45, 165, 172, 179, 186, 193, 200, 214, 221, 228, 235, 242, 249]) {
        final other = _spreadOutputs[(_spreadOutputIndex + offset) & (_historySize - 1)];
        adjacentMaximum = math.max(adjacentMaximum, other[bin - 1]);
      }
      if (candidateMagnitude <= adjacentMaximum) continue;

      final magnitude = math.log(math.max(1 / 64, candidateMagnitude)) * 1477.3 + 6144;
      final before = math.log(math.max(1 / 64, candidate[bin - 1])) * 1477.3 + 6144;
      final after = math.log(math.max(1 / 64, candidate[bin + 1])) * 1477.3 + 6144;
      final curvature = magnitude * 2 - before - after;
      if (!curvature.isFinite || curvature <= 0) continue;

      final correction = (after - before) * 32 / curvature;
      final correctedBin = (bin * 64 + correction).toInt();
      final frequencyHz = correctedBin * (_sampleRate / 2 / 1024 / 64);
      final band = switch (frequencyHz) {
        >= 250 && < 520 => _FrequencyBand.hz250To520,
        >= 520 && < 1450 => _FrequencyBand.hz520To1450,
        >= 1450 && < 3500 => _FrequencyBand.hz1450To3500,
        >= 3500 && <= 5500 => _FrequencyBand.hz3500To5500,
        _ => null,
      };
      if (band == null) continue;

      (_peaks[band] ??= []).add(
        _FrequencyPeak(
          fftPassNumber: _spreadFftsDone - 46,
          magnitude: magnitude.toInt().clamp(0, 0xffff),
          correctedFrequencyBin: correctedBin.clamp(0, 0xffff),
        ),
      );
    }
  }
}

Uint8List _encodeSignature(int numberSamples, Map<_FrequencyBand, List<_FrequencyPeak>> peaksByBand) {
  final contents = BytesBuilder(copy: false);
  for (final band in _FrequencyBand.values) {
    final peaks = peaksByBand[band];
    if (peaks == null || peaks.isEmpty) continue;

    final encodedPeaks = BytesBuilder(copy: false);
    var lastFftPass = 0;
    for (final peak in peaks) {
      final difference = peak.fftPassNumber - lastFftPass;
      if (difference >= 255) {
        encodedPeaks.addByte(0xff);
        encodedPeaks.add(_u32le(peak.fftPassNumber));
        lastFftPass = peak.fftPassNumber;
      }
      encodedPeaks.addByte(peak.fftPassNumber - lastFftPass);
      encodedPeaks.add(_u16le(peak.magnitude));
      encodedPeaks.add(_u16le(peak.correctedFrequencyBin));
      lastFftPass = peak.fftPassNumber;
    }

    final peakBytes = encodedPeaks.takeBytes();
    contents
      ..add(_u32le(0x60030040 + band.index))
      ..add(_u32le(peakBytes.length))
      ..add(peakBytes);
    final padding = (4 - peakBytes.length % 4) % 4;
    if (padding > 0) contents.add(Uint8List(padding));
  }

  final contentBytes = contents.takeBytes();
  final output = Uint8List(56 + contentBytes.length);
  final data = ByteData.sublistView(output);
  data
    ..setUint32(0, 0xcafe2580, Endian.little)
    ..setUint32(8, output.length - 48, Endian.little)
    ..setUint32(12, 0x94119c00, Endian.little)
    ..setUint32(28, 3 << 27, Endian.little)
    ..setUint32(40, numberSamples + (_sampleRate * 0.24).toInt(), Endian.little)
    ..setUint32(44, (15 << 19) + 0x40000, Endian.little)
    ..setUint32(48, 0x40000000, Endian.little)
    ..setUint32(52, output.length - 48, Endian.little);
  output.setRange(56, output.length, contentBytes);
  data.setUint32(4, _crc32(output, start: 8), Endian.little);
  return output;
}

Uint8List _u16le(int value) {
  final bytes = Uint8List(2);
  ByteData.sublistView(bytes).setUint16(0, value, Endian.little);
  return bytes;
}

Uint8List _u32le(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
  return bytes;
}

int _crc32(Uint8List bytes, {int start = 0}) {
  var crc = 0xffffffff;
  for (var index = start; index < bytes.length; index++) {
    crc ^= bytes[index];
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
