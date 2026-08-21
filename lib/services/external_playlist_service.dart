import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';
import 'package:resonance/models/external_playlist.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';

typedef ExternalPlaylistTextFetcher = Future<String> Function(Uri uri);
typedef YoutubePlaylistJsonFetcher = Future<String> Function(Uri uri);

class ExternalPlaylistException implements Exception {
  final String message;

  const ExternalPlaylistException(this.message);

  @override
  String toString() => message;
}

abstract interface class ExternalPlaylistProvider {
  ExternalPlaylistKind get kind;

  bool supports(Uri uri);

  Future<ExternalPlaylist> fetch(Uri uri);
}

class ExternalPlaylistService {
  static const fetchTimeout = Duration(seconds: 75);
  final List<ExternalPlaylistProvider> providers;

  ExternalPlaylistService({List<ExternalPlaylistProvider>? providers})
    : providers = providers ?? [YoutubePlaylistProvider(), SpotifyPlaylistProvider(), AudiomackPlaylistProvider()];

  Future<ExternalPlaylist> fetch(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const ExternalPlaylistException('Paste a YouTube, YouTube Music, Spotify, or Audiomack playlist link.');
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) throw const ExternalPlaylistException('The playlist link is not valid.');
    for (final provider in providers) {
      if (!provider.supports(uri)) continue;
      try {
        return await provider.fetch(uri).timeout(fetchTimeout);
      } on TimeoutException {
        throw ExternalPlaylistException('${provider.kind.label} took too long to read this playlist.');
      }
    }
    throw const ExternalPlaylistException(
      'Unsupported playlist link. Use a YouTube, YouTube Music, Spotify, or Audiomack playlist URL.',
    );
  }
}

class ExternalTrackMetadata {
  final String title;
  final String artist;

  const ExternalTrackMetadata({required this.title, required this.artist});

  String get searchQuery => artist.isEmpty ? title : '$artist $title';
}

/// Reads the public metadata already embedded in Spotify and Audiomack track
/// pages. This is deliberately metadata-only; playback still goes through the
/// existing YouTube search flow.
class ExternalTrackMetadataService {
  final ExternalPlaylistTextFetcher _fetchText;

  ExternalTrackMetadataService({ExternalPlaylistTextFetcher? fetchText}) : _fetchText = fetchText ?? _fetchExternalText;

  bool supports(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    return host == 'open.spotify.com' || host == 'audiomack.com' || host.endsWith('.audiomack.com');
  }

  Future<ExternalTrackMetadata> fetch(Uri uri) async {
    if (!supports(uri)) throw const ExternalPlaylistException('This shared track provider is not supported.');
    return parseHtml(await _fetchText(uri), sourceUri: uri);
  }

  static ExternalTrackMetadata parseHtml(String html, {required Uri sourceUri}) {
    final structured = _structuredTrackMetadata(html);
    if (structured != null) return structured;

    final meta = _htmlMetadata(html);
    var title = _cleanSharedMetadata(meta['og:title'] ?? meta['twitter:title']);
    var artist = _cleanSharedMetadata(meta['music:musician'] ?? meta['music:artist']);
    final description = _cleanSharedMetadata(meta['og:description'] ?? meta['twitter:description']);
    final host = sourceUri.host.toLowerCase();

    if (host.contains('audiomack')) {
      final match = RegExp(
        r'^(.+?)\s+by\s+(.+?)(?::\s*listen\s+on\s+audiomack|\s*\|\s*audiomack|$)',
        caseSensitive: false,
      ).firstMatch(title);
      if (match != null) {
        title = match.group(1)!.trim();
        artist = match.group(2)!.trim();
      } else {
        title = title
            .replaceFirst(RegExp(r':\s*listen\s+on\s+audiomack.*$', caseSensitive: false), '')
            .replaceFirst(RegExp(r'\s*\|\s*audiomack.*$', caseSensitive: false), '')
            .trim();
      }
    } else if (host.contains('spotify')) {
      final match = RegExp(
        r'^(.+?)\s+-\s+(?:song(?:\s+and\s+lyrics)?|single)\s+by\s+(.+?)(?:\s*\|\s*spotify)?$',
        caseSensitive: false,
      ).firstMatch(title);
      if (match != null) {
        title = match.group(1)!.trim();
        artist = match.group(2)!.trim();
      } else {
        title = title.replaceFirst(RegExp(r'\s*\|\s*spotify.*$', caseSensitive: false), '').trim();
      }
    }

    if (artist.startsWith('http://') || artist.startsWith('https://')) artist = '';
    if (artist.isEmpty && description.isNotEmpty) {
      final byMatch = RegExp(
        r'(?:listen\s+to\s+.+?\s+|song\s+|single\s+)?by\s+([^.|]+?)(?:\s+on\s+|[.|]|$)',
        caseSensitive: false,
      ).firstMatch(description);
      if (byMatch != null) artist = byMatch.group(1)!.trim();
    }
    if (title.isEmpty) {
      throw const ExternalPlaylistException('The shared track did not expose readable title metadata.');
    }
    return ExternalTrackMetadata(title: title, artist: artist);
  }
}

