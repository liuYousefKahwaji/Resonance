import 'package:resonance/models/youtube_track.dart';
import 'package:flutter/foundation.dart';

enum QueueLoopBehavior { off, one, all }

enum PlaybackQueueSurface { library, discover, search, other }

@immutable
class PlaybackQueueEntry {
  final String id;
  final String title;
  final String artist;
  final Uri? artworkUri;

  const PlaybackQueueEntry({required this.id, required this.title, required this.artist, this.artworkUri});

  factory PlaybackQueueEntry.youtube(YoutubeTrack track) => PlaybackQueueEntry(
    id: track.url,
    title: track.title,
    artist: track.artist,
    artworkUri: track.thumbnailUrl == null ? null : Uri.tryParse(track.thumbnailUrl!),
  );
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
