class ListeningHistoryEntry {
  final String trackPath;
  final String title;
  final String artist;
  final String? artworkUri;
  final DateTime playedAt;

  const ListeningHistoryEntry({
    required this.trackPath,
    required this.title,
    required this.artist,
    required this.playedAt,
    this.artworkUri,
  });

  Map<String, dynamic> toJson() => {
    'trackPath': trackPath,
    'title': title,
    'artist': artist,
    'playedAt': playedAt.toUtc().toIso8601String(),
    if (artworkUri != null) 'artworkUri': artworkUri,
  };

  factory ListeningHistoryEntry.fromJson(Map<String, dynamic> json) => ListeningHistoryEntry(
    trackPath: json['trackPath']?.toString() ?? '',
    title: json['title']?.toString().trim().isNotEmpty == true ? json['title'].toString() : 'Unknown track',
    artist: json['artist']?.toString().trim().isNotEmpty == true ? json['artist'].toString() : 'Unknown artist',
    artworkUri: json['artworkUri']?.toString(),
    playedAt: DateTime.tryParse(json['playedAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
  );
}
