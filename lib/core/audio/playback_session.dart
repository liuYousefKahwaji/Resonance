import 'dart:convert';

/// Only source references and presentation data, never resolved media URLs,
/// cookies or request headers. The decoder is opened only after pressing Play.
class SavedPlaybackEntry {
  const SavedPlaybackEntry({required this.id, required this.title, required this.artist, this.artwork});
  final String id, title, artist;
  final String? artwork;
  Map<String, Object?> toJson() => {'id': id, 'title': title, 'artist': artist, 'artwork': artwork};
  static SavedPlaybackEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    String? field(String key) {
      final s = value[key];
      return s is String && s.length <= 32768 ? s : null;
    }

    final id = field('id'), title = field('title'), artist = field('artist');
    if (id == null || id.isEmpty || title == null || artist == null) return null;
    return SavedPlaybackEntry(id: id, title: title, artist: artist, artwork: field('artwork'));
  }
}

class PlaybackSession {
  const PlaybackSession({
    required this.current,
    required this.position,
    this.duration,
    required this.standalone,
    this.playlistNumber,
    this.playlistIndex,
    this.queue = const [],
    this.originalQueue = const [],
    this.queueIndex,
    this.shufflePaths = const [],
    this.shuffleIndex = -1,
  });
  static const preferenceKey = 'playback_session_v1';
  final SavedPlaybackEntry current;
  final Duration position;
  final Duration? duration;
  final bool standalone;
  final int? playlistNumber, playlistIndex, queueIndex;
  final List<SavedPlaybackEntry> queue, originalQueue;
  final List<String> shufflePaths;
  final int shuffleIndex;

  PlaybackSession withPosition(Duration value) => PlaybackSession(
    current: current,
    position: value,
    duration: duration,
    standalone: standalone,
    playlistNumber: playlistNumber,
    playlistIndex: playlistIndex,
    queue: queue,
    originalQueue: originalQueue,
    queueIndex: queueIndex,
    shufflePaths: shufflePaths,
    shuffleIndex: shuffleIndex,
  );

  String encode() => jsonEncode({
    'version': 1,
    'current': current.toJson(),
    'position': position.inMilliseconds,
    'duration': duration?.inMilliseconds,
    'standalone': standalone,
    'playlist': playlistNumber,
    'playlistIndex': playlistIndex,
    'queue': queue.take(5000).map((e) => e.toJson()).toList(),
    'originalQueue': originalQueue.take(5000).map((e) => e.toJson()).toList(),
    'queueIndex': queueIndex,
    'shufflePaths': shufflePaths.take(5000).toList(),
    'shuffleIndex': shuffleIndex,
  });

  static PlaybackSession? decode(String? encoded) {
    if (encoded == null || encoded.length > 8 * 1024 * 1024) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map || value['version'] != 1) return null;
      final current = SavedPlaybackEntry.fromJson(value['current']);
      if (current == null) return null;
      int? number(String key, {int minimum = 0}) {
        final n = value[key];
        return n is int && n >= minimum && n <= 31536000000 ? n : null;
      }

      List<SavedPlaybackEntry> entries(String key) => value[key] is List
          ? (value[key] as List).take(5000).map(SavedPlaybackEntry.fromJson).whereType<SavedPlaybackEntry>().toList()
          : const [];
      final duration = number('duration');
      var position = number('position') ?? 0;
      if (duration != null && (duration == 0 || position >= duration - 1000)) position = 0;
      return PlaybackSession(
        current: current,
        position: Duration(milliseconds: position),
        duration: duration == null ? null : Duration(milliseconds: duration),
        standalone: value['standalone'] == true,
        playlistNumber: number('playlist'),
        playlistIndex: number('playlistIndex'),
        queueIndex: number('queueIndex'),
        queue: entries('queue'),
        originalQueue: entries('originalQueue'),
        shufflePaths: value['shufflePaths'] is List
            ? (value['shufflePaths'] as List)
                  .take(5000)
                  .whereType<String>()
                  .where((e) => e.isNotEmpty && e.length <= 32768)
                  .toList()
            : const [],
        shuffleIndex: number('shuffleIndex', minimum: -1) ?? -1,
      );
    } catch (_) {
      return null;
    }
  }
}
