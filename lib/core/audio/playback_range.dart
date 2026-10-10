import 'package:flutter/foundation.dart';

/// A non-destructive section of the original file. Public playback time is
/// relative to [start]; lyrics and file analysis keep the original timeline.
@immutable
class PlaybackRange {
  const PlaybackRange({this.start = Duration.zero, this.end});
  static const full = PlaybackRange();
  final Duration start;
  final Duration? end;
  bool get isFull => start == Duration.zero && end == null;

  PlaybackRange bounded(Duration? duration) {
    if (start < Duration.zero || (end != null && end! <= start)) return full;
    if (duration == null || duration <= Duration.zero) return this;
    if (start >= duration) return full;
    final limit = end == null || end! >= duration ? null : end;
    return PlaybackRange(start: start, end: limit);
  }

  Duration? durationOf(Duration? sourceDuration) {
    if (sourceDuration == null || sourceDuration <= Duration.zero) return end == null ? sourceDuration : end! - start;
    final range = bounded(sourceDuration);
    return (range.end ?? sourceDuration) - range.start;
  }

  Duration relative(Duration source, {Duration? sourceDuration}) {
    final value = source - start;
    final length = durationOf(sourceDuration);
    return Duration(microseconds: value.inMicroseconds.clamp(0, length?.inMicroseconds ?? 1 << 62));
  }

  Duration source(Duration relative) => start + (relative < Duration.zero ? Duration.zero : relative);
  Map<String, Object?> toJson() => {'startMs': start.inMilliseconds, 'endMs': end?.inMilliseconds};
  static bool validJson(Object? value) =>
      value is Map &&
      value['startMs'] is int &&
      value['startMs'] >= 0 &&
      (value['endMs'] == null || value['endMs'] is int && value['endMs'] > value['startMs']);
  factory PlaybackRange.fromJson(Object? value) {
    if (!validJson(value)) return full;
    final map = value as Map;
    return PlaybackRange(
      start: Duration(milliseconds: map['startMs']),
      end: map['endMs'] == null ? null : Duration(milliseconds: map['endMs']),
    );
  }
  @override
  bool operator ==(Object other) => other is PlaybackRange && start == other.start && end == other.end;
  @override
  int get hashCode => Object.hash(start, end);
}
