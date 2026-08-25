import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/core/youtube/youtube_music_home_models.dart';
import 'package:resonance/screens/youtube/youtube_search_screen.dart';
import 'package:resonance/services/suggested_music_service.dart';
import 'package:resonance/services/download/download_queue_controller.dart';

void main() {
  testWidgets('shows a two-result preview after idle and full results on submit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requests = <({String query, int limit})>[];
    final preview = Completer<List<YoutubeTrack>>();
    final tracks = List.generate(
      4,
      (index) => YoutubeTrack(
        title: 'Track ${index + 1}',
        artist: 'Artist',
        url: 'https://www.youtube.com/watch?v=track00000$index',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist 1',
          initialQuery: 'seed',
          previewDelay: const Duration(milliseconds: 200),
          searchLoader: (query, limit) async {
            requests.add((query: query, limit: limit));
            if (query == 'lady gaga' && limit == 2) return preview.future;
            return tracks;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    requests.clear();

    final field = find.byKey(const Key('youtube-search-field'));
    await tester.tap(field);
    await tester.enterText(field, 'lady gaga');
    await tester.pump(const Duration(milliseconds: 199));
    expect(requests, isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(requests, [(query: 'lady gaga', limit: 2)]);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('preview', findRichText: true), findsNothing);

    preview.complete(tracks);
    await tester.pump();
    expect(find.text('Track 1'), findsOneWidget);
    expect(find.text('Track 2'), findsOneWidget);
    expect(find.text('Track 3'), findsNothing);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(requests, [(query: 'lady gaga', limit: 2), (query: 'lady gaga', limit: 10)]);
    expect(find.text('Track 3'), findsOneWidget);
  });

  testWidgets('tapping outside the search field dismisses its focus', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist 1',
          initialQuery: 'seed',
          searchLoader: (_, __) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('youtube-search-field'));
    await tester.tap(field);
    await tester.pump();
    final focusNode = tester.widget<EditableText>(find.byType(EditableText)).focusNode;
    expect(focusNode.hasFocus, isTrue);

    await tester.tapAt(const Offset(8, 300));
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
  });

  testWidgets('restarts suggestions after a search cancels an in-flight load', (tester) async {
    final requests = <Completer<SuggestedMusicResult>>[];
    const profile = PlaylistProfile(
      playlistNumber: 1,
      playlistName: 'Playlist 1',
      fingerprint: 'profile',
      tracks: [PlaylistProfileTrack(path: 'seed.mp3', title: 'Seed', artist: 'Artist')],
      artistWeights: {'artist': 1},
      tokenWeights: {'seed': 1},
      variantTokens: {},
    );
    const suggestion = YoutubeTrack(
      title: 'Suggested Track',
      artist: 'Suggested Artist',
      url: 'https://www.youtube.com/watch?v=suggested01',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist 1',
          searchLoader: (_, __) async => const [],
          suggestionsLoader: ({required bool refresh, required bool Function() isCancelled}) {
            final request = Completer<SuggestedMusicResult>();
            requests.add(request);
            return request.future;
          },
        ),
      ),
    );
    await tester.pump();
    expect(requests, hasLength(1));
    expect(find.text('Finding Suggested Music'), findsOneWidget);

    final field = find.byKey(const Key('youtube-search-field'));
    await tester.enterText(field, 'query');
    await tester.pump();
    expect(find.text('Finding Suggested Music'), findsNothing);

    await tester.enterText(field, '');
    await tester.pump();
    expect(requests, hasLength(2));

    requests[1].complete(const SuggestedMusicResult(profile: profile, tracks: [suggestion], fromCache: false));
    await tester.pump();
    expect(find.text('Suggested Music'), findsOneWidget);
    expect(find.text('Suggested Track'), findsOneWidget);

    requests[0].complete(const SuggestedMusicResult(profile: profile, tracks: [], fromCache: false));
    await tester.pump();
    expect(find.text('Suggested Track'), findsOneWidget);
  });

  testWidgets('suggestions page keeps the source switch above the content', (tester) async {
    const emptyProfile = PlaylistProfile(
      playlistNumber: 1,
      playlistName: 'Playlist 1',
      fingerprint: 'empty',
      tracks: [],
      artistWeights: {},
      tokenWeights: {},
      variantTokens: {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist 1',
          searchLoader: (_, __) async => const [],
          suggestionsLoader: ({required bool refresh, required bool Function() isCancelled}) async =>
              const SuggestedMusicResult(profile: emptyProfile, tracks: [], fromCache: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('suggestions-mode-switcher')), findsOneWidget);
    expect(find.text('Resonance Suggestions'), findsOneWidget);
    expect(find.text('YouTube Music Home'), findsOneWidget);

    await tester.tap(find.text('YouTube Music Home'));
    await tester.pumpAndSettle();
    expect(find.text('Connect YouTube access'), findsOneWidget);
  });

  testWidgets('YouTube Music Home renders compact picks and collection shelves', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const emptyProfile = PlaylistProfile(
      playlistNumber: 1,
      playlistName: 'Playlist 1',
      fingerprint: 'empty-home-test',
      tracks: [],
      artistWeights: {},
      tokenWeights: {},
      variantTokens: {},
    );
    const pick = YoutubeTrack(
      title: 'Playable pick',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=homepick001',
    );
    const home = YoutubeMusicHome(
      shelves: [
        YoutubeMusicHomeShelf(title: 'Quick picks', tracks: [pick]),
        YoutubeMusicHomeShelf(
          title: 'New releases',
          tracks: [],
          items: [
            YoutubeMusicHomeItem(
              title: 'Collection album',
              subtitle: 'Album artist',
              kind: 'Album',
              playlistId: 'OLAK5uy_collection',
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist 1',
          searchLoader: (_, __) async => const [],
          suggestionsLoader: ({required bool refresh, required bool Function() isCancelled}) async =>
              const SuggestedMusicResult(profile: emptyProfile, tracks: [], fromCache: false),
          youtubeMusicHomeLoader: () async => home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('YouTube Music Home'));
    await tester.pumpAndSettle();

    expect(find.text('Your YouTube Music'), findsOneWidget);
    expect(find.text('Quick picks'), findsOneWidget);
    expect(find.text('Playable pick'), findsOneWidget);
    expect(find.text('New releases'), findsOneWidget);
    expect(find.text('Collection album'), findsOneWidget);
    final collectionInk = tester.widget<InkWell>(find.byKey(const ValueKey('youtube-home-card-Collection album')));
    expect(collectionInk.onTap, isNotNull);
    await tester.tap(find.byTooltip('Playlist actions'));
    await tester.pumpAndSettle();
    expect(find.text('Stream playlist'), findsOneWidget);
    expect(find.text('Download playlist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows Home shelves support mouse grab-drag and right-scroll controls', (tester) async {
    if (!Platform.isWindows) return;
    await tester.binding.setSurfaceSize(const Size(760, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const emptyProfile = PlaylistProfile(
      playlistNumber: 1,
      playlistName: 'Playlist 1',
      fingerprint: 'desktop-scroll-test',
      tracks: [],
      artistWeights: {},
      tokenWeights: {},
      variantTokens: {},
    );
    final home = YoutubeMusicHome(
      shelves: [
        YoutubeMusicHomeShelf(
          title: 'Made for you',
          tracks: const [],
          items: List.generate(
            12,
            (index) => YoutubeMusicHomeItem(
              title: 'Collection $index',
              subtitle: 'Artist',
              kind: 'Playlist',
              playlistId: 'PLcollection$index',
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist 1',
          searchLoader: (_, __) async => const [],
          suggestionsLoader: ({required bool refresh, required bool Function() isCancelled}) async =>
              const SuggestedMusicResult(profile: emptyProfile, tracks: [], fromCache: false),
          youtubeMusicHomeLoader: () async => home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('YouTube Music Home'));
    await tester.pumpAndSettle();

    final horizontal = find.byWidgetPredicate(
      (widget) => widget is Scrollable && widget.axisDirection == AxisDirection.right && widget.restorationId == null,
    );
    expect(horizontal, findsOneWidget);
    final position = tester.state<ScrollableState>(horizontal).position;
    expect(position.pixels, 0);
    final shelfCenter = tester.getCenter(horizontal);
    final mouse = await tester.startGesture(shelfCenter, kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(-40, 0));
    await mouse.moveBy(const Offset(-240, 0));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(PointerScrollEvent(position: shelfCenter, scrollDelta: const Offset(0, 180)));
    await tester.pumpAndSettle();
    expect(position.pixels, 0, reason: 'The vertical mouse wheel must not drive a horizontal shelf.');
    final enabledRight = find.byWidgetPredicate(
      (widget) =>
          widget is IconButton && widget.key == const Key('youtube-shelf-scroll-right') && widget.onPressed != null,
    );
    expect(enabledRight, findsOneWidget);
    await tester.tap(enabledRight);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('disabled queue mode never renders the Windows queue panel', (tester) async {
    if (!Platform.isWindows) return;
    final queue = DownloadQueueController.instance;
    queue.setQueueMode(false);
    addTearDown(() => queue.setQueueMode(false));
    const track = YoutubeTrack(
      title: 'Visible result',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=queuepanel1',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist 1',
          initialQuery: 'result',
          searchLoader: (_, __) async => const [track],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Download queue'), findsNothing);

    await tester.tap(find.byKey(const Key('download-queue-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Download queue'), findsOneWidget);

    await tester.tap(find.byKey(const Key('download-queue-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Download queue'), findsNothing);
  });
}
