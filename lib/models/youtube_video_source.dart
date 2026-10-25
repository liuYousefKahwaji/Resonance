class YoutubeMediaVersions {
  const YoutubeMediaVersions({required this.originalId, required this.songId, this.videoId});
  final String originalId, songId;
  final String? videoId;
  static final _id = RegExp(r'^[A-Za-z0-9_-]{11}$');
  factory YoutubeMediaVersions.fromJson(Map<String, dynamic> json) {
    final original = json['originalId']?.toString() ?? '';
    final song = json['songId']?.toString() ?? original;
    final video = json['videoId']?.toString();
    if (!_id.hasMatch(original) || !_id.hasMatch(song) || (video != null && !_id.hasMatch(video))) {
      throw const FormatException('Invalid Song/Video identity');
    }
    return YoutubeMediaVersions(originalId: original, songId: song, videoId: video);
  }
}

class ResolvedYoutubeVideo {
  const ResolvedYoutubeVideo({
    required this.videoUri,
    required this.audioUri,
    this.videoHeaders = const {},
    this.audioHeaders = const {},
  });
  final Uri videoUri, audioUri;
  final Map<String, String> videoHeaders, audioHeaders;

  factory ResolvedYoutubeVideo.fromJson(Map<String, dynamic> json) {
    Uri uri(dynamic raw) {
      final parsed = Uri.tryParse(raw?.toString() ?? '');
      if (parsed == null || !{'https', 'http'}.contains(parsed.scheme) || parsed.host.isEmpty) {
        throw const FormatException('Missing playable video stream');
      }
      return parsed;
    }

    Map<String, String> headers(dynamic raw) =>
        raw is Map ? {for (final entry in raw.entries) entry.key.toString(): entry.value.toString()} : const {};
    return ResolvedYoutubeVideo(
      videoUri: uri(json['videoUrl']),
      audioUri: uri(json['audioUrl']),
      videoHeaders: headers(json['videoHeaders']),
      audioHeaders: headers(json['audioHeaders']),
    );
  }

  /// yt-dlp's requested formats are authoritative; preserve each URL's headers.
  static ResolvedYoutubeVideo fromExtraction(Map<String, dynamic> info) {
    final candidates = (info['requested_formats'] is List ? info['requested_formats'] as List : [info])
        .whereType<Map>();
    final video = candidates.where((f) => f['vcodec'] != null && f['vcodec'] != 'none').firstOrNull;
    final audio = candidates.where((f) => f['acodec'] != null && f['acodec'] != 'none').firstOrNull;
    if (video == null || audio == null) {
      throw const FormatException('This upload has no playable video and audio pair.');
    }
    return ResolvedYoutubeVideo.fromJson({
      'videoUrl': video['url'],
      'audioUrl': audio['url'],
      'videoHeaders': video['http_headers'] ?? info['http_headers'],
      'audioHeaders': audio['http_headers'] ?? info['http_headers'],
    });
  }
}
