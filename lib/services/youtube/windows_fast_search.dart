import 'dart:convert';
import 'dart:io';

import 'package:resonance/models/youtube_track.dart';

/// Reads the public YouTube search page in one HTTP request. yt-dlp remains
/// the caller's fallback when YouTube changes the page or blocks the request.
class WindowsFastSearch {
  static final HttpClient _client = HttpClient()
    ..autoUncompress = true
    ..connectionTimeout = const Duration(seconds: 5);

  const WindowsFastSearch();

  Future<List<YoutubeTrack>> search(String query, {int limit = 10}) async {
    final uri = Uri.https('www.youtube.com', '/results', {'search_query': query});
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
    request.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    final response = await request.close().timeout(const Duration(seconds: 6));
    if (response.statusCode != HttpStatus.ok) return const [];
    final html = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 6));
    return parseHtml(html, limit: limit);
  }

  List<YoutubeTrack> parseHtml(String html, {int limit = 10}) {
    final resultLimit = limit.clamp(1, 120).toInt();
    const marker = 'var ytInitialData = ';
    final start = html.indexOf(marker);
    if (start < 0) return const [];
    final opening = html.indexOf('{', start + marker.length);
    if (opening < 0) return const [];
    var depth = 0;
    var inString = false;
    var escaped = false;
    var closing = -1;
    for (var i = opening; i < html.length; i++) {
      final char = html[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
      } else if (char == '"') {
        inString = true;
      } else if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) {
          closing = i + 1;
          break;
        }
      }
    }
    if (closing < 0) return const [];
    final data = jsonDecode(html.substring(opening, closing));
    final tracks = <YoutubeTrack>[];
    final seen = <String>{};

    void visit(dynamic node) {
      if (tracks.length >= resultLimit) return;
      if (node is List) {
        for (final child in node) {
          visit(child);
        }
      } else if (node is Map) {
        final renderer = node['videoRenderer'];
        if (renderer is Map) {
          final id = renderer['videoId']?.toString() ?? '';
          if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) && seen.add(id)) {
            String label(dynamic value) {
              if (value is! Map) return '';
              final simple = value['simpleText']?.toString();
              if (simple != null) return simple;
              final runs = value['runs'];
              return runs is List ? runs.whereType<Map>().map((run) => run['text']?.toString() ?? '').join() : '';
            }

            final title = label(renderer['title']);
            final artist = label(renderer['ownerText']);
            final thumbnails = (renderer['thumbnail'] as Map?)?['thumbnails'];
            final lastThumbnail = thumbnails is List && thumbnails.isNotEmpty ? thumbnails.last : null;
            final thumbnail = lastThumbnail is Map ? lastThumbnail['url']?.toString() : null;
            final duration = label(renderer['lengthText']);
            final parts = duration.split(':').map(int.tryParse).toList();
            int? seconds;
            if (parts.isNotEmpty && parts.length <= 3 && parts.every((part) => part != null)) {
              seconds = 0;
              for (final part in parts) {
                seconds = seconds! * 60 + part!;
              }
            }
            tracks.add(
              YoutubeTrack(
                title: title.isEmpty ? 'Unknown' : title,
                artist: artist.isEmpty ? 'Unknown' : artist,
                url: 'https://www.youtube.com/watch?v=$id',
                durationSeconds: seconds,
                thumbnailUrl: thumbnail,
              ),
            );
          }
        }
        for (final child in node.values) {
          visit(child);
        }
      }
    }

    visit(data);
    return tracks;
  }
}
