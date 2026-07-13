enum ExternalPlaylistKind { spotify, audiomack }

extension ExternalPlaylistKindLabel on ExternalPlaylistKind {
  String get label => switch (this) {
    ExternalPlaylistKind.spotify => 'Spotify',
    ExternalPlaylistKind.audiomack => 'Audiomack',
  };
}

class ExternalPlaylistTrack {
  final String title;
  final List<String> artists;
  final Duration? duration;
  final String? sourceId;

  const ExternalPlaylistTrack({required this.title, required this.artists, this.duration, this.sourceId});

  String get artistLabel => artists.isEmpty ? 'Unknown Artist' : artists.join(', ');

  String get searchQuery => artistLabel == 'Unknown Artist' ? title : '$artistLabel $title';
}

class ExternalPlaylist {
  final ExternalPlaylistKind kind;
  final String name;
  final Uri sourceUri;
  final List<ExternalPlaylistTrack> tracks;

  const ExternalPlaylist({required this.kind, required this.name, required this.sourceUri, required this.tracks});
}