ExternalTrackMetadata? _structuredTrackMetadata(String html) {
  final scripts = RegExp(r'<script\b([^>]*)>(.*?)</script>', caseSensitive: false, dotAll: true).allMatches(html);
  for (final script in scripts) {
    if (!script.group(1)!.toLowerCase().contains('application/ld+json')) continue;
    try {
      final found = _findStructuredTrack(jsonDecode(script.group(2)!));
      if (found != null) return found;
    } catch (_) {
      // Pages often include unrelated or partially escaped structured data.
    }
  }
  return null;
}

ExternalTrackMetadata? _findStructuredTrack(dynamic node) {
  if (node is List) {
    for (final item in node) {
      final found = _findStructuredTrack(item);
      if (found != null) return found;
    }
    return null;
  }
  if (node is! Map) return null;
  final map = Map<String, dynamic>.from(node);
  final type = map['@type'];
  final types = type is List ? type.map((value) => value.toString()) : <String>[type?.toString() ?? ''];
  if (types.any((value) => value.toLowerCase() == 'musicrecording')) {
    final title = _cleanText(map['name'] ?? map['headline']);
    final artist = _structuredArtist(map['byArtist'] ?? map['author']);
    if (title.isNotEmpty) return ExternalTrackMetadata(title: title, artist: artist);
  }
  for (final value in map.values) {
    final found = _findStructuredTrack(value);
    if (found != null) return found;
  }
  return null;
}

String _structuredArtist(dynamic value) {
  if (value is List) {
    return value.map(_structuredArtist).where((artist) => artist.isNotEmpty).join(', ');
  }
  if (value is Map) return _cleanText(value['name']);
  return _cleanText(value);
}

Map<String, String> _htmlMetadata(String html) {
  final result = <String, String>{};
  for (final match in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(html)) {
    final tag = match.group(0)!;
    final name = _htmlAttribute(tag, 'property') ?? _htmlAttribute(tag, 'name');
    final content = _htmlAttribute(tag, 'content');
    if (name != null && content != null) result[name.toLowerCase()] = content;
  }
  return result;
}

String? _htmlAttribute(String tag, String name) {
  final doubleQuoted = RegExp('$name\\s*=\\s*"([^"]*)"', caseSensitive: false).firstMatch(tag)?.group(1);
  if (doubleQuoted != null) return doubleQuoted;
  return RegExp("$name\\s*=\\s*'([^']*)'", caseSensitive: false).firstMatch(tag)?.group(1);
}

