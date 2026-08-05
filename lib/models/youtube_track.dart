class YoutubeTrack {
  final String title;
  final String artist;
  final String url;
  final int? durationSeconds;
  final String? thumbnailUrl;
  final int? viewCount;
  final int? likeCount;
  final bool isLive;
  final bool isShort;
  final String? availability;

  /// Compatibility alias for older transfer/search callers.
  String get uploader => artist;

  const YoutubeTrack({
    required this.title,
    required this.artist,
    required this.url,
    this.durationSeconds,
    this.thumbnailUrl,
    this.viewCount,
    this.likeCount,
    this.isLive = false,
    this.isShort = false,
    this.availability,
  });

  String? get videoId {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    final candidate = host.contains('youtu.be')
        ? uri.pathSegments.firstOrNull
        : uri.queryParameters['v'] ??
              (uri.pathSegments.length >= 2 && {'shorts', 'embed', 'live'}.contains(uri.pathSegments.first)
                  ? uri.pathSegments[1]
                  : null);
    return candidate != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(candidate) ? candidate : null;
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'url': url,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
    if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
    if (viewCount != null) 'viewCount': viewCount,
    if (likeCount != null) 'likeCount': likeCount,
    'isLive': isLive,
    'isShort': isShort,
    if (availability != null) 'availability': availability,
  };

  factory YoutubeTrack.fromCacheJson(Map<String, dynamic> json) => YoutubeTrack(
    title: json['title']?.toString() ?? 'Unknown',
    artist: json['artist']?.toString() ?? 'Unknown',
    url: json['url']?.toString() ?? '',
    durationSeconds: json['durationSeconds'] is num ? (json['durationSeconds'] as num).toInt() : null,
    thumbnailUrl: json['thumbnailUrl']?.toString(),
    viewCount: _readCount(json['viewCount']),
    likeCount: _readCount(json['likeCount']),
    isLive: json['isLive'] == true,
    isShort: json['isShort'] == true,
    availability: json['availability']?.toString(),
  );

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

  String get formattedViewCount => _compactCount(viewCount);

  String get formattedLikeCount => _compactCount(likeCount);

  YoutubeTrack copyWith({int? viewCount, int? likeCount}) => YoutubeTrack(
    title: title,
    artist: artist,
    url: url,
    durationSeconds: durationSeconds,
    thumbnailUrl: thumbnailUrl,
    viewCount: viewCount ?? this.viewCount,
    likeCount: likeCount ?? this.likeCount,
    isLive: isLive,
    isShort: isShort,
    availability: availability,
  );

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
      viewCount: _readCount(json['view_count']),
      likeCount: _readCount(json['like_count']),
      isLive: json['is_live'] == true || json['live_status'] == 'is_live' || json['live_status'] == 'was_live',
      isShort:
          json['is_short'] == true ||
          json['webpage_url']?.toString().contains('/shorts/') == true ||
          json['original_url']?.toString().contains('/shorts/') == true,
      availability: json['availability']?.toString(),
    );
  }

  static String? _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static int? _readCount(dynamic value) => value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  static String _compactCount(int? value) {
    if (value == null) return '—';
    if (value < 1000) return '$value';
    const suffixes = ['K', 'M', 'B', 'T'];
    var amount = value.toDouble();
    var suffix = -1;
    while (amount >= 1000 && suffix < suffixes.length - 1) {
      amount /= 1000;
      suffix++;
    }
    final digits = amount >= 100
        ? 0
        : amount >= 10
        ? 1
        : 2;
    return '${amount.toStringAsFixed(digits).replaceFirst(RegExp(r'\.0+$'), '')}${suffixes[suffix]}';
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
