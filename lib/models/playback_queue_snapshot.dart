import 'package:flutter/foundation.dart';

enum QueueLoopBehavior { off, one, all }

@immutable
class PlaybackQueueEntry {
  final String id;
  final String title;
  final String artist;
  final Uri? artworkUri;

  const PlaybackQueueEntry({required this.id, required this.title, required this.artist, this.artworkUri});
}

@immutable
class PlaybackQueueSnapshot {
  final PlaybackQueueEntry? current;
  final List<PlaybackQueueEntry> upcoming;
  final QueueLoopBehavior loopBehavior;
  final bool shuffled;

  const PlaybackQueueSnapshot({
    required this.current,
    required this.upcoming,
    required this.loopBehavior,
    required this.shuffled,
  });

  static const empty = PlaybackQueueSnapshot(
    current: null,
    upcoming: [],
    loopBehavior: QueueLoopBehavior.off,
    shuffled: false,
  );
}
