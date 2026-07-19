import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/suggested_music_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

PlaylistProfile _profile(List<PlaylistProfileTrack> tracks) {
  final artistWeights = <String, double>{};
  final tokenWeights = <String, double>{};
  for (final track in tracks) {
    final artist = normalizeRecommendationText(track.artist);
    artistWeights[artist] = (artistWeights[artist] ?? 0) + track.appearances;
    for (final token in recommendationTokens('${track.artist} ${track.title} ${track.genre ?? ''}')) {
      tokenWeights[token] = (tokenWeights[token] ?? 0) + track.appearances;
    }
  }
  return PlaylistProfile(
    playlistNumber: 1,
    playlistName: 'Mix',
    fingerprint: 'profile-fingerprint',
    tracks: tracks,
    artistWeights: artistWeights,
    tokenWeights: tokenWeights,
    variantTokens: const {},
    medianDurationSeconds: 220,
  );
}

YoutubeTrack _youtube(int id, {String? artist, String? title, int duration = 210}) => YoutubeTrack(
  title: title ?? 'Song $id',
  artist: artist ?? 'Artist ${id % 6}',
  url: 'https://www.youtube.com/watch?v=v${id.toString().padLeft(10, '0')}',
  durationSeconds: duration,
  thumbnailUrl: 'https://img.test/$id.jpg',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('seed selection prioritizes current track, caps artists, and mixes the playlist tail', () {
    final profile = _profile([
      const PlaylistProfileTrack(path: 'current', title: 'Current', artist: 'A', isCurrent: true, appearances: 5),
      const PlaylistProfileTrack(path: 'a2', title: 'Second', artist: 'A', appearances: 4),
      const PlaylistProfileTrack(path: 'a3', title: 'Third', artist: 'A', appearances: 3),
      const PlaylistProfileTrack(path: 'b', title: 'B song', artist: 'B', appearances: 2),
      const PlaylistProfileTrack(path: 'c', title: 'C song', artist: 'C'),
      const PlaylistProfileTrack(path: 'd', title: 'D song', artist: 'D'),
      const PlaylistProfileTrack(path: 'e', title: 'E song', artist: 'E'),
    ]);

    final seeds = selectRecommendationSeeds(profile);
    expect(seeds.first.path, 'current');
    expect(seeds.where((track) => track.artist == 'A').length, lessThanOrEqualTo(2));
    expect(seeds.map((track) => track.artist).toSet().length, greaterThan(2));
  });

  test('filter removes playlist members, duplicates, non-music, variants, and extreme durations', () {
    final profile = _profile([
      const PlaylistProfileTrack(path: 'existing', title: 'Existing Song', artist: 'Known', videoId: 'aaaaaaaaaaa'),
    ]);
    final candidates = [
      RecommendationCandidate(track: _youtube(1), seedKey: 's', query: 'q', queryRank: 0),
      RecommendationCandidate(track: _youtube(1), seedKey: 's', query: 'q2', queryRank: 1),
      RecommendationCandidate(
        track: const YoutubeTrack(
          title: 'Existing Song',
          artist: 'Known',
          url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
        ),
        seedKey: 's',
        query: 'q',
        queryRank: 2,
      ),
      RecommendationCandidate(
        track: _youtube(2, title: 'Artist Interview'),
        seedKey: 's',
        query: 'q',
        queryRank: 3,
      ),
      RecommendationCandidate(
        track: _youtube(3, title: 'Song Remix'),
        seedKey: 's',
        query: 'q',
        queryRank: 4,
      ),
      RecommendationCandidate(track: _youtube(4, duration: 4000), seedKey: 's', query: 'q', queryRank: 5),
    ];

    final filtered = filterRecommendationCandidates(profile, candidates);
    expect(filtered.map((candidate) => candidate.track.videoId), ['v0000000001']);
  });

  test('filter rejects alternate uploads of a playlist song across uploaders', () {
    final profile = _profile([
      const PlaylistProfileTrack(
        path: 'existing',
        title: 'Blinding Lights',
        artist: 'The Weeknd',
        videoId: 'aaaaaaaaaaa',
      ),
      const PlaylistProfileTrack(path: 'short-title', title: 'Stay', artist: 'Justin Bieber'),
    ]);
    final candidates = [
      RecommendationCandidate(
        track: _youtube(10, artist: 'Random Uploads', title: 'The Weeknd - Blinding Lights (Slowed + Reverb)'),
        seedKey: 's',
        query: 'q',
        queryRank: 0,
      ),
      RecommendationCandidate(
        track: _youtube(11, artist: 'TheWeekndVEVO', title: 'Blinding Lights (Official Audio)'),
        seedKey: 's',
        query: 'q',
        queryRank: 1,
      ),
      RecommendationCandidate(
        track: _youtube(12, artist: 'Lyrics Channel', title: 'Justin Bieber - Stay Lyrics'),
        seedKey: 's',
        query: 'q',
        queryRank: 2,
      ),
      RecommendationCandidate(
        track: _youtube(13, artist: 'TheWeekndVEVO', title: 'Save Your Tears (Official Video)'),
        seedKey: 's',
        query: 'q',
        queryRank: 3,
      ),
    ];

    final filtered = filterRecommendationCandidates(profile, candidates);

    expect(filtered.map((candidate) => candidate.track.videoId), ['v0000000013']);
  });

  test('queries discover related music instead of targeting the seed title', () {
    final profile = _profile([
      const PlaylistProfileTrack(path: 'a', title: 'Very Specific Song', artist: 'Artist A', genre: 'Synth Pop'),
    ]);
    final seed = profile.tracks.single;

    for (var generation = 0; generation < 3; generation++) {
      final queries = recommendationQueries(seed, profile, generation);
      expect(queries, hasLength(2));
      expect(queries.every((query) => !normalizeRecommendationText(query).contains('very specific song')), isTrue);
    }
  });

  test('ranking is stable and diversity caps an artist when alternatives exist', () {
    final profile = _profile([
      const PlaylistProfileTrack(path: 'a', title: 'Dream', artist: 'Anchor', genre: 'Pop'),
      const PlaylistProfileTrack(path: 'b', title: 'Night', artist: 'Second', genre: 'Pop'),
    ]);
    final candidates = <RecommendationCandidate>[
      for (var index = 0; index < 16; index++)
        RecommendationCandidate(
          track: _youtube(index + 20, artist: index < 6 ? 'One Artist' : 'Artist $index'),
          seedKey: 'seed-${index % 2}',
          query: 'query-${index % 4}',
          queryRank: index % 10,
        ),
    ];

    final first = rankAndDiversifyRecommendations(profile, candidates);
    final second = rankAndDiversifyRecommendations(profile, candidates);
    expect(first.map((candidate) => candidate.track.videoId), second.map((candidate) => candidate.track.videoId));
    expect(first.length, 10);
    expect(first.where((candidate) => candidate.track.artist == 'One Artist').length, lessThanOrEqualTo(2));
  });

  test('generation caches ten results and avoids repeated search work', () async {
    final prefs = await SharedPreferences.getInstance();
    final profile = _profile([
      const PlaylistProfileTrack(path: 'a', title: 'Alpha', artist: 'Artist A'),
      const PlaylistProfileTrack(path: 'b', title: 'Beta', artist: 'Artist B'),
      const PlaylistProfileTrack(path: 'c', title: 'Gamma', artist: 'Artist C'),
    ]);
    var calls = 0;
    Future<List<YoutubeTrack>> search(String query) async {
      final batch = calls++;
      return [for (var index = 0; index < 10; index++) _youtube(100 + batch * 10 + index)];
    }

    final service = SuggestedMusicService(preferences: prefs);
    final first = await service.generate(profile: profile, search: search);
    final callsAfterFirst = calls;
    final second = await service.generate(profile: profile, search: search);

    expect(first.tracks, hasLength(10));
    expect(first.fromCache, isFalse);
    expect(second.fromCache, isTrue);
    expect(calls, callsAfterFirst);
  });

  test('generation stops after four searches when the candidate pool is strong', () async {
    final prefs = await SharedPreferences.getInstance();
    final profile = _profile([
      for (var index = 0; index < 6; index++)
        PlaylistProfileTrack(path: 'seed-$index', title: 'Seed $index', artist: 'Seed Artist $index'),
    ]);
    var calls = 0;
    Future<List<YoutubeTrack>> search(String query) async {
      final batch = calls++;
      return [
        for (var index = 0; index < 10; index++)
          _youtube(700 + batch * 10 + index, artist: 'New Artist ${batch * 10 + index}'),
      ];
    }

    final result = await SuggestedMusicService(preferences: prefs).generate(profile: profile, search: search);

    expect(result.tracks, hasLength(10));
    expect(calls, SuggestedMusicService.minimumSearchRequests);
  });

  testWidgets('ranking isolate does not retain the UI cancellation context', (tester) async {
    late BuildContext screenContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            screenContext = context;
            return const SizedBox();
          },
        ),
      ),
    );
    final profile = _profile([
      const PlaylistProfileTrack(path: 'a', title: 'Alpha', artist: 'Artist A'),
      const PlaylistProfileTrack(path: 'b', title: 'Beta', artist: 'Artist B'),
    ]);
    var batch = 0;

    late SuggestedMusicResult result;
    await tester.runAsync(() async {
      result = await const SuggestedMusicService().generate(
        profile: profile,
        search: (_) async {
          final offset = batch++ * 10;
          return [for (var index = 0; index < 10; index++) _youtube(500 + offset + index)];
        },
        isCancelled: () => !screenContext.mounted,
      );
    });

    expect(result.tracks, hasLength(10));
  });
}
