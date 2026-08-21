import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart' as p;
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef YoutubeSuggestionSearch = Future<List<YoutubeTrack>> Function(String query);

Future<List<YoutubeTrack>> _runSuggestionSearch(YoutubeSuggestionSearch search, String query, Duration timeout) async {
  try {
    return await search(query).timeout(timeout);
  } on YoutubeFailure catch (failure) {
    if (failure.isAccessFailure) rethrow;
    return const [];
  } catch (_) {
    return const [];
  }
}

@immutable
class PlaylistProfileTrack {
  final String path;
  final String title;
  final String artist;
  final String? album;
  final String? genre;
  final int? year;
  final int? durationSeconds;
  final String? videoId;
  final int appearances;
  final bool isCurrent;

  const PlaylistProfileTrack({
    required this.path,
    required this.title,
    required this.artist,
    this.album,
    this.genre,
    this.year,
    this.durationSeconds,
    this.videoId,
    this.appearances = 1,
    this.isCurrent = false,
  });

  String get songKey => '${normalizeRecommendationText(artist)}|${normalizeRecommendationText(title)}';
}

@immutable
class PlaylistProfile {
  final int playlistNumber;
  final String playlistName;
  final String fingerprint;
  final List<PlaylistProfileTrack> tracks;
  final Map<String, double> artistWeights;
  final Map<String, double> tokenWeights;
  final Set<String> variantTokens;
  final int? medianDurationSeconds;

  const PlaylistProfile({
    required this.playlistNumber,
    required this.playlistName,
    required this.fingerprint,
    required this.tracks,
    required this.artistWeights,
    required this.tokenWeights,
    required this.variantTokens,
    this.medianDurationSeconds,
  });

  bool get isEmpty => tracks.isEmpty;
}

@immutable
class RecommendationCandidate {
  final YoutubeTrack track;
  final String seedKey;
  final String query;
  final int queryRank;
  final double score;

  const RecommendationCandidate({
    required this.track,
    required this.seedKey,
    required this.query,
    required this.queryRank,
    this.score = 0,
  });

  RecommendationCandidate withScore(double value) =>
      RecommendationCandidate(track: track, seedKey: seedKey, query: query, queryRank: queryRank, score: value);
}

@immutable
class SuggestedMusicResult {
  final PlaylistProfile profile;
  final List<YoutubeTrack> tracks;
  final bool fromCache;

  const SuggestedMusicResult({required this.profile, required this.tracks, required this.fromCache});
}

String normalizeRecommendationText(String value) => value
    .toLowerCase()
    .replaceAll(
      RegExp(
        r'[\s\-_.,/\\|()\[\]{}:;!?+*&"'
        '`~]+',
        unicode: true,
      ),
      ' ',
    )
    .trim();

Set<String> recommendationTokens(String value) =>
    normalizeRecommendationText(value).split(' ').where((token) => token.length > 1).toSet();

class PlaylistProfileBuilder {
  final FileService fileService;
  final TrackSourceRepository sourceRepository;

  PlaylistProfileBuilder({FileService? fileService, TrackSourceRepository? sourceRepository})
    : fileService = fileService ?? FileService(),
      sourceRepository = sourceRepository ?? const TrackSourceRepository();

