import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_range.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/favorites_repository.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/widgets/library/track_tile.dart';
import 'package:resonance/widgets/library/favorite_tracks_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('track menu favorites a song and every playlist row gains the gold cue', (tester) async {
    final favorites = FavoritesRepository(files: _MemoryFavoritesFiles());
    addTearDown(favorites.dispose);
    await favorites.refresh();
    final handler = _FakePlayerHandler();
    const track = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<PlayerHandler>.value(value: handler),
          ChangeNotifierProvider<FavoritesRepository>.value(value: favorites),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Column(
              children: [
                for (final number in [1, 2])
                  TrackTile(
                    key: ValueKey(number),
                    trackPath: track,
                    playlistNumber: number,
                    index: 0,
                    onDelete: () {},
                    onDeleteEverywhere: () {},
                    metadataLoader: (_) async => const CachedTrackMetadata(title: 'Same song', artist: 'Artist'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_cue(Icons.drag_handle_rounded), findsNWidgets(2));
    await tester.tap(find.byTooltip('Track actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Add to favorites'), findsOneWidget);
    await tester.tap(find.text('Add to favorites'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(favorites.isFavorite(track), isTrue);
    expect(_cue(Icons.star_rounded), findsNWidgets(2));
    for (final icon in tester.widgetList<Icon>(_cue(Icons.star_rounded))) {
      expect(icon.color, FavoritesRepository.gold);
    }
    for (final region in tester.widgetList<TrackTapRegion>(find.byType(TrackTapRegion))) {
      final ink = tester.widget<InkWell>(
        find.descendant(of: find.byWidget(region), matching: find.byType(InkWell)).first,
      );
      expect(ink.hoverColor, Colors.transparent);
      expect(ink.focusColor, Colors.transparent);
      expect(ink.highlightColor, Colors.transparent);
    }
    handler.playbackVisualNotifier.value = const PlaybackVisualState(trackId: track, playing: true);
    await tester.pumpAndSettle();
    final playingLines = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .where((container) => container.constraints?.maxWidth == 3 && container.constraints?.maxHeight == 32);
    expect(playingLines, hasLength(2));
    for (final line in playingLines) {
      final decoration = line.decoration! as BoxDecoration;
      expect(decoration.color, FavoritesRepository.gold);
      expect(decoration.boxShadow!.single.color, FavoritesRepository.gold.withValues(alpha: .42));
    }
    handler.shuffled = true;
    handler.playbackModeRevision.value++;
    await tester.pumpAndSettle();
    expect(_cue(Icons.shuffle_rounded), findsNWidgets(2));
    for (final icon in tester.widgetList<Icon>(_cue(Icons.shuffle_rounded))) {
      expect(icon.color, FavoritesRepository.gold);
    }
    await tester.tap(find.byTooltip('Track actions').last);
    await tester.pumpAndSettle();
    expect(find.text('Remove from favorites'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bulk star changes action for majority, treats a tie as add, and preserves other favorites', (
    tester,
  ) async {
    final favorites = FavoritesRepository(files: _MemoryFavoritesFiles());
    addTearDown(favorites.dispose);
    await favorites.setTracks(['other'], true);
    const selected = ['a', 'b', 'c', 'd'];
    await tester.pumpWidget(
      ChangeNotifierProvider<FavoritesRepository>.value(
        value: favorites,
        child: MaterialApp(
          home: Scaffold(
            body: FavoriteTracksButton(
              tracks: selected,
              onPressed: (favorite) => favorites.setTracks(selected, favorite),
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('Add selected to favorites'));
    await tester.pumpAndSettle();
    expect(favorites.allFavorite(selected), isTrue);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    await favorites.setTracks(['a', 'b'], false);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Add selected to favorites'), findsOneWidget);
    await favorites.setTracks(['a'], true);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove selected from favorites'), findsOneWidget);
    expect(tester.widget<Icon>(find.byIcon(Icons.star_rounded)).color, FavoritesRepository.gold);
    await tester.tap(find.byTooltip('Remove selected from favorites'));
    await tester.pumpAndSettle();
    expect(selected.any(favorites.isFavorite), isFalse);
    expect(favorites.isFavorite('other'), isTrue);
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

Finder _cue(IconData icon) =>
    find.byWidgetPredicate((widget) => widget is Icon && widget.icon == icon && widget.size == 18);

class _FakePlayerHandler extends Fake implements PlayerHandler {
  @override
  final playbackRangeRevision = ValueNotifier<int>(0);
  @override
  Future<PlaybackRange> savedPlaybackRangeFor(String path) async => PlaybackRange.full;

  bool shuffled = false;
  @override
  final playbackVisualNotifier = ValueNotifier(const PlaybackVisualState());
  @override
  final playbackModeRevision = ValueNotifier(0);
  @override
  bool getShuffleMode() => shuffled;
}

class _MemoryFavoritesFiles extends Fake implements FileService {
  final _tracks = <String>[];
  @override
  Future<List<String>> readPlaylistTracks(int number) async => List.of(_tracks);
  @override
  Future<Map<String, String>> favoriteSourceIds() async => {};
  @override
  String favoriteIdentity(String track, {Map<String, String> sourceIds = const {}}) =>
      FileService().favoriteIdentity(track, sourceIds: sourceIds);
  @override
  Future<void> toggleTrackFavorite(String track) async {
    if (!_tracks.remove(track)) _tracks.add(track);
  }

  @override
  Future<void> setTracksFavorite(Iterable<String> tracks, bool favorite) async {
    if (favorite) {
      for (final track in tracks) {
        if (!_tracks.contains(track)) _tracks.add(track);
      }
    } else {
      _tracks.removeWhere(tracks.contains);
    }
  }
}
