import 'package:resonance/models/youtube_track.dart';

/// A shelf returned by YouTube Music's authenticated home feed.
///
/// The feed is intentionally normalized at the platform boundary. Cookie
/// material and raw YouTube Music responses never cross into Flutter.
class YoutubeMusicHomeShelf {
  final String title;
  final List<YoutubeTrack> tracks;
  final List<YoutubeMusicHomeItem> items;

  const YoutubeMusicHomeShelf({required this.title, required this.tracks, this.items = const []});

  List<YoutubeMusicHomeItem> get displayItems =>
      items.isNotEmpty ? items : [for (final track in tracks) YoutubeMusicHomeItem.fromTrack(track)];
}

/// A Home card can be a directly playable song/video or a collection such as
/// an album or mix. Collection cards stay visible so the feed matches YouTube
/// Music, but only directly playable cards expose playback actions.
class YoutubeMusicHomeItem {
  final String title;
  final String subtitle;
  final String? thumbnailUrl;
  final String kind;
  final YoutubeTrack? track;
  final String? playlistId;
  final String? browseId;

  const YoutubeMusicHomeItem({
    required this.title,
    required this.subtitle,
    required this.kind,
    this.thumbnailUrl,
    this.track,
    this.playlistId,
    this.browseId,
  });

  /// The canonical playlist URL used by the existing cross-platform playlist
  /// reader. YouTube Music exposes this for playlists, mixes, and most albums.
  String? get playlistUrl {
    final id = playlistId?.trim() ?? '';
    if (id.isNotEmpty) return Uri.https('music.youtube.com', '/playlist', {'list': id}).toString();
    final browse = browseId?.trim() ?? '';
    if (browse.startsWith('VL') && browse.length > 2) {
      return Uri.https('music.youtube.com', '/playlist', {'list': browse.substring(2)}).toString();
    }
    if (browse.startsWith('MPRE')) return Uri.https('music.youtube.com', '/browse/$browse').toString();
    return null;
  }

  factory YoutubeMusicHomeItem.fromTrack(YoutubeTrack track) => YoutubeMusicHomeItem(
    title: track.title,
    subtitle: track.artist,
    thumbnailUrl: track.thumbnailUrl,
    kind: 'track',
    track: track,
  );
}

class YoutubeMusicHome {
  final List<YoutubeMusicHomeShelf> shelves;

  const YoutubeMusicHome({required this.shelves});

  bool get isEmpty => shelves.every((shelf) => shelf.displayItems.isEmpty);
}
