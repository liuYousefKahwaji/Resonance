import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/youtube/youtube_music_home_models.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/youtube_artist.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/screens/youtube/youtube_artist_screen.dart';
import 'package:resonance/screens/youtube/youtube_search_screen.dart';
import 'package:resonance/widgets/youtube/youtube_artist_link.dart';

const artistProfile = YoutubeArtistProfile(
  id: 'UCQJ-a2IzCJ-gwlHvqvOWGhw',
  name: 'The Artist',
  description: 'An artist biography.',
);
const seedTrack = YoutubeTrack(
  title: 'Original song',
  artist: 'The Artist',
  url: 'https://www.youtube.com/watch?v=abcdefghijk',
);
YoutubeTrack song(int index) => YoutubeTrack(
  title: 'Song $index',
  artist: artistProfile.name,
  url: 'https://www.youtube.com/watch?v=song${index.toString().padLeft(7, '0')}',
  viewCount: 4200,
  likeCount: 250,
  durationSeconds: 123,
);
YoutubeArtistPage page(
  List<YoutubeTrack> tracks, {
  YoutubeArtistCursor? next,
  YoutubeArtistProfile artist = artistProfile,
}) => YoutubeArtistPage(artist: artist, tracks: tracks, next: next, availableSorts: YoutubeArtistSort.values.toSet());
Widget app(Widget child, {bool arabic = false, double scale = 1}) => MaterialApp(
  locale: Locale(arabic ? 'ar' : 'en'),
  supportedLocales: AppStrings.supportedLocales,
  localizationsDelegates: const [
    AppStrings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

void main() {
  testWidgets('a second selection supersedes loading and ignores the first selection failure', (tester) async {
    final first = Completer<void>();
    final second = Completer<void>();
    final selections = <String>[];
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(
        YoutubeArtistScreen(
          seed: seedTrack,
          loader: (_, __) async => page([song(1), song(2)]),
          onPlay: (track, _) {
            selections.add(track.title);
            return track.title == 'Song 1' ? first.future : second.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song 1'));
    await tester.pump();
    await tester.tap(find.text('Song 2'));
    await tester.pump();
    expect(selections, ['Song 1', 'Song 2']);
    first.completeError(StateError('Obsolete selection'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    second.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist browsing and slow stats never trigger playback; selecting passes current order', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final stats = Completer<YoutubeTrack>();
    final selected = <YoutubeTrack>[];
    final queues = <List<YoutubeTrack>>[];
    final first = const YoutubeTrack(
      title: 'Ready to play',
      artist: 'The Artist',
      url: 'https://www.youtube.com/watch?v=abcdefghijk',
      viewCount: 10000,
    );
    await tester.pumpWidget(
      app(
        YoutubeArtistScreen(
          seed: seedTrack,
          loader: (_, __) async => page([first, song(2)]),
          statsLoader: (_) => stats.future,
          onPlay: (track, queue) async {
            selected.add(track);
            queues.add(queue);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.text('Ready to play'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('artist-track-abcdefghijk')));
    await tester.pump();
    expect(selected.single, first);
    expect(queues.single.map((track) => track.title), ['Ready to play', 'Song 2']);
    stats.complete(first.copyWith(likeCount: 123));
    await tester.pumpAndSettle();
    expect(find.text('123'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pagination waits for real scrolling, deduplicates songs and keeps the queue order', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final calls = <String?>[];
    await tester.pumpWidget(
      app(
        YoutubeArtistScreen(
          seed: seedTrack,
          loader: (_, cursor) async {
            calls.add(cursor?.token);
            return cursor == null
                ? page(
                    List.generate(16, song),
                    next: const YoutubeArtistCursor(token: 'next', context: {}),
                  )
                : page([song(15), song(16), song(17)]);
          },
          onPlay: (_, __) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 8));
    expect(calls, [null]);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(calls, [null, 'next']);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.text('Song 17'), findsOneWidget);
    expect(find.text('Song 15'), findsOneWidget);
    expect(calls, hasLength(2));
  });

  testWidgets('changing sort rejects a late first-page response and uses the selected server order', (tester) async {
    final late = Completer<YoutubeArtistPage>();
    final requests = <YoutubeArtistSort>[];
    List<YoutubeTrack>? queue;
    await tester.pumpWidget(
      app(
        YoutubeArtistScreen(
          seed: seedTrack,
          loader: (sort, _) {
            requests.add(sort);
            return sort == YoutubeArtistSort.newest ? late.future : Future.value(page([song(9), song(1)]));
          },
          onPlay: (_, tracks) async => queue = tracks,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('artist-sort-popular')));
    await tester.pumpAndSettle();
    expect(requests, [YoutubeArtistSort.newest, YoutubeArtistSort.popular]);
    late.complete(page([song(0)]));
    await tester.pumpAndSettle();
    expect(find.text('Song 0'), findsNothing);
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(queue!.map((track) => track.title), ['Song 9', 'Song 1']);
  });

  testWidgets('initial failure can retry; empty artists have a deliberate empty state', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      app(
        YoutubeArtistScreen(
          seed: seedTrack,
          loader: (_, __) async {
            if (++calls == 1) throw StateError('Offline');
            return page([]);
          },
          onPlay: (_, __) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load this artist.'), findsOneWidget);
    await tester.ensureVisible(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('This artist has no public songs.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 800), const Size(1280, 900)]) {
    testWidgets('Arabic artist layout at ${size.width} supports long names and enlarged text', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const longArtist = YoutubeArtistProfile(
        id: 'UCQJ-a2IzCJ-gwlHvqvOWGhw',
        name: 'فنان باسم طويل جدًا مع تفاصيل إضافية',
        description: 'سيرة الفنان وأعماله الموسيقية مع وصف طويل يمتد على عدة أسطر.',
      );
      await tester.pumpWidget(
        app(
          YoutubeArtistScreen(
            seed: seedTrack,
            loader: (_, __) async => page([song(1), song(2)], artist: longArtist),
            onPlay: (_, __) async {},
          ),
          arabic: true,
          scale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('الأحدث'), findsOneWidget);
      expect(find.text('الأقدم'), findsOneWidget);
      expect(find.text('الأكثر رواجًا'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('Song 1'), findsOneWidget);
      expect(Directionality.of(tester.element(find.text('Song 1'))), TextDirection.rtl);
      expect(tester.takeException(), isNull);
    });
  }

  for (final shelfTitle in ['Quick picks', 'New releases']) {
    testWidgets('Discover $shelfTitle artist tap opens the artist instead of playing its parent card', (tester) async {
      await tester.pumpWidget(
        app(
          YoutubeSearchScreen(
            playlistNumber: 1,
            playlistName: 'Library',
            embedded: true,
            startOnMusicHome: true,
            youtubeMusicHomeLoader: () async => YoutubeMusicHome(
              shelves: [
                YoutubeMusicHomeShelf(title: shelfTitle, tracks: const [seedTrack]),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('The Artist'));
      await tester.pumpAndSettle();
      expect(find.byType(YoutubeArtistScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('standalone stream metadata author opens a page; local artists remain plain metadata', (tester) async {
    await tester.pumpWidget(
      app(
        Scaffold(
          body: StandaloneMetadata(
            item: const MediaItem(
              id: 'https://www.youtube.com/watch?v=abcdefghijk',
              title: 'Song',
              artist: 'The Artist',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final link = tester.widget<YoutubeArtistLink>(find.byType(YoutubeArtistLink));
    expect(link.returnToPlayer, isTrue);
    await tester.tap(find.text('The Artist'));
    await tester.pumpAndSettle();
    expect(find.byType(YoutubeArtistScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      app(
        Scaffold(
          body: StandaloneMetadata(
            item: const MediaItem(id: 'C:/songs/local.mp3', title: 'Local', artist: 'Local artist'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local artist'));
    await tester.pumpAndSettle();
    expect(find.byType(YoutubeArtistScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
