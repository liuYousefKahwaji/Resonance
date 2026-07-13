import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/external_playlist.dart';
import 'package:resonance/services/external_playlist_service.dart';

void main() {
  test('Spotify embed metadata preserves playlist order, artists, duplicates, and duration', () {
    final nextData = jsonEncode({
      'props': {
        'pageProps': {
          'state': {
            'data': {
              'entity': {
                'name': 'Night Drive',
                'trackList': [
                  {
                    'uri': 'spotify:track:first',
                    'title': 'First',
                    'subtitle': 'Artist A, Artist B',
                    'duration': 61000,
                    'entityType': 'track',
                  },
                  {
                    'uri': 'spotify:track:first',
                    'title': 'First',
                    'subtitle': 'Artist A, Artist B',
                    'duration': 61000,
                    'entityType': 'track',
                  },
                  {
                    'uri': 'spotify:track:last',
                    'title': 'Last',
                    'subtitle': 'Artist C',
                    'duration': 125000,
                    'entityType': 'track',
                  },
                ],
              },
            },
          },
        },
      },
    });

    final playlist = SpotifyPlaylistProvider.parseHtml(
      '<html><script id="__NEXT_DATA__" type="application/json">$nextData</script></html>',
      sourceUri: Uri.parse('https://open.spotify.com/playlist/1234567890123456789012'),
    );

    expect(playlist.kind, ExternalPlaylistKind.spotify);
    expect(playlist.name, 'Night Drive');
    expect(playlist.tracks.map((track) => track.title), ['First', 'First', 'Last']);
    expect(playlist.tracks.first.artists, ['Artist A', 'Artist B']);
    expect(playlist.tracks.last.duration, const Duration(minutes: 2, seconds: 5));
  });

  test('Audiomack RSC metadata preserves playlist order and second durations', () {
    final dataFrame = [
      r'$',
      'main',
      null,
      {
        'data': {
          'type': 'playlist',
          'title': 'Fresh Finds',
          'tracks': [
            {
              'id': '10',
              'type': 'song',
              'title': 'Opening Track',
              'artist': 'One Artist',
              'featuring': 'Guest Artist',
              'duration': '90',
            },
            {'id': '11', 'type': 'song', 'title': 'Closing Track', 'artist': 'Second Artist', 'duration': '205'},
          ],
        },
      },
    ];
    final flightChunk = 'c:${jsonEncode(dataFrame)}';
    final html = '<script>self.__next_f.push([1,${jsonEncode(flightChunk)}])</script>';

    final playlist = AudiomackPlaylistProvider.parseHtml(
      html,
      sourceUri: Uri.parse('https://audiomack.com/resonance/playlist/fresh-finds'),
    );

    expect(playlist.kind, ExternalPlaylistKind.audiomack);
    expect(playlist.name, 'Fresh Finds');
    expect(playlist.tracks.map((track) => track.title), ['Opening Track', 'Closing Track']);
    expect(playlist.tracks.first.artists, ['One Artist', 'Guest Artist']);
    expect(playlist.tracks.first.duration, const Duration(seconds: 90));
    expect(playlist.tracks.last.duration, const Duration(seconds: 205));
  });

  test('provider registry rejects unrelated URLs before making a request', () async {
    final service = ExternalPlaylistService();
    await expectLater(
      service.fetch('https://example.com/playlist/anything'),
      throwsA(isA<ExternalPlaylistException>()),
    );
  });
}
