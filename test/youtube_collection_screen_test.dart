import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/core/youtube/youtube_music_home_models.dart';
import 'package:resonance/models/external_playlist.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/screens/youtube/youtube_collection_screen.dart';
import 'package:resonance/screens/youtube/youtube_search_screen.dart';

const item = YoutubeMusicHomeItem(title: 'My collection', subtitle: 'Artist', kind: 'playlist', playlistId: 'PLtest');
ExternalPlaylist playlist([List<ExternalPlaylistTrack>? tracks]) => ExternalPlaylist(
  kind: ExternalPlaylistKind.youtube,
  name: item.title,
  sourceUri: Uri.parse(item.playlistUrl!),
  tracks:
      tracks ??
      const [
        ExternalPlaylistTrack(title: 'First song', artists: ['First artist'], sourceId: 'aaaaaaaaaaa'),
        ExternalPlaylistTrack(title: 'Unavailable', artists: [], sourceId: null),
        ExternalPlaylistTrack(
          title: 'Second song',
          artists: ['Second artist'],
          sourceId: 'bbbbbbbbbbb',
          duration: Duration(seconds: 123),
        ),
      ],
);

void main() {
  testWidgets('browsing does not play; choosing the second song supplies the full collection', (tester) async {
    final loading = Completer<ExternalPlaylist>();
    YoutubeTrack? selected;
    List<YoutubeTrack>? queue;
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeCollectionScreen(
          item: item,
          loader: (_) => loading.future,
          onPlay: (track, tracks) async {
            selected = track;
            queue = tracks;
          },
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(selected, isNull);
    loading.complete(playlist());
    await tester.pumpAndSettle();
    expect(find.text('Unavailable'), findsNothing);
    expect(find.text('2:03'), findsOneWidget);
    expect(selected, isNull);
    await tester.tap(find.text('Second song'));
    await tester.pumpAndSettle();
    expect(selected?.url, 'https://www.youtube.com/watch?v=bbbbbbbbbbb');
    expect(queue?.map((track) => track.title), ['First song', 'Second song']);
  });

  testWidgets('a failed collection can retry and an empty collection has no play action', (tester) async {
    var attempts = 0;
    var plays = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeCollectionScreen(
          item: item,
          loader: (_) async {
            if (++attempts == 1) throw StateError('offline');
            return playlist([]);
          },
          onPlay: (_, __) async => plays++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load this collection.'), findsOneWidget);
    await tester.ensureVisible(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No playable songs in this collection.'), findsOneWidget);
    expect(plays, 0);
  });

  testWidgets('leaving while a collection loads ignores its late completion', (tester) async {
    final loading = Completer<ExternalPlaylist>();
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeCollectionScreen(item: item, loader: (_) => loading.future, onPlay: (_, __) async {}),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    loading.complete(playlist());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('responsive collection layout keeps long titles and song selection usable', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [const Size(320, 568), const Size(1280, 720)]) {
      await tester.binding.setSurfaceSize(size);
      YoutubeTrack? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildResonanceTheme(ResonanceThemeStyle.obsidian, Brightness.dark, rounderCorners: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: YoutubeCollectionScreen(
            key: ValueKey(size.width),
            item: const YoutubeMusicHomeItem(
              title: 'A very long playlist title that should wrap naturally on a small phone',
              subtitle: 'A collection with a long description and artist credits',
              kind: 'playlist',
              playlistId: 'PLtest',
            ),
            loader: (_) async => playlist(),
            onPlay: (track, _) async => selected = track,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('youtube-collection-track-1')),
        200,
        scrollable: find
            .descendant(of: find.byKey(const Key('youtube-collection-tracklist')), matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second song'));
      await tester.pumpAndSettle();
      expect(selected?.title, 'Second song');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Play starts at the first song and Shuffle supplies every song once', (tester) async {
    YoutubeTrack? selected;
    List<YoutubeTrack>? queue;
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeCollectionScreen(
          item: item,
          loader: (_) async => playlist(),
          onPlay: (track, tracks) async {
            selected = track;
            queue = tracks;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('youtube-collection-play')));
    await tester.pumpAndSettle();
    expect(selected?.title, 'First song');
    expect(queue?.map((track) => track.title), ['First song', 'Second song']);
    await tester.tap(find.byKey(const Key('youtube-collection-shuffle')));
    await tester.pumpAndSettle();
    expect(selected, queue?.first);
    expect(queue?.map((track) => track.title), unorderedEquals(['First song', 'Second song']));
    expect(find.text('First song'), findsOneWidget);
    expect(find.text('Second song'), findsOneWidget);
  });

  testWidgets('Discover collection cards navigate to the picker without accessing a player', (tester) async {
    String? requestedUrl;
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist 1',
          embedded: true,
          startOnMusicHome: true,
          playlistLibraryLoader: () async =>
              const YoutubeMusicHomeShelf(title: 'Playlist Library', tracks: [], items: [item]),
          youtubeMusicHomeLoader: () async => const YoutubeMusicHome(shelves: []),
          collectionLoader: (url) async {
            requestedUrl = url;
            return playlist();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('youtube-home-card-My collection')));
    await tester.pumpAndSettle();
    expect(find.byType(YoutubeCollectionScreen), findsOneWidget);
    expect(find.text('Second song'), findsOneWidget);
    expect(requestedUrl, item.playlistUrl);
    expect(tester.takeException(), isNull);
  });
}
