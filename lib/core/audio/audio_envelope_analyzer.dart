import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:ffmpeg_kit_audio_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_audio_flutter/ffmpeg_session.dart';
import 'package:ffmpeg_kit_audio_flutter/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _analysisSampleRate = 800;
const _envelopeFramesPerSecond = 20;

@immutable
class AudioEnvelope {
  final List<double> samples;
  final int framesPerSecond;

  const AudioEnvelope({required this.samples, required this.framesPerSecond});

  double amplitudeAt(Duration position) {
    if (samples.isEmpty || position <= Duration.zero) return samples.isEmpty ? 0 : samples.first;
    final frame = position.inMicroseconds * framesPerSecond / Duration.microsecondsPerSecond;
    final lower = frame.floor().clamp(0, samples.length - 1);
    final upper = (lower + 1).clamp(0, samples.length - 1);
    final fraction = (frame - lower).clamp(0.0, 1.0);
    return samples[lower] + (samples[upper] - samples[lower]) * fraction;
  }
}

/// Converts low-rate mono PCM into a normalized RMS envelope. FFmpeg performs
/// only decoding/resampling; this function determines the real pulse strength.
@visibleForTesting
AudioEnvelope audioEnvelopeFromPcm16(
  Uint8List bytes, {
  int inputSampleRate = _analysisSampleRate,
  int framesPerSecond = _envelopeFramesPerSecond,
}) {
  if (bytes.length < 2 || inputSampleRate <= 0 || framesPerSecond <= 0) {
    return AudioEnvelope(samples: const [], framesPerSecond: framesPerSecond);
  }

  final samplesPerFrame = math.max(1, inputSampleRate ~/ framesPerSecond);
  final pcmSamples = bytes.length ~/ 2;
  final raw = <double>[];
  final data = ByteData.sublistView(bytes);

  for (var start = 0; start < pcmSamples; start += samplesPerFrame) {
    final end = math.min(start + samplesPerFrame, pcmSamples);
    var sumSquares = 0.0;
    for (var index = start; index < end; index++) {
      final sample = data.getInt16(index * 2, Endian.little) / 32768.0;
      sumSquares += sample * sample;
    }
    raw.add(math.sqrt(sumSquares / math.max(1, end - start)));
  }

  if (raw.isEmpty) return AudioEnvelope(samples: const [], framesPerSecond: framesPerSecond);
  final sorted = List<double>.from(raw)..sort();
  final low = sorted[((sorted.length - 1) * 0.10).round()];
  final high = sorted[((sorted.length - 1) * 0.95).round()];
  final range = math.max(0.00001, high - low);
  final normalized = <double>[];
  var smoothed = 0.0;

  for (final value in raw) {
    final scaled = math.sqrt(((value - low) / range).clamp(0.0, 1.0));
    final response = scaled > smoothed ? 0.58 : 0.24;
    smoothed += (scaled - smoothed) * response;
    normalized.add(smoothed.clamp(0.0, 1.0));
  }
  return AudioEnvelope(samples: normalized, framesPerSecond: framesPerSecond);
}

class AudioEnvelopeAnalyzer {
  final Map<String, ({int modified, AudioEnvelope envelope})> _memoryCache = {};
  Process? _windowsProcess;
  int? _androidSessionId;
  int _request = 0;

  void cancel() {
    _request++;
    _windowsProcess?.kill();
    _windowsProcess = null;
    final sessionId = _androidSessionId;
    _androidSessionId = null;
    if (sessionId != null) unawaited(FFmpegKit.cancel(sessionId));
  }

  Future<AudioEnvelope?> analyze(String filePath) async {
    if (filePath.startsWith('http://') || filePath.startsWith('https://')) return null;
    final request = ++_request;
    final source = File(filePath);
    if (!await source.exists()) return null;
    final modified = (await source.lastModified()).millisecondsSinceEpoch;
    final cached = _memoryCache[filePath];
    if (cached != null && cached.modified == modified) return cached.envelope;

    try {
      final cacheDirectory = Directory(p.join((await getTemporaryDirectory()).path, 'resonance_pulse'));
      await cacheDirectory.create(recursive: true);
      final pcmFile = File(p.join(cacheDirectory.path, '${filePath.hashCode.abs()}_$modified.pcm'));
      if (!await pcmFile.exists() || await pcmFile.length() == 0) {
        await _trimCache(cacheDirectory);
        final decoded = Platform.isWindows
            ? await _decodeWindows(filePath, pcmFile, request)
            : Platform.isAndroid
            ? await _decodeAndroid(filePath, pcmFile, request)
            : false;
        if (!decoded) return null;
      }
      if (request != _request || !await pcmFile.exists()) return null;
      final envelope = audioEnvelopeFromPcm16(await pcmFile.readAsBytes());
      if (request != _request || envelope.samples.isEmpty) return null;
      if (_memoryCache.length >= 16) _memoryCache.remove(_memoryCache.keys.first);
      _memoryCache[filePath] = (modified: modified, envelope: envelope);
      return envelope;
    } catch (error) {
      debugPrint('[AudioEnvelopeAnalyzer] Could not analyze "$filePath": $error');
      return null;
    }
  }

  Future<bool> _decodeWindows(String input, File output, int request) async {
    final releaseBinary = File(p.join(p.dirname(Platform.resolvedExecutable), 'bin', 'ffmpeg.exe'));
    final developmentBinary = File(p.join(Directory.current.path, 'assets', 'bin', 'ffmpeg.exe'));
    final executable = await releaseBinary.exists() ? releaseBinary.path : developmentBinary.path;
    if (!await File(executable).exists()) return false;

    final process = await Process.start(executable, _arguments(input, output.path), runInShell: false);
    _windowsProcess = process;
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = process.stderr.drain<void>();
    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    if (identical(_windowsProcess, process)) _windowsProcess = null;
    if (request != _request || exitCode != 0) {
      if (await output.exists()) await output.delete();
      return false;
    }
    return await output.exists() && await output.length() > 0;
  }

  Future<bool> _decodeAndroid(String input, File output, int request) async {
    final completion = Completer<FFmpegSession>();
    final session = await FFmpegKit.executeWithArgumentsAsync(_arguments(input, output.path), (completed) {
      if (!completion.isCompleted) completion.complete(completed);
    });
    _androidSessionId = session.getSessionId();
    final completed = await completion.future;
    if (_androidSessionId == session.getSessionId()) _androidSessionId = null;
    final success = ReturnCode.isSuccess(await completed.getReturnCode());
    if (request != _request || !success) {
      if (await output.exists()) await output.delete();
      return false;
    }
    return await output.exists() && await output.length() > 0;
  }

  List<String> _arguments(String input, String output) => [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostdin',
    '-threads',
    '1',
    '-i',
    input,
    '-vn',
    '-ac',
    '1',
    '-ar',
    '$_analysisSampleRate',
    '-f',
    's16le',
    '-y',
    output,
  ];

  Future<void> _trimCache(Directory directory) async {
    final files = await directory.list().where((entry) => entry is File).cast<File>().toList();
    if (files.length < 64) return;
    files.sort((first, second) => first.lastModifiedSync().compareTo(second.lastModifiedSync()));
    for (final file in files.take(files.length - 63)) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  void dispose() {
    cancel();
    _memoryCache.clear();
  }
}