  Future<PlaylistProfile> build({
    required int playlistNumber,
    required String playlistName,
    String? currentTrackId,
  }) async {
    final content = await fileService.readTextFromPlaylist(playlistNumber);
    final entries = content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList(growable: false);
    final appearances = <String, int>{};
    final originalPath = <String, String>{};
    for (final entry in entries) {
      final key = _pathKey(entry);
      appearances[key] = (appearances[key] ?? 0) + 1;
      originalPath.putIfAbsent(key, () => entry);
    }

    final tracks = <PlaylistProfileTrack>[];
    final fingerprintParts = <String>['$playlistNumber', playlistName];
    for (final entry in originalPath.entries) {
      final path = entry.value;
      final count = appearances[entry.key] ?? 1;
      final stream = _isStream(path);
      String title;
      String artist;
      String? album;
      String? genre;
      int? year;
      int? duration;
      int modified = 0;
      if (stream) {
        final cached = await MetadataCacheService.get(path);
        title = cached?.title ?? 'Streaming Audio';
        artist = cached?.artist ?? 'YouTube';
      } else {
        title = p.basenameWithoutExtension(path);
        artist = 'Unknown Artist';
        try {
          final file = File(path);
          if (await file.exists()) {
            modified = (await file.lastModified()).millisecondsSinceEpoch;
            final metadata = await MetadataGod.readMetadata(file: path);
            title = metadata.title?.trim().isNotEmpty == true ? metadata.title!.trim() : title;
            artist = metadata.artist?.trim().isNotEmpty == true ? metadata.artist!.trim() : artist;
            album = metadata.album?.trim().isNotEmpty == true ? metadata.album!.trim() : null;
            genre = metadata.genre?.trim().isNotEmpty == true ? metadata.genre!.trim() : null;
            year = metadata.year;
            duration = metadata.durationMs == null ? null : (metadata.durationMs! / 1000).round();
          }
        } catch (_) {
          final cached = await MetadataCacheService.get(path);
          title = cached?.title ?? title;
          artist = cached?.artist ?? artist;
        }
      }
      final source = await sourceRepository.getSourceForTrack(path);
      final videoId = TrackSourceRepository.videoIdFromUrlOrId(path) ?? source?.youtubeVideoId;
      final track = PlaylistProfileTrack(
        path: path,
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        year: year,
        durationSeconds: duration,
        videoId: videoId,
        appearances: count,
        isCurrent: currentTrackId != null && _samePath(currentTrackId, path),
      );
      tracks.add(track);
      fingerprintParts.add(
        [
          entry.key,
          '$count',
          '$modified',
          title,
          artist,
          album ?? '',
          genre ?? '',
          '${year ?? ''}',
          videoId ?? '',
        ].join('|'),
      );
    }

    final artistWeights = <String, double>{};
    final tokenWeights = <String, double>{};
    final variantTokens = <String>{};
    final durations = <int>[];
    for (final track in tracks) {
      final artistKey = normalizeRecommendationText(track.artist);
      artistWeights[artistKey] = (artistWeights[artistKey] ?? 0) + track.appearances;
      for (final token in recommendationTokens(
        '${track.title} ${track.artist} ${track.album ?? ''} ${track.genre ?? ''}',
      )) {
        tokenWeights[token] = (tokenWeights[token] ?? 0) + track.appearances;
      }
      for (final token in _variantWords) {
        if (recommendationTokens(track.title).contains(token)) variantTokens.add(token);
      }
      if (track.durationSeconds case final duration?) durations.add(duration);
    }
    durations.sort();
    return PlaylistProfile(
      playlistNumber: playlistNumber,
      playlistName: playlistName,
      fingerprint: sha256.convert(utf8.encode(fingerprintParts.join('\n'))).toString(),
      tracks: List.unmodifiable(tracks),
      artistWeights: Map.unmodifiable(artistWeights),
      tokenWeights: Map.unmodifiable(tokenWeights),
      variantTokens: Set.unmodifiable(variantTokens),
      medianDurationSeconds: durations.isEmpty ? null : durations[durations.length ~/ 2],
    );
  }

  String _pathKey(String value) => _isStream(value)
      ? value.trim()
      : Platform.isWindows
      ? p.normalize(p.absolute(value)).toLowerCase()
      : p.normalize(p.absolute(value));

  bool _samePath(String first, String second) => _pathKey(first) == _pathKey(second);
}

const Set<String> _variantWords = {
  'live',
  'cover',
  'remix',
  'karaoke',
  'instrumental',
  'sped',
  'slowed',
  'reverb',
  'nightcore',
  'acoustic',
  'edit',
  'extended',
  'remaster',
  'remastered',
  'mashup',
  'bootleg',
  'demo',
  'unplugged',
  'performance',
  'session',
  'lofi',
  '8d',
  'bassboosted',
  'boosted',
};
const Set<String> _titleFormatWords = {
  'official',
  'music',
  'video',
  'audio',
  'lyrics',
  'lyric',
  'visualizer',
  'visualiser',
  'hd',
  'hq',
  '4k',
  'topic',
  'provided',
  'youtube',
  'records',
  'recordings',
};
const Set<String> _artistChannelWords = {'official', 'music', 'vevo', 'topic', 'records', 'recordings', 'channel'};
const Set<String> _nonMusicPhrases = {
  'interview',
  'reaction',
  'review',
  'podcast',
  'documentary',
  'tutorial',
  'behind the scenes',
};

