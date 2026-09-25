import 'dart:convert';
import 'dart:io';

import 'package:resonance/models/youtube_track.dart';

/// Fetches the small public title/author response independently of stream
/// extraction. A failed or non-embeddable link can still use yt-dlp later.
class YoutubeLinkMetadataService {
  static final Map<String, ({DateTime at, YoutubeTrack track})> _cache = {};
  static final Map<String, Future<YoutubeTrack?>> _pending = {};

  const YoutubeLinkMetadataService();

  Future<YoutubeTrack?> fetch(YoutubeTrack link) async {
    final videoId = link.videoId;
    if (videoId == null) return null;
    final cached = _cache[videoId];
    if (cached != null && DateTime.now().difference(cached.at) < const Duration(minutes: 30)) {
      return cached.track;
    }
    final future = _pending.putIfAbsent(videoId, () => _request(link));
    try {
      final track = await future;
      if (track != null) _cache[videoId] = (at: DateTime.now(), track: track);
      return track;
    } finally {
      if (identical(_pending[videoId], future)) _pending.remove(videoId);
    }
  }

  Future<YoutubeTrack?> _request(YoutubeTrack link) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final uri = Uri.https('www.youtube.com', '/oembed', {'url': link.url, 'format': 'json'});
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(const Duration(seconds: 3));
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 3));
      return parseResponse(body, link);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static YoutubeTrack? parseResponse(String body, YoutubeTrack link) {
    try {
      final data = jsonDecode(body);
      if (data is! Map) return null;
      final title = data['title']?.toString().trim() ?? '';
      final artist = data['author_name']?.toString().trim() ?? '';
      if (title.isEmpty || artist.isEmpty) return null;
      return YoutubeTrack(title: title, artist: artist, url: link.url, thumbnailUrl: link.thumbnailUrl);
    } catch (_) {
      return null;
    }
  }
}
