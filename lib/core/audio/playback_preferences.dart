import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

enum PlaybackSettingsScope { global, perTrack }

@immutable
class PlaybackAdjustments {
  final double speed;
  final double pitch;
  final double bass;

  const PlaybackAdjustments({this.speed = 1.0, this.pitch = 1.0, this.bass = 0.0});

  static const neutral = PlaybackAdjustments();

  PlaybackAdjustments copyWith({double? speed, double? pitch, double? bass}) =>
      PlaybackAdjustments(speed: speed ?? this.speed, pitch: pitch ?? this.pitch, bass: bass ?? this.bass);

  Map<String, double> toJson() => {'speed': speed, 'pitch': pitch, 'bass': bass};

  factory PlaybackAdjustments.fromJson(Object? value) {
    if (value is! Map) return neutral;
    final speed = (value['speed'] as num?)?.toDouble() ?? 1.0;
    final pitch = (value['pitch'] as num?)?.toDouble() ?? 1.0;
    final bass = (value['bass'] as num?)?.toDouble() ?? 0.0;
    return PlaybackAdjustments(speed: speed.clamp(0.5, 2.0), pitch: pitch.clamp(0.5, 2.0), bass: bass.clamp(0.0, 1.0));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackAdjustments && speed == other.speed && pitch == other.pitch && bass == other.bass;

  @override
  int get hashCode => Object.hash(speed, pitch, bass);
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
  static const _adjustmentsKey = 'per_track_playback_settings_v1';
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
      _decodeAdjustments(prefs.getString(_adjustmentsKey)),
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

  Future<bool> saveAdjustments(String source, PlaybackAdjustments adjustments) {
    final identity = playbackTrackIdentity(source);
    return _enqueueAdjustmentWrite(() async {
      final updated = Map<String, PlaybackAdjustments>.from(_adjustments);
      updated[identity] = adjustments;
      _trimOldest(updated);
      final encoded = <String, Object?>{for (final entry in updated.entries) entry.key: entry.value.toJson()};
      final written = await _preferences.setString(_adjustmentsKey, jsonEncode(encoded));
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
