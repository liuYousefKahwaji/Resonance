import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_audio_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_audio_flutter/ffmpeg_session.dart';
import 'package:ffmpeg_kit_audio_flutter/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const double normalizationTargetLufs = -14;
const double normalizationTruePeakCeilingDb = -1;
const int loudnessAnalysisVersion = 1;

@immutable
class LoudnessProfile {
  final double integratedLufs;
  final double truePeakDb;
  final double gainDb;
  final int sourceLength;
  final int sourceModifiedMilliseconds;
  final int analysisVersion;

  const LoudnessProfile({
    required this.integratedLufs,
    required this.truePeakDb,
    required this.gainDb,
    required this.sourceLength,
    required this.sourceModifiedMilliseconds,
    this.analysisVersion = loudnessAnalysisVersion,
  });

  double get multiplier => math.pow(10.0, gainDb / 20.0).toDouble();

  Map<String, Object?> toJson() => <String, Object?>{
    'integratedLufs': integratedLufs,
    'truePeakDb': truePeakDb,
    'gainDb': gainDb,
    'sourceLength': sourceLength,
    'sourceModifiedMilliseconds': sourceModifiedMilliseconds,
    'analysisVersion': analysisVersion,
  };

  factory LoudnessProfile.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid loudness profile');
    return LoudnessProfile(
      integratedLufs: (value['integratedLufs'] as num).toDouble(),
      truePeakDb: (value['truePeakDb'] as num).toDouble(),
      gainDb: (value['gainDb'] as num).toDouble(),
      sourceLength: (value['sourceLength'] as num).round(),
      sourceModifiedMilliseconds: (value['sourceModifiedMilliseconds'] as num).round(),
      analysisVersion: (value['analysisVersion'] as num?)?.round() ?? 0,
    );
  }
}

@immutable
class LoudnessMeasurement {
  final double integratedLufs;
  final double truePeakDb;

  const LoudnessMeasurement({required this.integratedLufs, required this.truePeakDb});
}

@visibleForTesting
double calculateNormalizationGainDb({required double integratedLufs, required double truePeakDb}) {
  final loudnessGain = normalizationTargetLufs - integratedLufs;
  final peakSafeGain = normalizationTruePeakCeilingDb - truePeakDb;
  return math.min(loudnessGain, peakSafeGain).clamp(-12.0, 6.0).toDouble();
}

@visibleForTesting
LoudnessMeasurement? parseEbur128Summary(String output) {
  final integratedMatches = RegExp(
    r'Integrated loudness:\s*(?:\r?\n\s*)?I:\s*([-+]?\d+(?:\.\d+)?)\s+LUFS',
    caseSensitive: false,
  ).allMatches(output);
  final peakMatches = RegExp(
    r'True peak:\s*(?:\r?\n\s*)?Peak:\s*([-+]?\d+(?:\.\d+)?)\s+dBFS',
    caseSensitive: false,
  ).allMatches(output);
  if (integratedMatches.isEmpty || peakMatches.isEmpty) return null;
  final integrated = double.tryParse(integratedMatches.last.group(1)!);
  final peak = double.tryParse(peakMatches.last.group(1)!);
  if (integrated == null || peak == null || !integrated.isFinite || !peak.isFinite) return null;
  return LoudnessMeasurement(integratedLufs: integrated, truePeakDb: peak);
}

class LoudnessProfileCache {
  static const _fileName = 'loudness_profiles_v1.json';
  final File _file;
  final Map<String, LoudnessProfile> _profiles;
  Future<void> _writeQueue = Future<void>.value();

  LoudnessProfileCache._(this._file, this._profiles);