List<PlaylistProfileTrack> selectRecommendationSeeds(PlaylistProfile profile, {int limit = 6}) {
  final unique = <String, PlaylistProfileTrack>{};
  for (final track in profile.tracks) {
    unique.putIfAbsent(track.songKey, () => track);
  }
  final ordered = unique.values.toList()
    ..sort((first, second) {
      if (first.isCurrent != second.isCurrent) return first.isCurrent ? -1 : 1;
      final firstWeight = profile.artistWeights[normalizeRecommendationText(first.artist)] ?? 0;
      final secondWeight = profile.artistWeights[normalizeRecommendationText(second.artist)] ?? 0;
      final weightOrder = secondWeight.compareTo(firstWeight);
      return weightOrder != 0 ? weightOrder : first.songKey.compareTo(second.songKey);
    });
  if (ordered.length > 2) {
    final mixed = <PlaylistProfileTrack>[];
    var left = 0;
    var right = ordered.length - 1;
    while (left <= right) {
      mixed.add(ordered[left++]);
      if (left <= right) mixed.add(ordered[right--]);
    }
    ordered
      ..clear()
      ..addAll(mixed);
  }
  final result = <PlaylistProfileTrack>[];
  final perArtist = <String, int>{};
  for (final track in ordered) {
    final artist = normalizeRecommendationText(track.artist);
    if ((perArtist[artist] ?? 0) >= 2) continue;
    result.add(track);
    perArtist[artist] = (perArtist[artist] ?? 0) + 1;
    if (result.length == limit) break;
  }
  return result;
}

List<String> recommendationQueries(PlaylistProfileTrack seed, PlaylistProfile profile, int generation) {
  final artist = seed.artist == 'Unknown Artist' ? '' : seed.artist;
  final genre = seed.genre?.trim().isNotEmpty == true ? seed.genre!.trim() : 'music';
  return switch (generation % 3) {
    1 => ['$artist official audio'.trim(), '$genre music discoveries'.trim()],
    2 => ['$artist related songs'.trim(), '$genre songs'.trim()],
    _ => ['$artist songs'.trim(), '$genre music'.trim()],
  };
}

typedef _SongIdentity = ({Set<String> title, Set<String> artist});

Set<String> _canonicalTitleTokens(String value) {
  var tokens = recommendationTokens(value).toList(growable: false);
  final featureIndex = tokens.indexWhere((token) => {'feat', 'featuring', 'ft'}.contains(token));
  if (featureIndex > 0) tokens = tokens.take(featureIndex).toList(growable: false);
  return tokens
      .where((token) => !_variantWords.contains(token) && !_titleFormatWords.contains(token))
      .where((token) => !RegExp(r'^(19|20)\d{2}p?$').hasMatch(token))
      .toSet();
}

Set<String> _canonicalArtistTokens(String value) => recommendationTokens(value)
    .where((token) => !_artistChannelWords.contains(token))
    .map((token) => token.endsWith('vevo') && token.length > 4 ? token.substring(0, token.length - 4) : token)
    .where((token) => token.isNotEmpty)
    .toSet();

_SongIdentity _profileIdentity(PlaylistProfileTrack track) =>
    (title: _canonicalTitleTokens(track.title), artist: _canonicalArtistTokens(track.artist));

_SongIdentity _youtubeIdentity(YoutubeTrack track) =>
    (title: _canonicalTitleTokens(track.title), artist: _canonicalArtistTokens(track.artist));

double _identitySimilarity(Set<String> first, Set<String> second) {
  if (first.isEmpty || second.isEmpty) return 0;
  final intersection = first.intersection(second).length;
  final shorter = math.min(first.length, second.length);
  final containment = intersection / shorter;
  final jaccard = intersection / first.union(second).length;
  return containment * 0.7 + jaccard * 0.3;
}

bool _sameSongIdentity(_SongIdentity first, _SongIdentity second) {
  final titleSimilarity = _identitySimilarity(first.title, second.title);
  // A one-word song title followed by an uploader-added artist name still
  // scores 0.80. Keep that inside the identity check, then require artist
  // evidence below so unrelated songs such as "Stay" and "Stay With Me" do
  // not collapse into one another.
  if (titleSimilarity < 0.78) return false;
  final shorterTitle = math.min(first.title.length, second.title.length);
  if (shorterTitle >= 2) return true;
  return _identitySimilarity(first.artist, second.artist) >= 0.45 ||
      first.artist.intersection(second.title).isNotEmpty ||
      second.artist.intersection(first.title).isNotEmpty;
}

