import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';

enum DownloadQueueStatus { queued, downloading, completed, failed, cancelled }

class DownloadQueueEntry {
  final String id;
  final YoutubeTrack track;
  final int playlistNumber;
  final bool replaceStream;
  final String? automaticKey;
  final int attempts;
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
    this.automaticKey,
    this.attempts = 0,
    this.status = DownloadQueueStatus.queued,
    this.progress = 0,
    this.statusText = 'Waiting',
    this.localPath,
    this.error,
    this.failureKind,
  });

  DownloadQueueEntry copyWith({
    DownloadQueueStatus? status,
    int? attempts,
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
    automaticKey: automaticKey,
    attempts: attempts ?? this.attempts,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    statusText: statusText ?? this.statusText,
    localPath: localPath ?? this.localPath,
    error: error ?? this.error,
    failureKind: failureKind ?? this.failureKind,
  );
}