  static Future<LoudnessProfileCache> load() async {
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, _fileName));
    final profiles = <String, LoudnessProfile>{};
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is! String) continue;
            try {
              profiles[entry.key as String] = LoudnessProfile.fromJson(entry.value);
            } catch (_) {}
          }
        }
      }
    } catch (error) {
      debugPrint('[LoudnessProfileCache] Could not read cache: $error');
    }
    return LoudnessProfileCache._(file, profiles);
  }

  LoudnessProfile? profileFor(String filePath) {
    if (_isStream(filePath)) return null;
    final profile = _profiles[playbackLoudnessIdentity(filePath)];
    if (profile == null || profile.analysisVersion != loudnessAnalysisVersion) return null;
    try {
      final stat = File(filePath).statSync();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != profile.sourceLength ||
          stat.modified.millisecondsSinceEpoch != profile.sourceModifiedMilliseconds) {
        return null;
      }
      return profile;
    } catch (_) {
      return null;
    }
  }

  Future<void> store(String filePath, LoudnessProfile profile) {
    _profiles[playbackLoudnessIdentity(filePath)] = profile;
    final operation = _writeQueue.then((_) async {
      await _file.parent.create(recursive: true);
      final temporary = File('${_file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(_profiles.map((key, value) => MapEntry(key, value.toJson()))),
        flush: true,
      );
      if (await _file.exists()) await _file.delete();
      await temporary.rename(_file.path);
    });
    _writeQueue = operation.catchError((Object error, StackTrace stackTrace) {
      debugPrint('[LoudnessProfileCache] Could not write cache: $error');
    });
    return operation;
  }
}

String playbackLoudnessIdentity(String filePath) {
  final normalized = p.normalize(p.absolute(filePath));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _isStream(String value) => value.startsWith('http://') || value.startsWith('https://');

class LoudnessAnalyzer {
  Process? _windowsProcess;
  int? _androidSessionId;
  bool _disposed = false;

  Future<LoudnessProfile?> analyze(String filePath) async {
    if (_disposed || _isStream(filePath)) return null;
    final source = File(filePath);
    if (!await source.exists()) return null;
    final stat = await source.stat();
    try {
      final output = Platform.isWindows
          ? await _analyzeWindows(filePath)
          : Platform.isAndroid
          ? await _analyzeAndroid(filePath)
          : null;
      if (_disposed || output == null) return null;
      final measurement = parseEbur128Summary(output);
      if (measurement == null) return null;
      return LoudnessProfile(
        integratedLufs: measurement.integratedLufs,
        truePeakDb: measurement.truePeakDb,
        gainDb: calculateNormalizationGainDb(
          integratedLufs: measurement.integratedLufs,
          truePeakDb: measurement.truePeakDb,
        ),
        sourceLength: stat.size,
        sourceModifiedMilliseconds: stat.modified.millisecondsSinceEpoch,
      );
    } catch (error) {
      debugPrint('[LoudnessAnalyzer] Could not analyze "$filePath": $error');
      return null;
    }
  }

  Future<String?> _analyzeWindows(String input) async {
    final releaseBinary = File(p.join(p.dirname(Platform.resolvedExecutable), 'bin', 'ffmpeg.exe'));
    final developmentBinary = File(p.join(Directory.current.path, 'assets', 'bin', 'ffmpeg.exe'));
    final executable = await releaseBinary.exists() ? releaseBinary.path : developmentBinary.path;
    if (!await File(executable).exists()) return null;
    final process = await Process.start(executable, _arguments(input), runInShell: false);
    _windowsProcess = process;
    final output = StringBuffer();
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = process.stderr.transform(utf8.decoder).listen(output.write).asFuture<void>();
    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    if (identical(_windowsProcess, process)) _windowsProcess = null;
    return exitCode == 0 ? output.toString() : null;
  }

  Future<String?> _analyzeAndroid(String input) async {
    final completion = Completer<FFmpegSession>();
    final session = await FFmpegKit.executeWithArgumentsAsync(_arguments(input), (completed) {
      if (!completion.isCompleted) completion.complete(completed);
    });
    _androidSessionId = session.getSessionId();
    final completed = await completion.future;
    if (_androidSessionId == session.getSessionId()) _androidSessionId = null;
    if (!ReturnCode.isSuccess(await completed.getReturnCode())) return null;
    return completed.getAllLogsAsString();
  }

  List<String> _arguments(String input) => <String>[
    '-hide_banner',
    '-nostats',
    '-nostdin',
    '-threads',
    '1',
    '-i',
    input,
    '-map',
    '0:a:0',
    '-af',
    'ebur128=peak=true',
    '-f',
    'null',
    Platform.isWindows ? 'NUL' : '-',
  ];

  void dispose() {
    _disposed = true;
    _windowsProcess?.kill();
    final sessionId = _androidSessionId;
    if (sessionId != null) unawaited(FFmpegKit.cancel(sessionId));
  }
}

@immutable
class LoudnessScanProgress {
  final bool scanning;
  final int completed;
  final int total;

  const LoudnessScanProgress({this.scanning = false, this.completed = 0, this.total = 0});
}
