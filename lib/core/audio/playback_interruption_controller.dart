import 'dart:async';

import 'package:audio_session/audio_session.dart';

/// Keeps playback intent separate from temporary loss of Android audio focus.
/// In particular, a paused stream must never be restarted by focus gain or by
/// a recovery timer while a call owns the audio output.
class PlaybackInterruptionController {
  PlaybackInterruptionController({required this.pauseBackend, required this.resumeBackend, required this.onError});

  final Future<void> Function() pauseBackend;
  final Future<void> Function() resumeBackend;
  final void Function(Object, StackTrace) onError;
  bool _desiredPlaying = false;
  bool _blocked = false;
  bool _temporary = false;
  bool _disposed = false;
  int _revision = 0;
  Future<void> _pendingPause = Future<void>.value();

  bool get blocked => _blocked;
  bool get disposed => _disposed;
  Future<void> get pauseComplete => _pendingPause;
  bool get desiredPlaying => _desiredPlaying;
  set desiredPlaying(bool value) {
    if (_disposed) return;
    _desiredPlaying = value;
    // Permanent focus loss has no guaranteed matching gain event. A later
    // explicit Play must be able to request focus again.
    if (value && _blocked && !_temporary) {
      _revision++;
      _blocked = false;
    }
  }

  bool get canPlay => desiredPlaying && !_blocked;

  void handle(AudioInterruptionEvent event) {
    if (_disposed) return;
    // Music usage is ducked by Android itself. Do not change the user's gain.
    if (event.type == AudioInterruptionType.duck) return;
    final revision = ++_revision;
    if (event.begin) {
      _blocked = true;
      _temporary = event.type == AudioInterruptionType.pause;
      if (!_temporary) _desiredPlaying = false;
      // Invoke immediately: backend pause and recovery cancellation happen
      // before any asynchronous work can start playback again.
      final previousPause = _pendingPause;
      final currentPause = _pause();
      _pendingPause = Future.wait([previousPause, currentPause]).then((_) {});
    } else {
      unawaited(_end(event.type, revision));
    }
  }

  Future<void> _pause() async {
    try {
      await pauseBackend();
    } catch (error, stack) {
      onError(error, stack);
    }
  }

  Future<void> _end(AudioInterruptionType type, int revision) async {
    await _pendingPause;
    if (revision != _revision || !_blocked) return;
    _blocked = false;
    _temporary = false;
    if (type == AudioInterruptionType.unknown) desiredPlaying = false;
    if (!canPlay) return;
    try {
      await resumeBackend();
    } catch (error, stack) {
      onError(error, stack);
    }
  }

  void dispose() {
    _revision++;
    _desiredPlaying = false;
    _disposed = true;
    _blocked = true;
  }
}
