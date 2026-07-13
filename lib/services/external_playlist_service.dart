import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:resonance/models/external_playlist.dart';

typedef ExternalPlaylistTextFetcher = Future<String> Function(Uri uri);

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
  final List<ExternalPlaylistProvider> providers;

  ExternalPlaylistService({List<ExternalPlaylistProvider>? providers})
    : providers = providers ?? [SpotifyPlaylistProvider(), AudiomackPlaylistProvider()];

  Future<ExternalPlaylist> fetch(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) throw const ExternalPlaylistException('Paste a Spotify or Audiomack playlist link.');
    final uri = Uri.tryParse(trimmed);
    if (uri == null) throw const ExternalPlaylistException('The playlist link is not valid.');
    for (final provider in providers) {
      if (provider.supports(uri)) return provider.fetch(uri);
    }
    throw const ExternalPlaylistException(
      'Unsupported playlist link. Use a Spotify playlist URL or an Audiomack /playlist/ URL.',
    );
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