List<RecommendationCandidate> filterRecommendationCandidates(
  PlaylistProfile profile,
  List<RecommendationCandidate> candidates,
) {
  final playlistIds = profile.tracks.map((track) => track.videoId).whereType<String>().toSet();
  final playlistSongs = profile.tracks.map((track) => track.songKey).toSet();
  final playlistIdentities = profile.tracks.map(_profileIdentity).toList(growable: false);
  final byVideo = <String, RecommendationCandidate>{};
  final bySong = <String>{};
  final acceptedIdentities = <_SongIdentity>[];
  final median = profile.medianDurationSeconds ?? 240;
  final minimumDuration = math.max(30, (median * 0.20).round());
  final maximumDuration = math.min(1800, math.max(900, median * 4));
  for (final candidate in candidates) {
    final track = candidate.track;
    final videoId = track.videoId;
    if (videoId == null || playlistIds.contains(videoId) || track.isLive || track.isShort) continue;
    if (track.availability case final availability?
        when {'private', 'premium_only', 'subscriber_only'}.contains(availability)) {
      continue;
    }
    final songKey = '${normalizeRecommendationText(track.artist)}|${normalizeRecommendationText(track.title)}';
    if (playlistSongs.contains(songKey) || bySong.contains(songKey)) continue;
    final identity = _youtubeIdentity(track);
    if (playlistIdentities.any((playlistTrack) => _sameSongIdentity(playlistTrack, identity))) continue;
    if (acceptedIdentities.any((accepted) => _sameSongIdentity(accepted, identity))) continue;
    final title = normalizeRecommendationText(track.title);
    if (_nonMusicPhrases.any(title.contains) || title.contains('#shorts') || track.url.contains('/shorts/')) continue;
    final duration = track.durationSeconds;
    if (duration != null && (duration < minimumDuration || duration > maximumDuration)) continue;
    final tokens = recommendationTokens(title);
    if (_variantWords.any((variant) => tokens.contains(variant) && !profile.variantTokens.contains(variant))) continue;
    final previous = byVideo[videoId];
    if (previous == null || candidate.queryRank < previous.queryRank) {
      byVideo[videoId] = candidate;
    }
    bySong.add(songKey);
    acceptedIdentities.add(identity);
  }
  return byVideo.values.toList(growable: false);
}

double scoreRecommendationCandidate(PlaylistProfile profile, RecommendationCandidate candidate) {
  final track = candidate.track;
  final artistTokens = _canonicalArtistTokens(track.artist);
  final artistKey = artistTokens.join(' ');
  final titleArtistTokens = recommendationTokens('${track.title} ${track.artist}');
  final queryTokens = recommendationTokens(candidate.query);
  final maximumArtistWeight = profile.artistWeights.values.fold<double>(1, math.max);
  final exactArtist = (profile.artistWeights[artistKey] ?? 0) / maximumArtistWeight;
  final profileArtistTokens = profile.artistWeights.keys.expand(_canonicalArtistTokens).toSet();
  final artistOverlap = _overlap(artistTokens, profileArtistTokens);
  final artistStyle = math.max(exactArtist, artistOverlap * 0.72);
  final totalProfileWeight = profile.tokenWeights.values.fold<double>(1, (sum, value) => sum + value);
  final profileSimilarity =
      titleArtistTokens.fold<double>(0, (sum, token) => sum + (profile.tokenWeights[token] ?? 0)) /
      totalProfileWeight *
      math.max(1, profile.tokenWeights.length / math.max(1, titleArtistTokens.length));
  final rankScore = (1 - candidate.queryRank / 10).clamp(0.0, 1.0);
  final searchRelevance = rankScore * 0.7 + _overlap(titleArtistTokens, queryTokens) * 0.3;
  final median = profile.medianDurationSeconds;
  final duration = track.durationSeconds;
  final durationFit = median == null || duration == null
      ? 0.65
      : (1 - (duration - median).abs() / math.max(median, 1)).clamp(0.0, 1.0);
  final metadataQuality = (track.title.trim().isNotEmpty && track.artist.trim().isNotEmpty && track.artist != 'Unknown')
      ? 1.0
      : 0.45;
  final quality = durationFit * 0.55 + metadataQuality * 0.45;
  final novelty = profile.artistWeights.containsKey(artistKey) ? 0.35 : 1.0;
  var score = artistStyle * 0.35 + profileSimilarity.clamp(0.0, 1.0) * 0.25;
  score += searchRelevance * 0.20 + quality * 0.10 + novelty * 0.10;
  if (track.thumbnailUrl == null) score -= 0.03;
  if (metadataQuality < 1) score -= 0.07;
  final titleTokens = recommendationTokens(track.title);
  if (_titleFormatWords.intersection(titleTokens).length >= 2) score -= 0.04;
  return score.clamp(0.0, 1.0);
}

