import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/youtube_transfer_service.dart';

enum YoutubePlaylistImportMode { download, stream }

extension YoutubePlaylistImportModeLabel on YoutubePlaylistImportMode {
  String get label => switch (this) {
    YoutubePlaylistImportMode.download => 'Download',
    YoutubePlaylistImportMode.stream => 'Stream',
  };
}

class YoutubePlaylistImportEntry {
  final String videoId;
  final String title;
  final String artist;

  const YoutubePlaylistImportEntry({required this.videoId, required this.title, required this.artist});

  YoutubeSearchCandidate asCandidate() => YoutubeSearchCandidate(
    title: title,
    uploader: artist,
    url: TrackSourceRepository.canonicalUrlFor(videoId),
    videoId: videoId,
  );
}

class YoutubePlaylistImportProgress {
  final int completed;
  final int total;
  final YoutubePlaylistImportEntry entry;
  final double percentage;
  final String status;

  const YoutubePlaylistImportProgress({
    required this.completed,
    required this.total,
    required this.entry,
    required this.percentage,
    required this.status,
  });
}

class YoutubePlaylistImportResult {
  final int playlistNumber;
  final String playlistName;
  final int playlistEntries;
  final int downloaded;
  final int reusedLocally;
  final int streamed;
  final int skippedEntries;
  final Map<String, String> failures;
  final bool cancelled;

  const YoutubePlaylistImportResult({
    required this.playlistNumber,
    required this.playlistName,
    required this.playlistEntries,
    required this.downloaded,
    required this.reusedLocally,
    required this.streamed,
    required this.skippedEntries,
    required this.failures,
    required this.cancelled,
  });
}

class YoutubePlaylistImportService {
  final YoutubeTransferService youtube;
  final TrackSourceRepository sourceRepository;
  final FileService fileService;

  YoutubePlaylistImportService({
    YoutubeTransferService? youtube,
    TrackSourceRepository? sourceRepository,
    FileService? fileService,
  }) : youtube = youtube ?? YoutubeTransferService(),
       sourceRepository = sourceRepository ?? const TrackSourceRepository(),
       fileService = fileService ?? FileService();

  Future<YoutubePlaylistImportResult> importPlaylist({
    required String playlistName,
    required List<YoutubePlaylistImportEntry> entries,
    required YoutubePlaylistImportMode mode,
    void Function(YoutubePlaylistImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (entries.isEmpty) throw StateError('Select at least one YouTube result before importing.');

    final unique = <String, YoutubePlaylistImportEntry>{};
    for (final entry in entries) {
      if (!TrackSourceRepository.isValidYoutubeVideoId(entry.videoId)) continue;
      unique.putIfAbsent(entry.videoId, () => entry);
    }
    if (unique.isEmpty) throw StateError('The selected results do not contain valid YouTube video IDs.');

    final resolvedById = <String, String>{};
    final failures = <String, String>{};
    var downloaded = 0;
    var reused = 0;
    var streamed = 0;
    var cancelled = false;
    final uniqueEntries = unique.values.toList(growable: false);

    for (var index = 0; index < uniqueEntries.length; index++) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final entry = uniqueEntries[index];
      void report(double percentage, String status) => onProgress?.call(
        YoutubePlaylistImportProgress(
          completed: index,
          total: uniqueEntries.length,
          entry: entry,
          percentage: percentage,
          status: status,
        ),
      );

      try {
        if (mode == YoutubePlaylistImportMode.stream) {
          report(0, 'Adding stream metadata…');
          final url = TrackSourceRepository.canonicalUrlFor(entry.videoId);
          try {
            await youtube.rememberStream(entry.asCandidate());
          } catch (_) {
            // Metadata cache failure should not prevent a playable URL from
            // being added to the playlist.
          }
          resolvedById[entry.videoId] = url;
          streamed++;
          report(100, 'Stream ready');
        } else {
          report(0, 'Checking local downloads…');
          final existing = await sourceRepository.findLocalTrackByYoutubeId(entry.videoId);
          if (existing != null) {
            resolvedById[entry.videoId] = existing;
            reused++;
            report(100, 'Using existing local track');
          } else {
            final result = await youtube.downloadVideo(
              entry.videoId,
              sourceMethod: TrackSourceMethod.importedFromExternalPlaylist,
              onProgress: report,
            );
            resolvedById[entry.videoId] = result.localPath;
            downloaded++;
          }
        }
      } catch (error) {
        failures[entry.videoId] = error.toString();
      }
      onProgress?.call(
        YoutubePlaylistImportProgress(
          completed: index + 1,
          total: uniqueEntries.length,
          entry: entry,
          percentage: 100,
          status: failures.containsKey(entry.videoId) ? 'Failed' : 'Ready',
        ),
      );
    }

    final orderedTracks = <String>[
      for (final entry in entries)
        if (resolvedById[entry.videoId] case final String path) path,
    ];
    if (orderedTracks.isEmpty) {
      throw StateError(cancelled ? 'Import stopped before any tracks were ready.' : 'No tracks could be prepared.');
    }

    final created = await fileService.createImportedPlaylist(playlistName, orderedTracks);
    return YoutubePlaylistImportResult(
      playlistNumber: created.number,
      playlistName: created.displayName,
      playlistEntries: orderedTracks.length,
      downloaded: downloaded,
      reusedLocally: reused,
      streamed: streamed,
      skippedEntries: entries.length - orderedTracks.length,
      failures: Map.unmodifiable(failures),
      cancelled: cancelled,
    );
  }
}
