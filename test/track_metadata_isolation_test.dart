import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/widgets/library/track_list.dart';
import 'package:resonance/widgets/library/track_tile.dart';

void main() {
  testWidgets('track row keys are scoped to their owning playlist', (tester) async {
    final requestedKeys = <({int playlistNumber, int index})>[];
    final keys = <({int playlistNumber, int index}), GlobalKey>{};

    await tester.pumpWidget(
      Provider<PlayerHandler>.value(
        value: _FakePlayerHandler(),
        child: MaterialApp(
          home: Scaffold(
            body: TrackList(
              tracks: const [
                'https://www.youtube.com/watch?v=aaaaaaaaaaa',
                'https://www.youtube.com/watch?v=bbbbbbbbbbb',
              ],
              playlistNumber: 7,
              onTrackDeleted: (_, __) {},
              onTrackDeletedEverywhere: (_) {},
              onReorder: (_, __) {},
              controller: ScrollController(),
              pulsingTrackIndex: null,
              pulse: 0,
              artworkRevision: 0,
              itemKeyForIndex: (playlistNumber, index) {
                final scope = (playlistNumber: playlistNumber, index: index);
                requestedKeys.add(scope);
                return keys.putIfAbsent(scope, GlobalKey.new);
              },
            ),
          ),
        ),
      ),
    );

    expect(requestedKeys, containsAll([(playlistNumber: 7, index: 0), (playlistNumber: 7, index: 1)]));
    expect(keys.length, 2);
  });

  testWidgets('a completed metadata read cannot overwrite a row which moved to another track', (tester) async {
    const firstPath = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';
    const secondPath = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';
    final firstMetadata = Completer<CachedTrackMetadata?>();
    final secondMetadata = Completer<CachedTrackMetadata?>();
    final handler = _FakePlayerHandler();
    final tileKey = GlobalKey();

    Future<CachedTrackMetadata?> loadMetadata(String path) => switch (path) {
      firstPath => firstMetadata.future,
      secondPath => secondMetadata.future,
      _ => Future.value(null),
    };

    Widget buildTile(String path) => Provider<PlayerHandler>.value(
      value: handler,
      child: MaterialApp(
        home: Scaffold(
          body: TrackTile(
            key: tileKey,
            trackPath: path,
            playlistNumber: 1,
            index: 0,
            onDelete: () {},
            onDeleteEverywhere: () {},
            metadataLoader: loadMetadata,
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildTile(firstPath));
    await tester.pumpWidget(buildTile(secondPath));

    secondMetadata.complete(const CachedTrackMetadata(title: 'Second title', artist: 'Second artist'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Second title'), findsOneWidget);

    firstMetadata.complete(const CachedTrackMetadata(title: 'First title', artist: 'First artist'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Second title'), findsOneWidget);
    expect(find.text('First title'), findsNothing);
  });
}

class _FakePlayerHandler implements PlayerHandler {
  @override
  final ValueNotifier<PlaybackVisualState> playbackVisualNotifier = ValueNotifier(const PlaybackVisualState());

  @override
  final ValueNotifier<int> playbackModeRevision = ValueNotifier(0);

  @override
  bool getShuffleMode() => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
