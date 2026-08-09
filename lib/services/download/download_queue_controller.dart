import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:resonance/models/download_queue_entry.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/import_service.dart';
import 'package:resonance/services/lyrics_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/widgets/youtube/android_youtube.dart';
import 'package:resonance/widgets/youtube/windows_youtube.dart';

typedef DownloadTaskRunner =
    Future<String?> Function(DownloadQueueEntry entry, void Function(double progress, String status) onProgress);

/// Process-lifetime FIFO download coordinator. It deliberately lives above
/// Search routes so navigation and app backgrounding cannot dispose its worker.
class DownloadQueueController extends ChangeNotifier {
  final DownloadTaskRunner? _testRunner;

  DownloadQueueController._({DownloadTaskRunner? testRunner}) : _testRunner = testRunner;
  static final DownloadQueueController instance = DownloadQueueController._();

  @visibleForTesting
  DownloadQueueController.forTesting({required DownloadTaskRunner runner}) : _testRunner = runner;

  final MediaDownloader _windows = MediaDownloader();
  final AndroidYoutubeDownloader _android = AndroidYoutubeDownloader();
  final List<DownloadQueueEntry> _entries = [];
  final Map<String, Completer<String?>> _completions = {};
  bool _queueMode = false;
  bool _working = false;
  int _sequence = 0;

  List<DownloadQueueEntry> get entries => List.unmodifiable(_entries);
  bool get queueMode => _queueMode;
  bool get isWorking => _working;
  int get pendingCount => _entries
      .where((entry) => entry.status == DownloadQueueStatus.queued || entry.status == DownloadQueueStatus.downloading)
      .length;

  DownloadQueueEntry? pendingEntryFor(String url, int playlistNumber) => _entries
      .where(
        (entry) =>
            entry.track.url == url &&
            entry.playlistNumber == playlistNumber &&
            (entry.status == DownloadQueueStatus.queued || entry.status == DownloadQueueStatus.downloading),
      )
      .firstOrNull;

  void setQueueMode(bool value) {
    if (_queueMode == value) return;
    _queueMode = value;
    notifyListeners();
  }

  Future<String?> enqueue(YoutubeTrack track, int playlistNumber) {
    final existing = pendingEntryFor(track.url, playlistNumber);
    if (existing != null) {
      return _completions[existing.id]?.future ?? Future.value(existing.localPath);
    }
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final completion = Completer<String?>();
    _completions[id] = completion;
    _entries.add(DownloadQueueEntry(id: id, track: track, playlistNumber: playlistNumber));
    notifyListeners();
    unawaited(_drain());
    return completion.future;
  }

  void clearFinished() {
    _entries.removeWhere(
      (entry) => entry.status == DownloadQueueStatus.completed || entry.status == DownloadQueueStatus.failed,
    );
    notifyListeners();
  }

  Future<void> retry(String id) async {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || _entries[index].status != DownloadQueueStatus.failed) return;
    final old = _entries[index];
    _entries[index] = DownloadQueueEntry(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
      track: old.track,
      playlistNumber: old.playlistNumber,
    );
    notifyListeners();
    await _drain();
  }

  Future<void> _drain() async {
    if (_working) return;
    _working = true;
    notifyListeners();
    try {
      while (true) {
        final index = _entries.indexWhere((entry) => entry.status == DownloadQueueStatus.queued);
        if (index < 0) break;
        final entry = _entries[index];
        _entries[index] = entry.copyWith(status: DownloadQueueStatus.downloading, statusText: 'Starting…');
        notifyListeners();
        try {
          void progressCallback(double progress, String status) {
            final liveIndex = _entries.indexWhere((candidate) => candidate.id == entry.id);
            if (liveIndex < 0) return;
            _entries[liveIndex] = _entries[liveIndex].copyWith(progress: progress.clamp(0, 100), statusText: status);
            notifyListeners();
          }

          final path = await (_testRunner?.call(entry, progressCallback) ?? _run(entry, progressCallback));
          final liveIndex = _entries.indexWhere((candidate) => candidate.id == entry.id);
          if (liveIndex >= 0) {
            _entries[liveIndex] = _entries[liveIndex].copyWith(
              status: DownloadQueueStatus.completed,
              progress: 100,
              statusText: 'Downloaded',
              localPath: path,
            );
          }
          _completions.remove(entry.id)?.complete(path);
        } catch (error, stackTrace) {
          debugPrint('Queued download failed: $error\n$stackTrace');
          final liveIndex = _entries.indexWhere((candidate) => candidate.id == entry.id);
          if (liveIndex >= 0) {
            _entries[liveIndex] = _entries[liveIndex].copyWith(
              status: DownloadQueueStatus.failed,
              statusText: 'Failed',
              error: error.toString().replaceFirst('Exception: ', ''),
            );
          }
          _completions.remove(entry.id)?.completeError(error, stackTrace);
        }
        notifyListeners();
      }
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<String?> _run(DownloadQueueEntry entry, void Function(double progress, String status) onProgress) async {
    String? firstPath;
    if (Platform.isWindows) {
      await _windows.initBinaries();
      await _windows.downloadAudio(
        url: entry.track.url,
        historyTitle: entry.track.title,
        historyArtist: entry.track.artist,
        onProgress: onProgress,
        onTrackDownloaded: (path, videoId) async {
          await _finishTrack(entry, path, videoId);
          firstPath ??= path;
        },
      );
    } else if (Platform.isAndroid) {
      final downloads = await _android.downloadAudio(
        entry.track.url,
        historyTitle: entry.track.title,
        historyArtist: entry.track.artist,
        onProgress: onProgress,
      );
      for (final download in downloads) {
        await _finishTrack(entry, download.localPath, download.youtubeVideoId);
        firstPath ??= download.localPath;
      }
    } else {
      throw UnsupportedError('YouTube downloads are supported on Android and Windows');
    }
    return firstPath;
  }

  Future<void> _finishTrack(DownloadQueueEntry entry, String path, String? videoId) async {
    await ImportService.importFiles([path], (_) {}, playlistNumber: entry.playlistNumber);
    if (videoId != null) {
      await const TrackSourceRepository().saveSource(
        localPath: path,
        youtubeVideoId: videoId,
        method: TrackSourceMethod.downloadedByResonance,
        lastVerifiedAt: DateTime.now().toUtc(),
      );
    }
    unawaited(
      const LyricsService().prefetch(
        trackId: path,
        title: entry.track.title,
        artist: entry.track.artist,
        duration: entry.track.durationSeconds == null ? null : Duration(seconds: entry.track.durationSeconds!),
      ),
    );
  }
}
