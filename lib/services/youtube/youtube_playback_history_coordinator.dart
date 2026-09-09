import 'dart:async';

import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/youtube/youtube_history_service.dart';

/// Turns real, forward playback progress into at most one history write per
/// active media session. It has no platform/channel/process knowledge.
class YoutubePlaybackHistoryCoordinator {
  YoutubePlaybackHistoryCoordinator({
    required YoutubeHistoryReporter reporter,
    required bool Function() isEnabled,
    this.threshold = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _reporter = reporter,
       _isEnabled = isEnabled,
       _clock = clock ?? DateTime.now;

  final YoutubeHistoryReporter _reporter;
  final bool Function() _isEnabled;
  final Duration threshold;
  final DateTime Function() _clock;

  String? _activeIdentity;
  String? _activeVideoId;
  Duration _accumulatedPlaying = Duration.zero;
  Duration? _lastPosition;
  DateTime? _lastObservedAt;
  bool _reported = false;

  void onPlaybackSnapshot({required String? mediaIdentity, required bool playing, required Duration position}) {
    if (mediaIdentity != _activeIdentity) {
      _beginSession(mediaIdentity, position);
    }

    final previousPosition = _lastPosition;
    final previousObservedAt = _lastObservedAt;
    final now = _clock();
    _lastPosition = position;
    _lastObservedAt = now;

    if (_reported || !_isEnabled() || !playing || _activeVideoId == null) return;
    if (previousPosition == null || previousObservedAt == null) return;

    final positionDelta = position - previousPosition;
    final wallDelta = now.difference(previousObservedAt);
    // A normal stream update moves forward by no more than elapsed wall time
    // plus a compact scheduling tolerance. Larger jumps are seeks/restores.
    final allowedDelta = wallDelta + const Duration(milliseconds: 750);
    if (positionDelta <= Duration.zero || positionDelta > allowedDelta) return;

    _accumulatedPlaying += positionDelta > const Duration(seconds: 5) ? const Duration(seconds: 5) : positionDelta;
    if (_accumulatedPlaying < threshold) return;

    // Set this before asynchronous work so a slow/failing request cannot be
    // repeated by every position tick.
    _reported = true;
    final videoId = _activeVideoId!;
    unawaited(_writeSafely(videoId));
  }

  void onSessionEnded() {
    _activeIdentity = null;
    _activeVideoId = null;
    _accumulatedPlaying = Duration.zero;
    _lastPosition = null;
    _lastObservedAt = null;
    _reported = false;
  }

  void _beginSession(String? mediaIdentity, Duration position) {
    _activeIdentity = mediaIdentity;
    _activeVideoId = mediaIdentity == null ? null : YoutubeTrack(title: '', artist: '', url: mediaIdentity).videoId;
    _accumulatedPlaying = Duration.zero;
    _lastPosition = position;
    _lastObservedAt = _clock();
    _reported = false;
  }

  Future<void> _writeSafely(String videoId) async {
    try {
      await _reporter.reportVideoId(videoId);
    } catch (_) {
      // Reporter implementations should return failures, but playback must be
      // safe even if an injected implementation unexpectedly throws.
    }
  }
}
