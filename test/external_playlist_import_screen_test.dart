import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/screens/external_playlist/external_playlist_import_screen.dart';
import 'package:resonance/services/external_playlist_service.dart';

void main() {
  testWidgets('YouTube playlists skip approximate matching and offer exact entries for import', (tester) async {
    final provider = YoutubePlaylistProvider(
      fetchJson: (_) async => jsonEncode({
        'title': 'Exact Playlist',
        'entries': [
          {'id': 'aaaaaaaaaaa', 'title': 'First', 'uploader': 'Artist A'},
          {'id': 'aaaaaaaaaaa', 'title': 'First', 'uploader': 'Artist A'},
          {'id': 'bbbbbbbbbbb', 'title': 'Last', 'uploader': 'Artist B'},
        ],
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ExternalPlaylistImportScreen(
          playlistService: ExternalPlaylistService(providers: [provider]),
          initialUrl: 'https://music.youtube.com/playlist?list=PLtest',
        ),
      ),
    );

    expect(find.text('Cross-Website Playlist Import'), findsOneWidget);
    await tester.tap(find.text('Find Tracks'));
    await tester.pumpAndSettle();

    expect(find.text('Import “Exact Playlist”'), findsOneWidget);
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('3'), findsNWidgets(2));
    expect(find.text('Download Tracks'), findsOneWidget);
    expect(find.text('Stream From Playlist'), findsOneWidget);
  });
}
