import 'package:resonance/models/youtube_track.dart';

enum YoutubeArtistSort {
  newest('Newest'),
  oldest('Oldest'),
  popular('Popular');

  const YoutubeArtistSort(this.label);
  final String label;
}

class YoutubeArtistProfile {
  const YoutubeArtistProfile({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.bannerUrl,
    this.description = '',
  });
  final String id;
  final String name;
  final String? avatarUrl;
  final String? bannerUrl;
  final String description;
}

class YoutubeArtistCursor {
  const YoutubeArtistCursor({required this.token, required this.context}) : remaining = null;
  const YoutubeArtistCursor.local(this.remaining) : token = '', context = const {};
  final String token;
  final Map<String, dynamic> context;
  final List<YoutubeTrack>? remaining;
}

class YoutubeArtistPage {
  const YoutubeArtistPage({
    required this.artist,
    required this.tracks,
    this.next,
    this.availableSorts = const {YoutubeArtistSort.newest},
  });
  final YoutubeArtistProfile artist;
  final List<YoutubeTrack> tracks;
  final YoutubeArtistCursor? next;
  final Set<YoutubeArtistSort> availableSorts;
}

class YoutubeArtistException implements Exception {
  const YoutubeArtistException(this.message);
  final String message;
  @override
  String toString() => message;
}
