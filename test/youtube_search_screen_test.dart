import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/screens/youtube/youtube_search_screen.dart';
import 'package:resonance/services/suggested_music_service.dart';

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
}