String _cleanSharedMetadata(String? value) => (value ?? '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

class YoutubePlaylistProvider implements ExternalPlaylistProvider {
  static const maximumPlaylistEntries = 1000;
  final YoutubePlaylistJsonFetcher _fetchJson;

  YoutubePlaylistProvider({YoutubePlaylistJsonFetcher? fetchJson})
    : _fetchJson = fetchJson ?? _fetchYoutubePlaylistJson;

  @override
  ExternalPlaylistKind get kind => ExternalPlaylistKind.youtube;

  @override
  bool supports(Uri uri) => isPlaylistUri(uri);

  static bool isPlaylistUri(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final isYoutube =
        host == 'youtube.com' || host == 'music.youtube.com' || host == 'm.youtube.com' || host == 'youtu.be';
    if (!isYoutube) return false;
    final playlistId = uri.queryParameters['list']?.trim() ?? '';
    return playlistId.isNotEmpty;
  }

  @override
  Future<ExternalPlaylist> fetch(Uri uri) async {
    final json = await _fetchJson(uri);
    return parseJson(json, sourceUri: uri);
  }

  static ExternalPlaylist parseJson(String json, {required Uri sourceUri}) {
    try {
      final root = _asMap(jsonDecode(json));
      final name = _cleanText(root['title'] ?? root['playlist_title']);
      final rawEntries = root['entries'];
      if (rawEntries is! List) throw const FormatException();

      final tracks = <ExternalPlaylistTrack>[];
      for (final raw in rawEntries.take(maximumPlaylistEntries)) {
        final entry = _asMap(raw);
        final title = _cleanText(entry['title']);
        final videoId = _youtubeVideoId(entry);
        if (title.isEmpty || videoId == null) continue;
        final artist = _cleanText(entry['artist'] ?? entry['uploader'] ?? entry['channel']);
        final durationSeconds = _asInt(entry['duration_seconds'] ?? entry['duration']);
        tracks.add(
          ExternalPlaylistTrack(
            title: title,
            artists: artist.isEmpty ? const [] : [artist],
            duration: durationSeconds == null || durationSeconds < 0 ? null : Duration(seconds: durationSeconds),
            sourceId: videoId,
          ),
        );
      }
      if (tracks.isEmpty) throw const ExternalPlaylistException('This YouTube playlist has no readable public videos.');
      return ExternalPlaylist(
        kind: ExternalPlaylistKind.youtube,
        name: name.isEmpty ? 'YouTube Playlist' : name,
        sourceUri: sourceUri,
        tracks: List.unmodifiable(tracks),
      );
    } on ExternalPlaylistException {
      rethrow;
    } catch (_) {
      throw const ExternalPlaylistException('YouTube returned playlist metadata in an unsupported format.');
    }
  }

  static String? _youtubeVideoId(Map<String, dynamic> entry) {
    final directId = _cleanText(entry['id']);
    if (TrackSourceRepository.isValidYoutubeVideoId(directId)) return directId;
    return TrackSourceRepository.videoIdFromUrlOrId(_cleanText(entry['webpage_url'] ?? entry['url']));
  }
}

class SpotifyPlaylistProvider implements ExternalPlaylistProvider {
  static final RegExp _playlistIdPattern = RegExp(r'(?:playlist/|spotify:playlist:)([A-Za-z0-9]{22})');
  final ExternalPlaylistTextFetcher _fetchText;

  SpotifyPlaylistProvider({ExternalPlaylistTextFetcher? fetchText}) : _fetchText = fetchText ?? _fetchExternalText;

  @override
  ExternalPlaylistKind get kind => ExternalPlaylistKind.spotify;

  @override
  bool supports(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    return (host == 'open.spotify.com' || uri.scheme.toLowerCase() == 'spotify') &&
        _playlistIdPattern.hasMatch(uri.toString());
  }

  @override
  Future<ExternalPlaylist> fetch(Uri uri) async {
    final id = _playlistIdPattern.firstMatch(uri.toString())?.group(1);
    if (id == null) throw const ExternalPlaylistException('The Spotify playlist ID could not be read.');
    final embedUri = Uri.https('open.spotify.com', '/embed/playlist/$id');
    final html = await _fetchText(embedUri);
    return parseHtml(html, sourceUri: uri);
  }

  static ExternalPlaylist parseHtml(String html, {required Uri sourceUri}) {
    final match = RegExp(
      r'''<script[^>]*id=["']__NEXT_DATA__["'][^>]*>(.*?)</script>''',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (match == null) {
      throw const ExternalPlaylistException('Spotify did not return readable playlist metadata.');
    }

    try {
      final root = jsonDecode(match.group(1)!);
      final pageProps = _asMap(_asMap(root)['props'])['pageProps'];
      final state = _asMap(_asMap(pageProps)['state']);
      final entity = _asMap(_asMap(state['data'])['entity']);
      final name = _cleanText(entity['name'] ?? entity['title']);
      final rawTracks = entity['trackList'];
      if (name.isEmpty || rawTracks is! List) throw const FormatException();

      final tracks = <ExternalPlaylistTrack>[];
      for (final raw in rawTracks) {
        final track = _asMap(raw);
        final title = _cleanText(track['title']);
        if (title.isEmpty || track['entityType']?.toString() == 'episode') continue;
        final durationMs = _asInt(track['duration']);
        tracks.add(
          ExternalPlaylistTrack(
            title: title,
            artists: _splitArtists(track['subtitle']),
            duration: durationMs == null || durationMs < 0 ? null : Duration(milliseconds: durationMs),
            sourceId: _cleanText(track['uri']).isEmpty ? null : _cleanText(track['uri']),
          ),
        );
      }
      if (tracks.isEmpty) throw const ExternalPlaylistException('This Spotify playlist has no readable tracks.');
      return ExternalPlaylist(
        kind: ExternalPlaylistKind.spotify,
        name: name,
        sourceUri: sourceUri,
        tracks: List.unmodifiable(tracks),
      );
    } on ExternalPlaylistException {
      rethrow;
    } catch (_) {
      throw const ExternalPlaylistException('Spotify returned playlist metadata in an unsupported format.');
    }
  }
}

class AudiomackPlaylistProvider implements ExternalPlaylistProvider {
  final ExternalPlaylistTextFetcher _fetchText;

  AudiomackPlaylistProvider({ExternalPlaylistTextFetcher? fetchText}) : _fetchText = fetchText ?? _fetchExternalText;

  @override
  ExternalPlaylistKind get kind => ExternalPlaylistKind.audiomack;

  @override
  bool supports(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    return (host == 'audiomack.com' || host.endsWith('.audiomack.com')) && uri.pathSegments.contains('playlist');
  }

  @override
  Future<ExternalPlaylist> fetch(Uri uri) async {
    final html = await _fetchText(uri);
    return parseHtml(html, sourceUri: uri);
  }

  static ExternalPlaylist parseHtml(String html, {required Uri sourceUri}) {
    final pushes = RegExp(r'self\.__next_f\.push\(\[1,("(?:\\.|[^"\\])*")\]\)', dotAll: true).allMatches(html);

    Map<String, dynamic>? playlist;
    for (final push in pushes) {
      try {
        final decodedChunk = jsonDecode(push.group(1)!) as String;
        final separator = decodedChunk.indexOf(':');
        if (separator < 0 || separator == decodedChunk.length - 1) continue;
        final payload = jsonDecode(decodedChunk.substring(separator + 1));
        playlist = _findAudiomackPlaylist(payload);
        if (playlist != null) break;
      } catch (_) {
        // RSC contains module references and other non-JSON frames. Only data
        // frames are relevant to playlist metadata.
      }
    }
    if (playlist == null) {
      throw const ExternalPlaylistException('Audiomack did not return readable playlist metadata.');
    }

    final name = _cleanText(playlist['title']);
    final rawTracks = playlist['tracks'];
    if (name.isEmpty || rawTracks is! List) {
      throw const ExternalPlaylistException('Audiomack returned playlist metadata in an unsupported format.');
    }

    final tracks = <ExternalPlaylistTrack>[];
    for (final raw in rawTracks) {
      final track = _asMap(raw);
      final title = _cleanText(track['title']);
      if (title.isEmpty || (track['type'] != null && track['type'].toString() != 'song')) continue;
      final artists = <String>[
        if (_cleanText(track['artist']).isNotEmpty) _cleanText(track['artist']),
        if (_cleanText(track['featuring']).isNotEmpty) _cleanText(track['featuring']),
      ];
      final durationSeconds = _asInt(track['duration']);
      tracks.add(
        ExternalPlaylistTrack(
          title: title,
          artists: _deduplicateArtists(artists),
          duration: durationSeconds == null || durationSeconds < 0 ? null : Duration(seconds: durationSeconds),
          sourceId: _cleanText(track['id']).isEmpty ? null : _cleanText(track['id']),
        ),
      );
    }
    if (tracks.isEmpty) throw const ExternalPlaylistException('This Audiomack playlist has no readable tracks.');
    return ExternalPlaylist(
      kind: ExternalPlaylistKind.audiomack,
      name: name,
      sourceUri: sourceUri,
      tracks: List.unmodifiable(tracks),
    );
  }
}

Map<String, dynamic>? _findAudiomackPlaylist(dynamic node) {
  if (node is Map) {
    final map = Map<String, dynamic>.from(node);
    final tracks = map['tracks'];
    if (map['type']?.toString() == 'playlist' &&
        _cleanText(map['title']).isNotEmpty &&
        tracks is List &&
        tracks.any((track) => track is Map && _cleanText(track['title']).isNotEmpty)) {
      return map;
    }
    for (final value in map.values) {
      final found = _findAudiomackPlaylist(value);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final value in node) {
      final found = _findAudiomackPlaylist(value);
      if (found != null) return found;
    }
  }
  return null;
}

Future<String> _fetchExternalText(Uri uri) async {
  const maximumBytes = 8 * 1024 * 1024;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 20));
    request.followRedirects = true;
    request.maxRedirects = 5;
    request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Resonance playlist metadata importer)');
    request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');
    final response = await request.close().timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ExternalPlaylistException('The playlist provider returned HTTP ${response.statusCode}.');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.addAll(chunk);
      if (bytes.length > maximumBytes) {
        throw const ExternalPlaylistException('The playlist metadata response was unexpectedly large.');
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  } on ExternalPlaylistException {
    rethrow;
  } on TimeoutException {
    throw const ExternalPlaylistException('The playlist provider took too long to respond.');
  } on SocketException catch (error) {
    throw ExternalPlaylistException('Could not connect to the playlist provider: ${error.message}');
  } finally {
    client.close(force: true);
  }
}

