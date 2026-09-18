import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:resonance/models/listening_history_entry.dart';
import 'package:resonance/services/listening_history_repository.dart';

/// Records genuine local playback without participating in transport.
class LocalPlaybackHistoryCoordinator {
  LocalPlaybackHistoryCoordinator({
    required ListeningHistoryRepository repository,
    this.threshold = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _repository = repository,
       _clock = clock ?? DateTime.now;

  final ListeningHistoryRepository _repository;
  final Duration threshold;
  final DateTime Function() _clock;
  String? _identity;
  Duration? _lastPosition;
  DateTime? _lastObservedAt;
  Duration _accumulated = Duration.zero;
  bool _recorded = false;

  void onPlaybackSnapshot({required MediaItem? item, required bool playing, required Duration position}) {
    if (item?.id != _identity) _begin(item?.id, position);
    final previousPosition = _lastPosition;
    final previousObservedAt = _lastObservedAt;
    final now = _clock();
    _lastPosition = position;
    _lastObservedAt = now;
    if (_recorded ||
        item == null ||
        _isNetwork(item.id) ||
        !playing ||
        previousPosition == null ||
        previousObservedAt == null) {
      return;
    }
    final positionDelta = position - previousPosition;
    final allowedDelta = now.difference(previousObservedAt) + const Duration(milliseconds: 750);
    if (positionDelta <= Duration.zero || positionDelta > allowedDelta) return;
    _accumulated += positionDelta > const Duration(seconds: 5) ? const Duration(seconds: 5) : positionDelta;
    if (_accumulated < threshold) return;
    _recorded = true;
    unawaited(
      _repository.record(
        ListeningHistoryEntry(
          trackPath: item.id,
          title: item.title,
          artist: item.artist ?? 'Unknown artist',
          artworkUri: item.artUri?.toString(),
          playedAt: now,
        ),
      ),
    );
  }

  void onSessionEnded() => _begin(null, Duration.zero);

  void _begin(String? identity, Duration position) {
    _identity = identity;
    _lastPosition = position;
    _lastObservedAt = _clock();
    _accumulated = Duration.zero;
    _recorded = false;
  }

  static bool _isNetwork(String value) => value.startsWith('http://') || value.startsWith('https://');
}
