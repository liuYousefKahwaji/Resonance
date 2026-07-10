import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/services/playlist_transfer_export_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/youtube_transfer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const firstCandidate = YoutubeSearchCandidate(
    title: 'First result',
    uploader: 'Channel A',
    url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
    videoId: 'aaaaaaaaaaa',
  );
  const secondCandidate = YoutubeSearchCandidate(
    title: 'Second result',
    uploader: 'Channel B',
    url: 'https://www.youtube.com/watch?v=bbbbbbbbbbb',
    videoId: 'bbbbbbbbbbb',
  );

  PlaylistSourceScan scanWith(List<UnresolvedPlaylistTrack> unresolved) => PlaylistSourceScan(
    playlistName: 'Test',
    playlistTracks: [for (final track in unresolved) track.localPath],
    resolvedByPath: {},
    unresolved: unresolved,
  );

  test('automatic matching chooses the first result without prompting per track', () async {
    final scan = scanWith(const [
      UnresolvedPlaylistTrack(localPath: 'one.mp3', title: 'One', artist: 'Artist', occurrenceCount: 1),
      UnresolvedPlaylistTrack(localPath: 'two.mp3', title: 'Two', artist: 'Artist', occurrenceCount: 1),
    ]);
    final queries = <String>[];

    final matches = await const PlaylistTransferExportService().findAutomaticMatches(scan, (query) async {
      queries.add(query);
      return const [firstCandidate, secondCandidate];
    });

    expect(queries, ['Artist One', 'Artist Two']);
    expect(matches, hasLength(2));
    expect(matches.every((match) => match.selected?.videoId == firstCandidate.videoId), isTrue);
    expect(matches.every((match) => !match.manuallyChanged), isTrue);
  });

  test('a failed search is retained for review and does not stop later tracks', () async {
    final scan = scanWith(const [
      UnresolvedPlaylistTrack(localPath: 'one.mp3', title: 'One', artist: 'Artist', occurrenceCount: 1),
      UnresolvedPlaylistTrack(localPath: 'two.mp3', title: 'Two', artist: 'Artist', occurrenceCount: 1),
    ]);
    var calls = 0;

    final matches = await const PlaylistTransferExportService().findAutomaticMatches(scan, (_) async {
      calls++;
      if (calls == 1) throw Exception('offline');
      return const [secondCandidate];
    });

    expect(matches.first.selected, isNull);
    expect(matches.first.error, contains('offline'));
    expect(matches.last.selected?.videoId, secondCandidate.videoId);
  });

  test('reviewed matches are committed once and duplicate playlist order is preserved', () async {
    SharedPreferences.setMockInitialValues({});
    final scan = PlaylistSourceScan(
      playlistName: 'Duplicates',
      playlistTracks: const ['one.mp3', 'two.mp3', 'one.mp3'],
      resolvedByPath: {},
      unresolved: const [
        UnresolvedPlaylistTrack(localPath: 'one.mp3', title: 'One', artist: 'Artist', occurrenceCount: 2),
        UnresolvedPlaylistTrack(localPath: 'two.mp3', title: 'Two', artist: 'Artist', occurrenceCount: 1),
      ],
    );
    final first = PlaylistSourceMatch(
      track: scan.unresolved.first,
      query: 'Artist One',
      selected: firstCandidate,
      manuallyChanged: true,
    );
    final skipped = PlaylistSourceMatch(
      track: scan.unresolved.last,
      query: 'Artist Two',
      selected: secondCandidate,
      skipped: true,
    );

    await const PlaylistTransferExportService().commitMatches(scan, [first, skipped]);

    expect(scan.resolvedVideoIds, ['aaaaaaaaaaa', 'aaaaaaaaaaa']);
    expect(scan.skippedEntryCount, 1);
    final saved = await const TrackSourceRepository().getSourceForTrack('one.mp3');
    expect(saved?.youtubeVideoId, 'aaaaaaaaaaa');
    expect(saved?.method, TrackSourceMethod.manuallySelected);
    expect(await const TrackSourceRepository().getSourceForTrack('two.mp3'), isNull);
  });

  test('automatic matching can be cancelled between searches', () async {
    final scan = scanWith(const [
      UnresolvedPlaylistTrack(localPath: 'one.mp3', title: 'One', artist: 'Artist', occurrenceCount: 1),
      UnresolvedPlaylistTrack(localPath: 'two.mp3', title: 'Two', artist: 'Artist', occurrenceCount: 1),
    ]);
    var cancel = false;

    expect(
      () => const PlaylistTransferExportService().findAutomaticMatches(scan, (_) async {
        cancel = true;
        return const [firstCandidate];
      }, isCancelled: () => cancel),
      throwsA(isA<PlaylistSourceMatchingCancelled>()),
    );
  });
}
