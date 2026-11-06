import 'package:resonance/models/download_transfer_progress.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/services/youtube/youtube_request.dart';
import 'dart:async';
import 'dart:io';
import 'package:resonance/core/storage/file_service.dart';

import 'package:flutter/foundation.dart';
import 'package:resonance/models/download_queue_entry.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/import_service.dart';
import 'package:resonance/services/lyrics_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/widgets/youtube/android_youtube.dart';
import 'package:resonance/widgets/youtube/windows_youtube.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';

typedef DownloadTaskRunner =
    Future<String?> Function(DownloadQueueEntry entry, void Function(double progress, String status) onProgress);

/// Process-lifetime FIFO download coordinator. It deliberately lives above
/// Search routes so navigation and app backgrounding cannot dispose its worker.
class DownloadQueueController extends ChangeNotifier {
  final DownloadTaskRunner? _testRunner;

  DownloadQueueController._()
    : _testRunner = null,
      persist = true,
      maxAutomaticRetries = 3,
      retryDelay = const Duration(seconds: 1) {
    _ready = _restore();
    unawaited(_ready.then((_) => _drain()));
  }
  static final DownloadQueueController instance = DownloadQueueController._();

  @visibleForTesting
  DownloadQueueController.forTesting({
    required DownloadTaskRunner runner,
    this.persist = false,
    this.maxAutomaticRetries = 3,
    this.retryDelay = Duration.zero,
  }) : _testRunner = runner {
    _loaded = !persist;
    _ready = persist ? _restore() : Future.value();
  }
  final bool persist;
  final int maxAutomaticRetries;
  final Duration retryDelay;
  static const storageKey = 'download_queue_v2';
  final Set<String> _blockedAutomatic = {};
  late Future<void> _ready;
  Future<void> get ready => _ready;
  bool _loaded = false, _disposed = false;
  Future<void> _writes = Future.value();
  YoutubeRequest? _activeRequest;
  @visibleForTesting
  YoutubeRequest? get activeRequest => _activeRequest;
  String? _activeId;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

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
    _notify();
  }

  Future<String?> enqueue(YoutubeTrack track, int playlistNumber, {bool replaceStream = false, String? automaticKey}) {
    if (!_loaded) {
      return _ready.then(
        (_) => enqueue(track, playlistNumber, replaceStream: replaceStream, automaticKey: automaticKey),
      );
    }
    if (_disposed || (automaticKey != null && _blockedAutomatic.contains(automaticKey))) return Future.value(null);
    final existing = pendingEntryFor(track.url, playlistNumber);
    if (existing != null) return _completions.putIfAbsent(existing.id, Completer<String?>.new).future;
    return _enqueue(
      DownloadQueueEntry(
        id: '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
        track: track,
        playlistNumber: playlistNumber,
        replaceStream: replaceStream,
        automaticKey: automaticKey,
      ),
    );
  }

  Future<String?> _enqueue(DownloadQueueEntry entry) {
    final completion = Completer<String?>();
    _completions[entry.id] = completion;
    _entries.add(entry);
    _notify();
    unawaited(_save());
    unawaited(_drain());
    return completion.future;
  }

  void _block(DownloadQueueEntry entry) {
    if (entry.automaticKey != null) _blockedAutomatic.add(entry.automaticKey!);
  }

  void cancel(String id) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final entry = _entries[index];
    if (entry.status != DownloadQueueStatus.queued && entry.status != DownloadQueueStatus.downloading) return;
    _block(entry);
    if (_activeId == id) _activeRequest?.cancel();
    _entries[index] = entry.copyWith(status: DownloadQueueStatus.cancelled, statusText: 'Cancelled');
    _completions.remove(id)?.complete(null);
    unawaited(_save());
    _notify();
  }

  void clearFinished() {
    _entries.removeWhere(
      (e) =>
          e.status == DownloadQueueStatus.completed ||
          e.status == DownloadQueueStatus.failed ||
          e.status == DownloadQueueStatus.cancelled,
    );
    // Keep automatic suppression: clearing a failure must not re-enqueue it at the next Drive poll.
    unawaited(_save());
    _notify();
  }

  void clearAll() {
    for (final entry in List<DownloadQueueEntry>.of(_entries)) {
      cancel(entry.id);
    }
    _entries.clear();
    unawaited(_save());
    _notify();
  }

  Future<void> retry(String id) async {
    await _ready;
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0 || ![DownloadQueueStatus.failed, DownloadQueueStatus.cancelled].contains(_entries[index].status)) {
      return;
    }
    final old = _entries.removeAt(index);
    if (old.automaticKey != null) _blockedAutomatic.remove(old.automaticKey);
    await _enqueue(
      DownloadQueueEntry(
        id: '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
        track: old.track,
        playlistNumber: old.playlistNumber,
        replaceStream: old.replaceStream,
        automaticKey: old.automaticKey,
      ),
    ).catchError((Object _) => null);
  }

  Future<void> _drain() async {
    if (_working || !_loaded || _disposed) return;
    _working = true;
    _notify();
    try {
      while (!_disposed) {
        final index = _entries.indexWhere((e) => e.status == DownloadQueueStatus.queued);
        if (index < 0) break;
        var entry = _entries[index];
        final request = YoutubeRequest();
        _activeRequest = request;
        _activeId = entry.id;
        try {
          while (true) {
            request.check();
            if (entry.attempts >= maxAutomaticRetries + 1) throw StateError('Retry limit reached');
            if (entry.attempts > 0) await request.follow(Future<void>.delayed(retryDelay * entry.attempts));
            request.check();
            final live = _entries.indexWhere((e) => e.id == entry.id);
            if (live < 0) throw const YoutubeRequestCancelled();
            entry = entry.copyWith(
              status: DownloadQueueStatus.downloading,
              attempts: entry.attempts + 1,
              progress: 0,
              clearTransfer: true,
              statusText: entry.attempts == 0 ? 'Starting…' : 'Retrying (${entry.attempts}/$maxAutomaticRetries)...',
            );
            _entries[live] = entry;
            _notify();
            if (persist) await _save(); // Preserve the retry budget before starting native work.
            request.check();
            try {
              void progress(double value, String status) {
                final current = _entries.indexWhere((e) => e.id == entry.id);
                if (request.isCancelled || current < 0 || _disposed) return;
                _entries[current] = _entries[current].copyWith(
                  progress: value.clamp(0, 100),
                  statusText: status,
                  clearTransfer: !status.contains('Downloading'),
                );
                _notify();
              }

              final path = await (_testRunner?.call(entry, progress) ?? _run(entry, progress, request));
              request.check();
              final current = _entries.indexWhere((e) => e.id == entry.id);
              if (current >= 0) {
                _entries[current] = entry.copyWith(
                  status: DownloadQueueStatus.completed,
                  progress: 100,
                  statusText: 'Downloaded',
                  localPath: path,
                );
              }
              _completions.remove(entry.id)?.complete(path);
              break;
            } catch (error) {
              if (request.isCancelled) throw const YoutubeRequestCancelled();
              if (error is YoutubeRequestCancelled) rethrow;
              final failure = error is YoutubeFailure
                  ? error
                  : YoutubeFailureClassifier.classify(
                      error,
                      authenticated: YoutubeAccessService.active?.isConfigured ?? false,
                      sourceUrl: entry.track.url,
                    );
              final message = _downloadFailureMessage(error, failure);
              final retryable =
                  message == failure.userMessage &&
                  (failure.kind == YoutubeFailureKind.network || failure.kind == YoutubeFailureKind.unknown);
              if (retryable && entry.attempts <= maxAutomaticRetries) continue;
              _block(entry);
              YoutubeAccessService.active?.observeFailure(failure);
              final current = _entries.indexWhere((e) => e.id == entry.id);
              if (current >= 0) {
                _entries[current] = entry.copyWith(
                  status: DownloadQueueStatus.failed,
                  statusText: 'Failed',
                  error: message,
                  failureKind: failure.kind,
                );
              }
              _completions.remove(entry.id)?.completeError(error, StackTrace.current);
              break;
            }
          }
        } on YoutubeRequestCancelled {
          _completions.remove(entry.id)?.complete(null);
        } catch (error, stack) {
          _block(entry);
          final current = _entries.indexWhere((e) => e.id == entry.id);
          if (current >= 0) {
            _entries[current] = entry.copyWith(
              status: DownloadQueueStatus.failed,
              statusText: 'Failed',
              error: 'Download stopped. Retry when you are ready.',
            );
          }
          _completions.remove(entry.id)?.completeError(error, stack);
        } finally {
          _activeRequest = null;
          _activeId = null;
          await _save();
          _notify();
        }
      }
    } finally {
      _working = false;
      _notify();
    }
  }

  Future<void> _save() {
    if (!persist) return Future.value();
    final json = jsonEncode({
      'blocked': _blockedAutomatic.toList(),
      'entries': [
        for (final e in _entries)
          {
            'id': e.id,
            'url': e.track.url,
            'title': e.track.title,
            'artist': e.track.artist,
            'thumbnail': e.track.thumbnailUrl,
            'playlist': e.playlistNumber,
            'replace': e.replaceStream,
            'automaticKey': e.automaticKey,
            'attempts': e.attempts,
            'status': e.status.name,
            'path': e.localPath,
            'error': e.error,
            'failureKind': e.failureKind?.name,
          },
      ],
    });
    _writes = _writes
        .catchError((_) {})
        .then((_) async {
          await (await SharedPreferences.getInstance()).setString(storageKey, json);
        })
        .catchError((Object _) {});
    return _writes;
  }

  Future<void> _restore() async {
    try {
      final data = jsonDecode((await SharedPreferences.getInstance()).getString(storageKey) ?? '{}') as Map;
      _blockedAutomatic.addAll((data['blocked'] as List? ?? []).whereType<String>());
      for (final raw in data['entries'] as List? ?? []) {
        if (raw is! Map || raw['url'] is! String || raw['playlist'] is! int) continue;
        final status =
            DownloadQueueStatus.values.where((s) => s.name == raw['status']).firstOrNull ?? DownloadQueueStatus.failed;
        final attempts = (raw['attempts'] as int? ?? 0).clamp(0, maxAutomaticRetries + 1);
        final entry = DownloadQueueEntry(
          id: raw['id'] as String,
          track: YoutubeTrack(
            url: raw['url'],
            title: raw['title'] as String? ?? 'Song',
            artist: raw['artist'] as String? ?? '',
            thumbnailUrl: raw['thumbnail'] as String?,
          ),
          playlistNumber: raw['playlist'],
          replaceStream: raw['replace'] == true,
          automaticKey: raw['automaticKey'] as String?,
          attempts: attempts,
          status: status == DownloadQueueStatus.downloading ? DownloadQueueStatus.queued : status,
          failureKind: YoutubeFailureKind.values.where((kind) => kind.name == raw['failureKind']).firstOrNull,
          localPath: raw['path'] as String?,
          error: raw['error'] as String?,
          statusText: status == DownloadQueueStatus.cancelled
              ? 'Cancelled'
              : status == DownloadQueueStatus.completed
              ? 'Downloaded'
              : status == DownloadQueueStatus.failed
              ? 'Failed'
              : 'Waiting',
        );
        _entries.add(entry);
        if (status == DownloadQueueStatus.failed || status == DownloadQueueStatus.cancelled) _block(entry);
      }
    } catch (_) {
      /* A malformed queue must never change a playlist. */
    }
    _loaded = true;
    _notify();
  }

  @visibleForTesting
  void resume() => unawaited(_drain());
  Future<void> flush() => _writes;
  @override
  void dispose() {
    _disposed = true;
    _activeRequest?.cancel();
    super.dispose();
  }

  String _downloadFailureMessage(Object error, YoutubeFailure failure) {
    final text = error.toString().toLowerCase();
    if (text.contains('no space left') || text.contains('disk full') || text.contains('not enough space')) {
      return 'Not enough storage space. Free some space, then retry.';
    }
    if (text.contains('permission denied') || text.contains('access is denied') || text.contains('read-only file')) {
      return 'Cannot save to the download folder. Choose another folder in Settings.';
    }
    if (text.contains('conversion failed') || text.contains('no audio file') || text.contains('no output file')) {
      return 'Audio processing failed. Retry the download or choose Original format in Settings.';
    }
    return failure.userMessage;
  }

  Future<String?> _run(
    DownloadQueueEntry entry,
    void Function(double progress, String status) onProgress,
    YoutubeRequest request,
  ) async {
    String? firstPath;
    void transfer(DownloadTransferProgress value) {
      final index = _entries.indexWhere((e) => e.id == entry.id);
      if (index < 0 || request.isCancelled || _disposed) return;
      _entries[index] = _entries[index].copyWith(transfer: value);
      _notify();
    }

    if (Platform.isWindows) {
      await _windows.initBinaries();
      request.check();
      await _windows.downloadAudio(
        url: entry.track.url,
        request: request,
        historyTitle: entry.track.title,
        historyArtist: entry.track.artist,
        onProgress: onProgress,
        onTransferProgress: transfer,
        onTrackDownloaded: (path, videoId) async {
          await _finishTrack(entry, path, videoId, request);
          firstPath ??= path;
        },
      );
    } else if (Platform.isAndroid) {
      final downloads = await _android.downloadAudio(
        entry.track.url,
        request: request,
        historyTitle: entry.track.title,
        historyArtist: entry.track.artist,
        onProgress: onProgress,
        onTransferProgress: transfer,
      );
      for (final download in downloads) {
        await _finishTrack(entry, download.localPath, download.youtubeVideoId, request);
        firstPath ??= download.localPath;
      }
    } else {
      throw UnsupportedError('YouTube downloads are supported on Android and Windows');
    }
    if (firstPath == null) throw StateError('Download completed without an audio file');
    return firstPath;
  }

  Future<void> _finishTrack(DownloadQueueEntry entry, String path, String? videoId, YoutubeRequest request) async {
    request.check();
    if (videoId != null) {
      await const TrackSourceRepository().saveSource(
        localPath: path,
        youtubeVideoId: videoId,
        method: TrackSourceMethod.downloadedByResonance,
        lastVerifiedAt: DateTime.now().toUtc(),
      );
    }
    request.check();
    if (entry.replaceStream) {
      await FileService().replaceStreamWithDownload(entry.playlistNumber, entry.track.url, path);
    } else {
      await ImportService.importFiles([path], (_) {}, playlistNumber: entry.playlistNumber);
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
