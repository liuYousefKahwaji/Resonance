import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:resonance/models/youtube_artist.dart';
import 'package:resonance/models/youtube_track.dart';

typedef ArtistHttpLoader = Future<String> Function(Uri uri, Map<String, dynamic>? body);

/// Reads a public channel's selected Videos tab and its actual sort endpoints.
/// No browser cookies, playback extraction or name-based search is involved.
class YoutubeArtistService {
  YoutubeArtistService({ArtistHttpLoader? loader}) : _loader = loader;
  final ArtistHttpLoader? _loader;
  final Set<HttpClient> _clients = {};
  bool _cancelled = false;
  static final _cache = <String, ({DateTime stored, _ArtistFeed feed})>{};
  static final _resolved = <String, String>{};
  static final _pages = <String, ({DateTime stored, YoutubeArtistPage page})>{};
  static final _catalogues = <String, List<YoutubeTrack>>{};
  static final _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');
  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  static void clearCache() {
    _cache.clear();
    _resolved.clear();
    _pages.clear();
    _catalogues.clear();
  }

  void cancel() {
    _cancelled = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }

  Future<String> _request(Uri uri, [Map<String, dynamic>? body]) async {
    if (_cancelled) throw const YoutubeArtistException('Artist request cancelled.');
    if (_loader != null) return _loader(uri, body);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    _clients.add(client);
    try {
      return await (() async {
        final request = await client.openUrl(body == null ? 'GET' : 'POST', uri);
        request.followRedirects = true;
        request.maxRedirects = 3;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/132.0.0.0 Safari/537.36',
        );
        request.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.headers.set('Origin', 'https://www.youtube.com');
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) throw const YoutubeArtistException('Could not load this artist.');
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 8 * 1024 * 1024) throw const YoutubeArtistException('Could not read this artist page.');
        }
        return utf8.decode(bytes);
      })().timeout(const Duration(seconds: 25));
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<YoutubeArtistPage> fetch(
    YoutubeTrack seed,
    YoutubeArtistSort sort, {
    YoutubeArtistCursor? cursor,
    YoutubeArtistProfile? artist,
    Set<YoutubeArtistSort>? availableSorts,
  }) async {
    if (_cancelled) throw const YoutubeArtistException('Artist request cancelled.');
    if (cursor != null && artist != null) {
      if (cursor.remaining case final remaining?) {
        return _localPage(remaining, artist, availableSorts ?? {sort});
      }
      final raw = await _request(Uri.https('www.youtube.com', '/youtubei/v1/browse'), {
        'context': cursor.context,
        'continuation': cursor.token,
      });
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (_cancelled) throw const YoutubeArtistException('Artist request cancelled.');
      final page = decodePage(data, artist, cursor.context, availableSorts: availableSorts ?? {sort});
      if (page.next?.token == cursor.token) {
        throw const YoutubeArtistException('Could not load more songs.');
      }
      return page;
    }
    final id = seed.artistId;
    final reference = id != null && _channelId.hasMatch(id) ? '/channel/$id' : await _resolve(seed);
    final pageKey = '$reference:${sort.name}';
    final pageCache = _pages[pageKey];
    if (pageCache != null && DateTime.now().difference(pageCache.stored) < const Duration(minutes: 5)) {
      return pageCache.page;
    }
    var feed = _cache[reference];
    if (feed == null || DateTime.now().difference(feed.stored) >= const Duration(minutes: 5)) {
      final html = await _request(Uri.https('www.youtube.com', '$reference/videos', {'hl': 'en'}));
      final initial = jsonAfter(html, RegExp(r'(?:var\s+)?ytInitialData\s*=\s*|window\["ytInitialData"\]\s*=\s*'));
      var context = _contextFromHtml(html);
      if (context['client'] is! Map) throw const YoutubeArtistException('Could not read this artist page.');
      final metadata = initial['metadata']?['channelMetadataRenderer'] as Map?;
      final channel = metadata?['externalId']?.toString();
      if (channel == null || !_channelId.hasMatch(channel)) {
        throw const YoutubeArtistException('Could not find this artist.');
      }
      final profile = YoutubeArtistProfile(
        id: channel,
        name: (metadata?['title']?.toString() ?? seed.artist).replaceFirst(RegExp(r' - Topic$'), ''),
        description: metadata?['description']?.toString() ?? '',
        avatarUrl: _image(metadata?['avatar']),
        bannerUrl: _banner(initial['header']),
      );
      Map<String, dynamic> content;
      var uploads = false;
      try {
        content = _selectedContent(initial);
      } on YoutubeArtistException {
        if (metadata?['title']?.toString().endsWith(' - Topic') != true) rethrow;
        // Auto-generated music channels expose their own uploads playlist
        // instead of Videos. Do not mix in Home recommendations or radio.
        final uploadsHtml = await _request(
          Uri.https('www.youtube.com', '/playlist', {'list': 'UU${profile.id.substring(2)}', 'hl': 'en'}),
        );
        final uploadsData = jsonAfter(
          uploadsHtml,
          RegExp(r'(?:var\s+)?ytInitialData\s*=\s*|window\["ytInitialData"\]\s*=\s*'),
        );
        content = _selectedContent(uploadsData, videosOnly: false);
        context = _contextFromHtml(uploadsHtml);
        uploads = true;
      }
      final sorts = _sortTokens(content);
      feed = (stored: DateTime.now(), feed: _ArtistFeed(profile, context, content, sorts, uploads));
      if (_cancelled) throw const YoutubeArtistException('Artist request cancelled.');
      _cache[reference] = feed;
      _catalogues.remove(reference);
      if (_cache.length > 24) {
        final removed = _cache.keys.first;
        _cache.remove(removed);
        _catalogues.remove(removed);
      }
    }
    final source = feed.feed;
    final sorts = source.uploads ? YoutubeArtistSort.values.toSet() : {YoutubeArtistSort.newest, ...source.sorts.keys};
    Map<String, dynamic> content = source.content;
    if (source.uploads && sort != YoutubeArtistSort.newest) {
      var catalogue = _catalogues[reference];
      if (catalogue == null) {
        final first = decodePage(content, source.artist, source.context, availableSorts: sorts);
        catalogue = first.tracks.toList();
        final seen = catalogue.map((track) => track.videoId).toSet();
        final tokens = <String>{};
        var next = first.next;
        while (next != null) {
          if (!tokens.add(next.token)) throw const YoutubeArtistException('Could not finish sorting this artist.');
          final page = await fetch(
            seed,
            YoutubeArtistSort.newest,
            cursor: next,
            artist: source.artist,
            availableSorts: sorts,
          );
          catalogue.addAll(page.tracks.where((track) => seen.add(track.videoId)));
          next = page.next;
        }
        if (_cancelled) throw const YoutubeArtistException('Artist request cancelled.');
        _catalogues[reference] = List.unmodifiable(catalogue);
      }
      final ranked = sort == YoutubeArtistSort.oldest ? catalogue.reversed.toList() : catalogue.toList();
      if (sort == YoutubeArtistSort.popular) {
        final order = {for (var i = 0; i < ranked.length; i++) ranked[i].url: i};
        ranked.sort((a, b) {
          final count = (b.viewCount ?? -1).compareTo(a.viewCount ?? -1);
          return count != 0 ? count : order[a.url]!.compareTo(order[b.url]!);
        });
      }
      final page = _localPage(ranked, source.artist, sorts);
      _pages[pageKey] = (stored: DateTime.now(), page: page);
      return page;
    }
    if (sort != YoutubeArtistSort.newest) {
      final token = source.sorts[sort];
      if (token == null) throw const YoutubeArtistException('This artist does not offer that sort.');
      content =
          jsonDecode(
                await _request(Uri.https('www.youtube.com', '/youtubei/v1/browse'), {
                  'context': source.context,
                  'continuation': token,
                }),
              )
              as Map<String, dynamic>;
    }
    final page = decodePage(content, source.artist, source.context, availableSorts: sorts);
    if (_cancelled) throw const YoutubeArtistException('Artist request cancelled.');
    _pages[pageKey] = (stored: DateTime.now(), page: page);
    if (_pages.length > 72) _pages.remove(_pages.keys.first);
    return page;
  }

  Future<String> _resolve(YoutubeTrack seed) async {
    final video = seed.videoId;
    if (video == null) throw const YoutubeArtistException('Could not find this artist.');
    if (_resolved[video] case final cached?) return cached;
    final raw = await _request(
      Uri.https('www.youtube.com', '/oembed', {'url': 'https://www.youtube.com/watch?v=$video', 'format': 'json'}),
    );
    final data = jsonDecode(raw) as Map;
    final url = Uri.tryParse(data['author_url']?.toString() ?? '');
    if (url == null || !{'www.youtube.com', 'youtube.com'}.contains(url.host)) {
      throw const YoutubeArtistException('Could not find this artist.');
    }
    final parts = url.pathSegments;
    final valid =
        parts.length == 1 && RegExp(r'^@[A-Za-z0-9_.\-\p{L}\p{N}]+$', unicode: true).hasMatch(parts.first) ||
        parts.length == 2 && parts.first == 'channel' && _channelId.hasMatch(parts.last);
    if (!valid) throw const YoutubeArtistException('Could not find this artist.');
    _resolved[video] = url.path;
    if (_resolved.length > 256) _resolved.remove(_resolved.keys.first);
    return url.path;
  }

  static Map<String, dynamic> jsonAfter(String html, RegExp pattern) {
    final match = pattern.firstMatch(html);
    if (match == null) throw const YoutubeArtistException('Could not read this artist page.');
    return jsonAt(html, match.end);
  }

  static Map<String, dynamic> _contextFromHtml(String html) {
    final config = <String, dynamic>{};
    for (final match in RegExp(r'ytcfg\.set\(\s*(?=\{)').allMatches(html)) {
      try {
        config.addAll(jsonAt(html, match.end));
      } on FormatException {
        // Auxiliary calls can contain JS rather than JSON. Never execute it.
      }
    }
    final context = Map<String, dynamic>.from(config['INNERTUBE_CONTEXT'] as Map? ?? {});
    if (context['client'] is! Map) throw const YoutubeArtistException('Could not read this artist page.');
    return context;
  }

  static YoutubeArtistPage _localPage(
    List<YoutubeTrack> tracks,
    YoutubeArtistProfile artist,
    Set<YoutubeArtistSort> sorts,
  ) => YoutubeArtistPage(
    artist: artist,
    tracks: tracks.take(30).toList(),
    availableSorts: sorts,
    next: tracks.length <= 30 ? null : YoutubeArtistCursor.local(tracks.skip(30).toList()),
  );

  static Map<String, dynamic> jsonAt(String text, int offset) {
    final start = text.indexOf('{', offset);
    var depth = 0, quoted = false, escaped = false;
    for (var i = start; i >= 0 && i < text.length; i++) {
      final char = text[i];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          quoted = false;
        }
      } else if (char == '"') {
        quoted = true;
      } else if (char == '{') {
        depth++;
      } else if (char == '}' && --depth == 0) {
        return Map<String, dynamic>.from(jsonDecode(text.substring(start, i + 1)) as Map);
      }
    }
    throw const YoutubeArtistException('Could not read this artist page.');
  }

  static Iterable<Map> _walk(dynamic data) sync* {
    if (data is Map) {
      yield data;
      for (final value in data.values) {
        yield* _walk(value);
      }
    }
    if (data is List) {
      for (final value in data) {
        yield* _walk(value);
      }
    }
  }

  static Map<String, dynamic> _selectedContent(Map data, {bool videosOnly = true}) {
    for (final node in _walk(data['contents'])) {
      final tab = node['tabRenderer'];
      if (tab is Map &&
          tab['selected'] == true &&
          tab['content'] is Map &&
          (!videosOnly ||
              tab['title'] == 'Videos' ||
              tab['endpoint']?['commandMetadata']?['webCommandMetadata']?['url']?.toString().endsWith('/videos') ==
                  true)) {
        return Map<String, dynamic>.from(tab['content']);
      }
    }
    throw const YoutubeArtistException('This artist has no public songs.');
  }

  static Map<YoutubeArtistSort, String> _sortTokens(dynamic data) {
    final result = <YoutubeArtistSort, String>{};
    for (final node in _walk(data)) {
      final chip = node['chipViewModel'] ?? node['chipCloudChipRenderer'];
      if (chip is! Map) continue;
      final label = _text(chip['text']).toLowerCase();
      final sort = switch (label) {
        'latest' || 'newest' => YoutubeArtistSort.newest,
        'oldest' => YoutubeArtistSort.oldest,
        'popular' => YoutubeArtistSort.popular,
        _ => null,
      };
      if (sort == null) continue;
      final endpoint = chip['tapCommand']?['innertubeCommand'] ?? chip['navigationEndpoint'];
      final token = endpoint?['continuationCommand']?['token'];
      if (token is String && token.isNotEmpty) result[sort] = token;
    }
    return result;
  }

  static String _text(dynamic value) {
    if (value is String) return value;
    if (value is Map) {
      if (value['content'] is String) return value['content'];
      if (value['simpleText'] is String) return value['simpleText'];
      if (value['runs'] is List) return (value['runs'] as List).map((run) => run['text'] ?? '').join();
    }
    return '';
  }

  static String? _image(dynamic data) {
    for (final node in _walk(data)) {
      final images = node['thumbnails'] ?? node['sources'];
      if (images is List) {
        for (final image in images.reversed) {
          final url = image is Map ? image['url'] : null;
          if (url is String && url.startsWith('https://')) return url;
        }
      }
    }
    return null;
  }

  static String? _banner(dynamic header) {
    for (final node in _walk(header)) {
      if (node['banner'] != null) return _image(node['banner']);
    }
    return null;
  }

  static int? _count(String label) {
    final match = RegExp(r'([\d,.]+)\s*(thousand|million|billion|[KMB])?', caseSensitive: false).firstMatch(label);
    final number = double.tryParse((match?[1] ?? '').replaceAll(',', ''));
    if (number == null) return null;
    final scale = switch (match?[2]?.toLowerCase()) {
      'k' || 'thousand' => 1000,
      'm' || 'million' => 1000000,
      'b' || 'billion' => 1000000000,
      _ => 1,
    };
    return (number * scale).round();
  }

  static int? _duration(String label) {
    if (!RegExp(r'^\d+(?::\d{2}){1,2}$').hasMatch(label)) return null;
    return label.split(':').fold<int>(0, (total, part) => total * 60 + int.parse(part));
  }

  static YoutubeArtistPage decodePage(
    Map<String, dynamic> data,
    YoutubeArtistProfile artist,
    Map<String, dynamic> context, {
    Set<YoutubeArtistSort> availableSorts = const {YoutubeArtistSort.newest},
  }) {
    final tracks = <YoutubeTrack>[];
    final seen = <String>{};
    String? continuation;
    // Browse responses can contain sidebars and menus. Only channel content or
    // appended/reloaded grid items may supply songs and pagination tokens.
    final roots = data['onResponseReceivedActions'] ?? data['onResponseReceivedEndpoints'] ?? data;
    for (final node in _walk(roots)) {
      final next = node['continuationItemRenderer']?['continuationEndpoint']?['continuationCommand']?['token'];
      if (next is String) continuation = next;
      final legacy = node['videoRenderer'] ?? node['gridVideoRenderer'];
      final modern = node['lockupViewModel'];
      String? id, title, thumb;
      int? views, duration;
      if (legacy is Map) {
        id = legacy['videoId']?.toString();
        title = _text(legacy['title']);
        thumb = _image(legacy['thumbnail']);
        views = _count(_text(legacy['viewCountText'] ?? legacy['shortViewCountText']));
        duration = _duration(_text(legacy['lengthText']));
      } else if (modern is Map && modern['contentType'] == 'LOCKUP_CONTENT_TYPE_VIDEO') {
        id = modern['contentId']?.toString();
        final metadata = modern['metadata']?['lockupMetadataViewModel'];
        title = _text(metadata?['title']);
        thumb = _image(modern['contentImage']);
        for (final part in _walk(metadata?['metadata'])) {
          final accessibility = part['accessibilityLabel']?.toString() ?? '';
          final label = _text(part['text']);
          if (accessibility.contains('view') || part['leadingIcon']?['name'] == 'PLAY_ARROW_OUTLINED') {
            views ??= _count(accessibility.isNotEmpty ? accessibility : label);
          }
        }
        for (final badge in _walk(modern['contentImage'])) {
          final text = badge['thumbnailBadgeViewModel']?['text'];
          if (text is String) duration ??= _duration(text);
        }
      }
      if (id == null || !_videoId.hasMatch(id) || title == null || title.isEmpty || !seen.add(id)) continue;
      tracks.add(
        YoutubeTrack(
          title: title,
          artist: artist.name,
          artistId: artist.id,
          url: 'https://www.youtube.com/watch?v=$id',
          thumbnailUrl: thumb ?? 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
          durationSeconds: duration,
          viewCount: views,
        ),
      );
    }
    return YoutubeArtistPage(
      artist: artist,
      tracks: tracks,
      availableSorts: availableSorts,
      next: continuation == null ? null : YoutubeArtistCursor(token: continuation, context: context),
    );
  }
}

class _ArtistFeed {
  const _ArtistFeed(this.artist, this.context, this.content, this.sorts, this.uploads);
  final YoutubeArtistProfile artist;
  final Map<String, dynamic> context;
  final Map<String, dynamic> content;
  final Map<YoutubeArtistSort, String> sorts;
  final bool uploads;
}