List<RecommendationCandidate> rankAndDiversifyRecommendations(
  PlaylistProfile profile,
  List<RecommendationCandidate> candidates, {
  int limit = 10,
}) {
  final ranked =
      candidates.map((candidate) => candidate.withScore(scoreRecommendationCandidate(profile, candidate))).toList()
        ..sort((first, second) {
          final scoreOrder = second.score.compareTo(first.score);
          if (scoreOrder != 0) return scoreOrder;
          final firstTie =
              '${normalizeRecommendationText(first.track.title)}|${first.track.videoId ?? first.track.url}';
          final secondTie =
              '${normalizeRecommendationText(second.track.title)}|${second.track.videoId ?? second.track.url}';
          return firstTie.compareTo(secondTie);
        });
  final selected = <RecommendationCandidate>[];
  final selectedIds = <String>{};
  final artists = <String, int>{};
  final queries = <String, int>{};

  void pass({required bool capArtists, required bool capQueries}) {
    for (final candidate in ranked) {
      if (selected.length >= limit) return;
      final id = candidate.track.videoId ?? candidate.track.url;
      if (selectedIds.contains(id)) continue;
      final artist = _canonicalArtistTokens(candidate.track.artist).join(' ');
      if (capArtists && (artists[artist] ?? 0) >= 2) continue;
      if (capQueries && (queries[candidate.query] ?? 0) >= 3) continue;
      selected.add(candidate);
      selectedIds.add(id);
      artists[artist] = (artists[artist] ?? 0) + 1;
      queries[candidate.query] = (queries[candidate.query] ?? 0) + 1;
    }
  }

  pass(capArtists: true, capQueries: true);
  pass(capArtists: true, capQueries: false);
  pass(capArtists: false, capQueries: false);
  return selected;
}

double _overlap(Set<String> first, Set<String> second) {
  if (first.isEmpty || second.isEmpty) return 0;
  return first.intersection(second).length / first.union(second).length;
}

bool _isStream(String value) => value.startsWith('http://') || value.startsWith('https://');

@immutable
class _RecommendationRankingInput {
  final PlaylistProfile profile;
  final List<RecommendationCandidate> candidates;

  const _RecommendationRankingInput(this.profile, this.candidates);
}

List<RecommendationCandidate> _rankRecommendationInput(_RecommendationRankingInput input) {
  return rankAndDiversifyRecommendations(input.profile, input.candidates);
}

class SuggestedMusicService {
  static const String cacheKey = 'suggested_music_cache_v1';
  static const Duration cacheTtl = Duration(minutes: 15);
  static const int algorithmVersion = 2;
  static const int maxSearchRequests = 6;
  static const int minimumSearchRequests = 4;
  static const Duration searchTimeout = Duration(seconds: 10);
  final SharedPreferences? _preferences;
  final DateTime Function() _clock;

  const SuggestedMusicService({SharedPreferences? preferences, DateTime Function()? clock})
    : _preferences = preferences,
      _clock = clock ?? DateTime.now;

