import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/android_shared_content_service.dart';
import 'package:resonance/services/external_playlist_service.dart';

void main() {
  test('routes shared YouTube playlists to the existing playlist importer', () async {
    final result = await AndroidSharedContentService().resolve(
      'Try this playlist https://music.youtube.com/playlist?list=PL123',
    );

    expect(result.kind, AndroidSharedContentKind.playlist);
    expect(result.value, 'https://music.youtube.com/playlist?list=PL123');
  });

  test('keeps YouTube tracks as links for the existing search flow', () async {
    final result = await AndroidSharedContentService().resolve('https://youtu.be/dQw4w9WgXcQ');

    expect(result.kind, AndroidSharedContentKind.search);
    expect(result.value, 'https://youtu.be/dQw4w9WgXcQ');
  });

  test('turns shared Spotify tracks into title and artist searches', () async {
    final result = await AndroidSharedContentService(
      trackMetadata: (_) async => const ExternalTrackMetadata(title: 'Judas', artist: 'Lady Gaga'),
    ).resolve('Judas https://open.spotify.com/track/1234567890123456789012');

    expect(result.kind, AndroidSharedContentKind.search);
    expect(result.value, 'Lady Gaga Judas');
  });

  test('treats ordinary shared text as a search', () async {
    final result = await AndroidSharedContentService().resolve('Lady Gaga Judas live');

    expect(result.kind, AndroidSharedContentKind.search);
    expect(result.value, 'Lady Gaga Judas live');
  });

  test('parses Spotify Open Graph track metadata', () {
    final result = ExternalTrackMetadataService.parseHtml(
      '<meta property="og:title" content="Judas - song and lyrics by Lady Gaga | Spotify">',
      sourceUri: Uri.parse('https://open.spotify.com/track/example'),
    );

    expect(result.title, 'Judas');
    expect(result.artist, 'Lady Gaga');
  });

  test('parses Audiomack Open Graph track metadata', () {
    final result = ExternalTrackMetadataService.parseHtml(
      '<meta property="og:title" content="Judas by Lady Gaga: Listen on Audiomack">',
      sourceUri: Uri.parse('https://audiomack.com/artist/song/judas'),
    );

    expect(result.title, 'Judas');
    expect(result.artist, 'Lady Gaga');
  });

  test('prefers structured MusicRecording metadata', () {
    final result = ExternalTrackMetadataService.parseHtml(
      '<script type="application/ld+json">'
      '{"@type":"MusicRecording","name":"Judas","byArtist":{"name":"Lady Gaga"}}'
      '</script>',
      sourceUri: Uri.parse('https://open.spotify.com/track/example'),
    );

    expect(result.searchQuery, 'Lady Gaga Judas');
  });
}
