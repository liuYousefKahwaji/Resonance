import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'equalizer_settings.dart';
export 'equalizer_settings.dart';

enum PlaybackSettingsScope { global, perTrack }

@immutable
class PlaybackAdjustments {
  final double speed;
  final double pitch;
  final EqualizerSettings equalizer;
  final double volumePercent;

  PlaybackAdjustments({this.speed = 1.0, this.pitch = 1.0, this.volumePercent = 0, EqualizerSettings? equalizer})
    : equalizer = equalizer ?? EqualizerSettings.flat;

  static final neutral = PlaybackAdjustments();

  PlaybackAdjustments copyWith({double? speed, double? pitch, double? volumePercent, EqualizerSettings? equalizer}) =>
      PlaybackAdjustments(
        speed: speed ?? this.speed,
        pitch: pitch ?? this.pitch,
        equalizer: equalizer ?? this.equalizer,
        volumePercent: volumePercent ?? this.volumePercent,
      );

  Map<String, Object?> toJson() => {
    'speed': speed,
    'pitch': pitch,
    'equalizer': equalizer.toJson(),
    'volumePercent': volumePercent,
  };

  factory PlaybackAdjustments.fromJson(Object? value) {
    if (value is! Map) return neutral;
    final speed = (value['speed'] as num?)?.toDouble() ?? 1.0;
    final pitch = (value['pitch'] as num?)?.toDouble() ?? 1.0;
    final equalizer = value.containsKey('equalizer')
        ? EqualizerSettings.fromJson(value['equalizer'])
        : EqualizerSettings.fromLegacyBass((value['bass'] as num?)?.toDouble() ?? 0);
    final volume = value['volumePercent'] is num ? (value['volumePercent'] as num).toDouble() : 0.0;
    return PlaybackAdjustments(
      speed: speed.clamp(0.5, 2.0),
      pitch: pitch.clamp(0.5, 2.0),
      equalizer: equalizer,
      volumePercent: volume.isFinite ? volume.clamp(-100, 100) : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackAdjustments &&
          speed == other.speed &&
          pitch == other.pitch &&
          equalizer == other.equalizer &&
          volumePercent == other.volumePercent;

  @override
  int get hashCode => Object.hash(speed, pitch, equalizer, volumePercent);
}

/// Positive trims use the same 1–2x range as the main volume booster, without
/// stacking two boosts. Reductions still work while the main booster is active.
double trackVolumeMultiplier(double percent, double mainVolume) {
  final trim = percent.isFinite ? percent.clamp(-100.0, 100.0) : 0.0;
  return mainVolume > 1.0 && trim > 0 ? 1.0 : 1.0 + trim / 100.0;
}

/// Returns a stable identity for preference data shared by local and streamed
/// tracks. YouTube identities deliberately ignore presentation URL variants.
String playbackTrackIdentity(String source, {bool? isWindowsOverride}) {
  final uri = Uri.tryParse(source);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return 'youtube:${uri.pathSegments.first}';
    }
    if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
      final videoId = uri.queryParameters['v'];
      if (videoId != null && videoId.isNotEmpty) return 'youtube:$videoId';
      final segments = uri.pathSegments;
      final marker = segments.indexWhere((segment) => segment == 'shorts' || segment == 'embed' || segment == 'live');
      if (marker >= 0 && marker + 1 < segments.length) return 'youtube:${segments[marker + 1]}';
    }
    return uri.replace(fragment: '').toString();
  }

  final normalized = p.normalize(p.absolute(source));
  return (isWindowsOverride ?? Platform.isWindows) ? normalized.toLowerCase() : normalized;
}

bool isLongFormTrack(Duration? duration) => duration != null && duration >= const Duration(minutes: 10);

bool isResumablePosition(Duration position, Duration duration) {
  if (!isLongFormTrack(duration) || position <= Duration.zero) return false;
  return position < duration - const Duration(seconds: 5);
}

class PlaybackPreferenceStore {
  static const _positionsKey = 'long_track_positions_v1';
  static const _adjustmentsKey = 'per_track_playback_settings_v2';
  static const _legacyAdjustmentsKey = 'per_track_playback_settings_v1';
  static const _maximumEntries = 512;

  final SharedPreferences _preferences;
  Map<String, int> _positions;
  Map<String, PlaybackAdjustments> _adjustments;
  Future<void> _positionWriteQueue = Future<void>.value();
  Future<void> _adjustmentWriteQueue = Future<void>.value();

  PlaybackPreferenceStore._(this._preferences, this._positions, this._adjustments);

