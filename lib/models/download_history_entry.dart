class DownloadHistoryEntry {
  final String id;
  final String title;
  final String artist;
  final String source;
  final String localPath;
  final DateTime downloadedAt;
  final bool succeeded;
  final String? failureMessage;

  const DownloadHistoryEntry({
    required this.id,
    required this.title,
    required this.artist,
    required this.source,
    required this.localPath,
    required this.downloadedAt,
    required this.succeeded,
    this.failureMessage,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'source': source,
    'localPath': localPath,
    'downloadedAt': downloadedAt.toUtc().toIso8601String(),
    'succeeded': succeeded,
    if (failureMessage case final message?) 'failureMessage': message,
  };

  factory DownloadHistoryEntry.fromJson(Map<String, dynamic> json) {
    final timestamp = DateTime.tryParse(json['downloadedAt']?.toString() ?? '');
    return DownloadHistoryEntry(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Unknown track',
      artist: json['artist']?.toString() ?? 'Unknown artist',
      source: json['source']?.toString() ?? '',
      localPath: json['localPath']?.toString() ?? '',
      downloadedAt: timestamp ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      succeeded: json['succeeded'] == true,
      failureMessage: json['failureMessage']?.toString(),
    );
  }
}
