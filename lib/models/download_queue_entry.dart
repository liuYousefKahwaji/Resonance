import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';

enum DownloadQueueStatus { queued, downloading, completed, failed }

class DownloadQueueEntry {
  final String id;
  final YoutubeTrack track;
  final int playlistNumber;
  final bool replaceStream;
  final DownloadQueueStatus status;
  final double progress;
  final String statusText;
  final String? localPath;
  final String? error;
  final YoutubeFailureKind? failureKind;

  const DownloadQueueEntry({
    required this.id,
    required this.track,
    required this.playlistNumber,
    this.replaceStream = false,
    this.status = DownloadQueueStatus.queued,
    this.progress = 0,
    this.statusText = 'Waiting',
    this.localPath,
    this.error,
    this.failureKind,
  });

  DownloadQueueEntry copyWith({
    DownloadQueueStatus? status,
    double? progress,
    String? statusText,
    String? localPath,
    String? error,
    YoutubeFailureKind? failureKind,
  }) => DownloadQueueEntry(
    id: id,
    track: track,
    playlistNumber: playlistNumber,
    replaceStream: replaceStream,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    statusText: statusText ?? this.statusText,
    localPath: localPath ?? this.localPath,
    error: error ?? this.error,
    failureKind: failureKind ?? this.failureKind,
  );
}
