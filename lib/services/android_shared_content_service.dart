import 'package:resonance/services/external_playlist_service.dart';

enum AndroidSharedContentKind { search, playlist }

class AndroidSharedContent {
  final AndroidSharedContentKind kind;
  final String value;

  const AndroidSharedContent({required this.kind, required this.value});
}

/// Routes Android ACTION_SEND text into the same search and cross-provider
/// playlist flows used by the in-app toolbar.
class AndroidSharedContentService {
  final ExternalPlaylistService _playlists;
  final Future<ExternalTrackMetadata> Function(Uri uri) _trackMetadata;

  AndroidSharedContentService({
    ExternalPlaylistService? playlists,
    Future<ExternalTrackMetadata> Function(Uri uri)? trackMetadata,
  }) : _playlists = playlists ?? ExternalPlaylistService(),
       _trackMetadata = trackMetadata ?? ExternalTrackMetadataService().fetch;

  Future<AndroidSharedContent> resolve(String sharedText) async {
    final text = sharedText.trim();
    if (text.isEmpty) throw const ExternalPlaylistException('Nothing was shared with Resonance.');
    final link = _firstWebLink(text);
    if (link == null) return AndroidSharedContent(kind: AndroidSharedContentKind.search, value: text);

    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) {
      return AndroidSharedContent(kind: AndroidSharedContentKind.search, value: text);
    }
    if (_playlists.providers.any((provider) => provider.supports(uri))) {
      return AndroidSharedContent(kind: AndroidSharedContentKind.playlist, value: link);
    }

    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final isYoutube =
        host == 'youtube.com' || host == 'music.youtube.com' || host == 'm.youtube.com' || host == 'youtu.be';
    if (isYoutube) return AndroidSharedContent(kind: AndroidSharedContentKind.search, value: link);

    final isExternalTrack = host == 'open.spotify.com' || host == 'audiomack.com' || host.endsWith('.audiomack.com');
    if (isExternalTrack) {
      final metadata = await _trackMetadata(uri);
      return AndroidSharedContent(kind: AndroidSharedContentKind.search, value: metadata.searchQuery);
    }

    return AndroidSharedContent(kind: AndroidSharedContentKind.search, value: link);
  }

  static String? _firstWebLink(String text) {
    final match = RegExp(r'https?://[^\s<>]+', caseSensitive: false).firstMatch(text);
    return match?.group(0)?.replaceFirst(RegExp(r'''[),.;!?\]}]+$'''), '');
  }
}
