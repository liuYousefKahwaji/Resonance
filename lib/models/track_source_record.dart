enum TrackSourceMethod {
  downloadedByResonance,
  matchedDuringTransfer,
  manuallySelected,
  importedFromQrTransfer,
  importedFromExternalPlaylist,
}

class TrackSourceRecord {
  final String localTrackKey;
  final String localPath;
  final String youtubeVideoId;
  final String canonicalUrl;
  final TrackSourceMethod method;
  final DateTime createdAt;
  final DateTime? lastVerifiedAt;

  const TrackSourceRecord({
    required this.localTrackKey,
    required this.localPath,
    required this.youtubeVideoId,
    required this.canonicalUrl,
    required this.method,
    required this.createdAt,
    this.lastVerifiedAt,
  });

  Map<String, dynamic> toJson() => {
    'localTrackKey': localTrackKey,
    'localPath': localPath,
    'youtubeVideoId': youtubeVideoId,
    'canonicalUrl': canonicalUrl,
    'method': method.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (lastVerifiedAt != null) 'lastVerifiedAt': lastVerifiedAt!.toUtc().toIso8601String(),
  };

  factory TrackSourceRecord.fromJson(Map<String, dynamic> json) {
    final methodName = json['method']?.toString();
    final method = TrackSourceMethod.values.where((value) => value.name == methodName).firstOrNull;
    return TrackSourceRecord(
      localTrackKey: json['localTrackKey']?.toString() ?? '',
      localPath: json['localPath']?.toString() ?? '',
      youtubeVideoId: json['youtubeVideoId']?.toString() ?? '',
      canonicalUrl: json['canonicalUrl']?.toString() ?? '',
      method: method ?? TrackSourceMethod.matchedDuringTransfer,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      lastVerifiedAt: DateTime.tryParse(json['lastVerifiedAt']?.toString() ?? ''),
    );
  }
}
