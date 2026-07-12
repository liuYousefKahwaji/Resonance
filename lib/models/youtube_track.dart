class YoutubeTrack {
  final String title;
  final String artist;
  final String url;
  final int? durationSeconds;
  final String? thumbnailUrl;

  /// Compatibility alias for older transfer/search callers.
  String get uploader => artist;

  const YoutubeTrack({
    required this.title,
    required this.artist,
    required this.url,
    this.durationSeconds,
    this.thumbnailUrl,
  });

  String get formattedDuration {
    final duration = durationSeconds;
    if (duration == null || duration < 0) return '';
    final hours = duration ~/ 3600;
    final minutes = (duration % 3600) ~/ 60;
    final seconds = duration % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  factory YoutubeTrack.fromJson(Map<String, dynamic> json) {
    final thumbnails = json['thumbnails'];
    String? thumbnail = json['thumbnail']?.toString();
    if ((thumbnail == null || thumbnail.isEmpty) && thumbnails is List && thumbnails.isNotEmpty) {
      final last = thumbnails.last;
      if (last is Map) thumbnail = last['url']?.toString();
    }
    final rawUrl = json['webpage_url']?.toString() ?? json['url']?.toString() ?? '';
    final rawDuration = json['duration_seconds'] ?? json['duration'];
    return YoutubeTrack(
      title: json['title']?.toString().trim().isNotEmpty == true ? json['title'].toString() : 'Unknown',
      artist: _firstNonEmpty([json['uploader'], json['channel'], json['artist'], json['uploader_id']]) ?? 'Unknown',
      url: _canonicalYoutubeUrl(rawUrl, json['id']?.toString()),
      durationSeconds: rawDuration is num ? rawDuration.toInt() : int.tryParse(rawDuration?.toString() ?? ''),
      thumbnailUrl: thumbnail?.trim().isNotEmpty == true ? thumbnail : null,
    );
  }

  static String? _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static String _canonicalYoutubeUrl(String value, String? id) {
    if (value.startsWith('http://') || value.startsWith('https://')) return value;
    final candidate = (id?.isNotEmpty == true ? id : value).toString();
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(candidate)) {
      return 'https://www.youtube.com/watch?v=$candidate';
    }
    return value;
  }
}