  static Future<PlaybackPreferenceStore> load({SharedPreferences? preferences}) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    return PlaybackPreferenceStore._(
      prefs,
      _decodePositions(prefs.getString(_positionsKey)),
      _decodeAdjustments(prefs.getString(_adjustmentsKey) ?? prefs.getString(_legacyAdjustmentsKey)),
    );
  }

  Duration? positionFor(String source) {
    final milliseconds = _positions[playbackTrackIdentity(source)];
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  PlaybackAdjustments adjustmentsFor(String source) =>
      _adjustments[playbackTrackIdentity(source)] ?? PlaybackAdjustments.neutral;

  Future<bool> savePosition(String source, Duration position) {
    final identity = playbackTrackIdentity(source);
    return _enqueuePositionWrite(() async {
      final updated = Map<String, int>.from(_positions);
      updated[identity] = position.inMilliseconds;
      _trimOldest(updated);
      final written = await _preferences.setString(_positionsKey, jsonEncode(updated));
      if (written) _positions = updated;
      return written;
    });
  }

  Future<bool> clearPosition(String source) {
    final identity = playbackTrackIdentity(source);
    return _enqueuePositionWrite(() async {
      if (!_positions.containsKey(identity)) return true;
      final updated = Map<String, int>.from(_positions)..remove(identity);
      final written = await _preferences.setString(_positionsKey, jsonEncode(updated));
      if (written) _positions = updated;
      return written;
    });
  }

  Future<bool> saveAdjustments(String source, PlaybackAdjustments adjustments, {bool preserveVolume = false}) {
    final identity = playbackTrackIdentity(source);
    return _enqueueAdjustmentWrite(() async {
      final updated = Map<String, PlaybackAdjustments>.from(_adjustments);
      updated[identity] = preserveVolume
          ? adjustments.copyWith(volumePercent: adjustmentsFor(source).volumePercent)
          : adjustments;
      _trimOldest(updated);
      final encoded = <String, Object?>{for (final entry in updated.entries) entry.key: entry.value.toJson()};
      final written = await _preferences.setString(_adjustmentsKey, jsonEncode(encoded));
      if (written) _adjustments = updated;
      return written;
    });
  }

  Future<bool> saveTrackVolume(String source, double percent) {
    final identity = playbackTrackIdentity(source);
    return _enqueueAdjustmentWrite(() async {
      final updated = Map<String, PlaybackAdjustments>.from(_adjustments);
      updated[identity] = adjustmentsFor(source).copyWith(volumePercent: percent.clamp(-100, 100));
      _trimOldest(updated);
      final written = await _preferences.setString(
        _adjustmentsKey,
        jsonEncode({for (final entry in updated.entries) entry.key: entry.value.toJson()}),
      );
      if (written) _adjustments = updated;
      return written;
    });
  }

  Future<bool> clearAdjustments(String source) {
    final identity = playbackTrackIdentity(source);
    return _enqueueAdjustmentWrite(() async {
      if (!_adjustments.containsKey(identity)) return true;
      final updated = Map<String, PlaybackAdjustments>.from(_adjustments)..remove(identity);
      final encoded = <String, Object?>{for (final entry in updated.entries) entry.key: entry.value.toJson()};
      final written = await _preferences.setString(_adjustmentsKey, jsonEncode(encoded));
      if (written) _adjustments = updated;
      return written;
    });
  }

  Future<bool> _enqueuePositionWrite(Future<bool> Function() write) {
    final operation = _positionWriteQueue.then((_) => write());
    _positionWriteQueue = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<bool> _enqueueAdjustmentWrite(Future<bool> Function() write) {
    final operation = _adjustmentWriteQueue.then((_) => write());
    _adjustmentWriteQueue = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  static Map<String, int> _decodePositions(String? encoded) {
    if (encoded == null || encoded.isEmpty) return {};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return {};
      return <String, int>{
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is num && (entry.value as num) >= 0)
            entry.key as String: (entry.value as num).round(),
      };
    } catch (_) {
      return {};
    }
  }

  static Map<String, PlaybackAdjustments> _decodeAdjustments(String? encoded) {
    if (encoded == null || encoded.isEmpty) return {};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return {};
      return <String, PlaybackAdjustments>{
        for (final entry in decoded.entries)
          if (entry.key is String) entry.key as String: PlaybackAdjustments.fromJson(entry.value),
      };
    } catch (_) {
      return {};
    }
  }

  static void _trimOldest<T>(Map<String, T> values) {
    while (values.length > _maximumEntries) {
      values.remove(values.keys.first);
    }
  }
}