  Future<SuggestedMusicResult> generate({
    required PlaylistProfile profile,
    required YoutubeSuggestionSearch search,
    int refreshGeneration = 0,
    bool Function()? isCancelled,
  }) async {
    final cached = await _cached(profile.fingerprint, refreshGeneration);
    if (cached != null) return SuggestedMusicResult(profile: profile, tracks: cached, fromCache: true);
    final seeds = selectRecommendationSeeds(profile);
    final seenQueries = <String>{};
    final queriesBySeed = {for (final seed in seeds) seed: recommendationQueries(seed, profile, refreshGeneration)};
    final jobs = <({PlaylistProfileTrack seed, String query})>[];
    // Interleave the first query from every seed before scheduling any
    // fallback query. This yields broad artist coverage much earlier.
    for (var queryIndex = 0; queryIndex < 2; queryIndex++) {
      for (final seed in seeds) {
        final queries = queriesBySeed[seed]!;
        if (queryIndex >= queries.length) continue;
        final query = queries[queryIndex];
        if (query.isNotEmpty && seenQueries.add(normalizeRecommendationText(query))) {
          jobs.add((seed: seed, query: query));
        }
      }
    }
    final candidates = <RecommendationCandidate>[];
    final requestCount = math.min(jobs.length, maxSearchRequests);
    for (var offset = 0; offset < requestCount; offset += 2) {
      if (isCancelled?.call() ?? false) throw const SuggestedMusicCancelled();
      final batch = jobs.skip(offset).take(math.min(2, requestCount - offset)).toList(growable: false);
      final batchResults = await Future.wait([
        for (final job in batch) _runSuggestionSearch(search, job.query, searchTimeout),
      ]);
      for (var batchIndex = 0; batchIndex < batch.length; batchIndex++) {
        final job = batch[batchIndex];
        final results = batchResults[batchIndex];
        for (var rank = 0; rank < results.length && rank < 10 && candidates.length < 120; rank++) {
          candidates.add(
            RecommendationCandidate(track: results[rank], seedKey: job.seed.songKey, query: job.query, queryRank: rank),
          );
        }
      }
      if (isCancelled?.call() ?? false) throw const SuggestedMusicCancelled();
      final completedRequests = offset + batch.length;
      if (completedRequests >= minimumSearchRequests) {
        final currentPool = filterRecommendationCandidates(profile, candidates);
        if (currentPool.length >= 18 && rankAndDiversifyRecommendations(profile, currentPool).length >= 10) break;
      }
    }
    final filtered = filterRecommendationCandidates(profile, candidates);
    // Keep the isolate message graph deliberately data-only. An Isolate.run
    // closure created in this method can retain the complete async context,
    // including [isCancelled]. The UI supplies that callback from State, so
    // retaining it also retains Flutter Elements and fails with an
    // "object is unsendable" exception on native platforms.
    final ranked = await compute(_rankRecommendationInput, _RecommendationRankingInput(profile, filtered));
    final results = ranked.take(10).map((candidate) => candidate.track).toList(growable: false);
    await _store(
      profile.fingerprint,
      refreshGeneration,
      results,
      filtered.map((candidate) => candidate.track).toList(),
    );
    return SuggestedMusicResult(profile: profile, tracks: results, fromCache: false);
  }

  Future<List<YoutubeTrack>?> _cached(String fingerprint, int generation) async {
    final entries = await _loadCache();
    final now = _clock().millisecondsSinceEpoch;
    for (final entry in entries) {
      if (entry['fingerprint'] == fingerprint &&
          entry['algorithmVersion'] == algorithmVersion &&
          entry['generation'] == generation &&
          (entry['expiresAt'] as num? ?? 0) > now) {
        final raw = entry['results'];
        if (raw is List) {
          return raw
              .whereType<Map>()
              .map((value) => YoutubeTrack.fromCacheJson(Map<String, dynamic>.from(value)))
              .toList();
        }
      }
    }
    return null;
  }

  Future<void> _store(String fingerprint, int generation, List<YoutubeTrack> results, List<YoutubeTrack> pool) async {
    final entries = await _loadCache();
    entries.removeWhere((entry) => entry['fingerprint'] == fingerprint && entry['generation'] == generation);
    entries.insert(0, {
      'fingerprint': fingerprint,
      'algorithmVersion': algorithmVersion,
      'generation': generation,
      'expiresAt': _clock().add(cacheTtl).millisecondsSinceEpoch,
      'results': results.map((track) => track.toJson()).toList(),
      'pool': pool.take(120).map((track) => track.toJson()).toList(),
    });
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    await prefs.setString(cacheKey, jsonEncode(entries.take(3).toList()));
  }

  Future<List<Map<String, dynamic>>> _loadCache() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final raw = prefs.getString(cacheKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.whereType<Map>().map((value) => Map<String, dynamic>.from(value)).toList() : [];
    } catch (_) {
      return [];
    }
  }
}

class SuggestedMusicCancelled implements Exception {
  const SuggestedMusicCancelled();
}
