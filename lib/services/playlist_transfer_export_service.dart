import 'dart:io';

import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/track_source_repository.dart';

class UnresolvedPlaylistTrack {
  final String localPath;
  final String title;
  final String artist;
  final int occurrenceCount;

  const UnresolvedPlaylistTrack({
    required this.localPath,
    required this.title,
    required this.artist,
    required this.occurrenceCount,
  });

  String get searchQuery => artist == 'Unknown Artist' ? title : '$artist $title';
}

class PlaylistSourceScan {
  final String playlistName;
  final List<String> playlistTracks;
  final Map<String, String> resolvedByPath;
  final List<UnresolvedPlaylistTrack> unresolved;

  const PlaylistSourceScan({
    required this.playlistName,
    required this.playlistTracks,
    required this.resolvedByPath,
    required this.unresolved,
  });

  List<String> get resolvedVideoIds => [
    for (final path in playlistTracks)
      if (resolvedByPath[path] case final String videoId) videoId,
  ];

  int get skippedEntryCount => playlistTracks.length - resolvedVideoIds.length;

  PlaylistTransferManifest createManifest() =>
      PlaylistTransferManifest(playlistName: playlistName, youtubeVideoIds: resolvedVideoIds);
}

class PlaylistTransferExportService {
  final TrackSourceRepository sourceRepository;

  const PlaylistTransferExportService({this.sourceRepository = const TrackSourceRepository()});

  Future<PlaylistSourceScan> scanPlaylist(String playlistName, List<String> tracks) async {
    final resolved = <String, String>{};
    final unresolved = <UnresolvedPlaylistTrack>[];
    final counts = <String, int>{};
    for (final path in tracks) {
      counts[path] = (counts[path] ?? 0) + 1;
    }
    for (final path in counts.keys) {
      final saved = await sourceRepository.getSourceForTrack(path);
      if (saved != null && TrackSourceRepository.isValidYoutubeVideoId(saved.youtubeVideoId)) {
        resolved[path] = saved.youtubeVideoId;
        continue;
      }
      final embeddedVideoId = TrackSourceRepository.videoIdFromUrlOrId(path);
      if (embeddedVideoId != null) {
        resolved[path] = embeddedVideoId;
        await sourceRepository.saveSource(
          localPath: path,
          youtubeVideoId: embeddedVideoId,
          method: TrackSourceMethod.matchedDuringTransfer,
        );
        continue;
      }
      final metadata = await _metadataFor(path);
      unresolved.add(
        UnresolvedPlaylistTrack(
          localPath: path,
          title: metadata.title,
          artist: metadata.artist,
          occurrenceCount: counts[path]!,
        ),
      );
    }
    return PlaylistSourceScan(
      playlistName: playlistName,
      playlistTracks: List.unmodifiable(tracks),
      resolvedByPath: resolved,
      unresolved: unresolved,
    );
  }

  Future<({String title, String artist})> _metadataFor(String path) async {
    final cached = await MetadataCacheService.get(path);
    if (cached != null) return (title: cached.title, artist: cached.artist);
    if (!path.startsWith('http://') && !path.startsWith('https://')) {
      try {
        final metadata = await AudioMetadata.extract(File(path));
        final filename = p.basenameWithoutExtension(path);
        final title = (metadata?.trackName?.trim().isNotEmpty ?? false) ? metadata!.trackName!.trim() : filename;
        final artist = (metadata?.firstArtists?.trim().isNotEmpty ?? false)
            ? metadata!.firstArtists!.trim()
            : 'Unknown Artist';
        return (title: title, artist: artist);
      } catch (_) {}
    }
    final filename = p.basenameWithoutExtension(path).trim();
    return (title: filename.isEmpty ? 'Unknown Track' : filename, artist: 'Unknown Artist');
  }
}
