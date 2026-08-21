import 'dart:io';

import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/youtube_transfer_service.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';

class UnresolvedPlaylistTrack {
  final String localPath;
  final String title;
  final String artist;
  final int occurrenceCount;
  final int? durationSeconds;

  const UnresolvedPlaylistTrack({
    required this.localPath,
    required this.title,
    required this.artist,
    required this.occurrenceCount,
    this.durationSeconds,
  });

  String get searchQuery => artist == 'Unknown Artist' ? title : '$artist $title';

  String get formattedDuration {
    final duration = durationSeconds;
    if (duration == null || duration < 0) return '';
    final hours = duration ~/ 3600;
    final minutes = (duration % 3600) ~/ 60;
    final seconds = duration % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}'
        : '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
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

class PlaylistSourceMatch {
  final UnresolvedPlaylistTrack track;
  String query;
  List<YoutubeSearchCandidate> candidates;
  YoutubeSearchCandidate? selected;
  String? error;
  bool skipped;
  bool manuallyChanged;

  PlaylistSourceMatch({
    required this.track,
    required this.query,
    this.candidates = const [],
    this.selected,
    this.error,
    this.skipped = false,
    this.manuallyChanged = false,
  });
}

class PlaylistSourceMatchingCancelled implements Exception {
  const PlaylistSourceMatchingCancelled();
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

  Future<List<PlaylistSourceMatch>> findAutomaticMatches(
    PlaylistSourceScan scan,
    Future<List<YoutubeSearchCandidate>> Function(String query) search, {
    void Function(int completed, int total, UnresolvedPlaylistTrack track)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final matches = <PlaylistSourceMatch>[];
    for (var index = 0; index < scan.unresolved.length; index++) {
      if (isCancelled?.call() ?? false) throw const PlaylistSourceMatchingCancelled();
      final track = scan.unresolved[index];
      onProgress?.call(index, scan.unresolved.length, track);
      final match = PlaylistSourceMatch(track: track, query: track.searchQuery);
      try {
        final candidates = await search(match.query);
        match.candidates = List.unmodifiable(candidates);
        match.selected = candidates.firstOrNull;
        if (candidates.isEmpty) match.error = 'No YouTube results found.';
      } catch (error) {
        if (error is YoutubeFailure && error.isAccessFailure) rethrow;
        match.error = 'Search failed: $error';
      }
      matches.add(match);
      onProgress?.call(index + 1, scan.unresolved.length, track);
    }
    return matches;
  }

  Future<void> commitMatches(PlaylistSourceScan scan, Iterable<PlaylistSourceMatch> matches) async {
    for (final match in matches) {
      final selected = match.selected;
      if (match.skipped || selected == null) {
        scan.resolvedByPath.remove(match.track.localPath);
        continue;
      }
      await sourceRepository.saveSource(
        localPath: match.track.localPath,
        youtubeVideoId: selected.videoId,
        method: match.manuallyChanged ? TrackSourceMethod.manuallySelected : TrackSourceMethod.matchedDuringTransfer,
      );
      scan.resolvedByPath[match.track.localPath] = selected.videoId;
    }
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