Future<String> _fetchYoutubePlaylistJson(Uri uri) async {
  if (Platform.isAndroid) {
    const channel = MethodChannel('resonance/android_youtube');
    try {
      final result = await channel
          .invokeMethod<String>('getPlaylistMetadata', {'url': uri.toString()})
          .timeout(const Duration(seconds: 60));
      if (result == null || result.trim().isEmpty) {
        throw const ExternalPlaylistException('YouTube did not return readable playlist metadata.');
      }
      return result;
    } on TimeoutException {
      throw const ExternalPlaylistException('YouTube took too long to read this playlist.');
    } on PlatformException catch (error) {
      final failure = YoutubeFailureClassifier.classify(
        error,
        authenticated: YoutubeAccessService.active?.isConfigured ?? false,
        sourceUrl: uri.toString(),
      );
      YoutubeAccessService.active?.observeFailure(failure);
      throw failure;
    }
  }
  if (Platform.isWindows) return _fetchWindowsYoutubePlaylistJson(uri);
  throw const ExternalPlaylistException('YouTube playlist import is supported on Windows and Android.');
}

Future<String> _fetchWindowsYoutubePlaylistJson(Uri uri) async {
  try {
    final result = await WindowsYtdlpRunner.instance.run(
      [
        '--flat-playlist',
        '--dump-single-json',
        '--skip-download',
        '--yes-playlist',
        '--playlist-end',
        YoutubePlaylistProvider.maximumPlaylistEntries.toString(),
        '--no-warnings',
        uri.toString(),
      ],
      timeout: const Duration(seconds: 60),
      sourceUrl: uri.toString(),
      requireOutput: true,
    );
    return result.stdout;
  } on TimeoutException {
    throw const ExternalPlaylistException('YouTube took too long to read this playlist.');
  } on YoutubeFailure {
    rethrow;
  } catch (error) {
    throw ExternalPlaylistException(error.toString());
  }
}

Map<String, dynamic> _asMap(dynamic value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

int? _asInt(dynamic value) => value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

String _cleanText(dynamic value) =>
    value?.toString().replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';

List<String> _splitArtists(dynamic value) {
  final text = _cleanText(value);
  if (text.isEmpty) return const [];
  return _deduplicateArtists(text.split(RegExp(r'\s*(?:,|&| feat\.? | ft\.? )\s*', caseSensitive: false)));
}

List<String> _deduplicateArtists(Iterable<String> artists) {
  final seen = <String>{};
  final result = <String>[];
  for (final artist in artists) {
    final clean = _cleanText(artist);
    if (clean.isEmpty || !seen.add(clean.toLowerCase())) continue;
    result.add(clean);
  }
  return result;
}
