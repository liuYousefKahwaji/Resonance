import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_track.dart';
import 'download/download_queue_controller.dart';
import 'metadata_cache_service.dart';
import 'track_source_repository.dart';

class OfflineProgress {
  int total = 0, completed = 0;
  bool running = false, stopping = false;
  final Map<String, String> failures = {};
  String? current;
}

class PlaylistOfflineService extends ChangeNotifier {
  PlaylistOfflineService({FileService? files, DownloadQueueController? queue})
    : files = files ?? FileService(),
      queue = queue ?? DownloadQueueController.instance;
  static final instance = PlaylistOfflineService();
  final FileService files;
  final DownloadQueueController queue;
  final Map<int, OfflineProgress> progress = {};
  Future<void> makeOffline(int number) async {
    if (progress[number]?.running == true) return;
    final state = OfflineProgress()..running = true;
    progress[number] = state;
    notifyListeners();
    try {
      final tracks = await files.readPlaylistTracks(number);
      state.total = tracks.length;
      for (final path in tracks) {
        if (state.stopping) break;
        state.current = path;
        notifyListeners();
        try {
          if (!path.startsWith('http')) {
            if (!await File(path).exists()) throw StateError('Local file is missing');
          } else {
            final video = TrackSourceRepository.videoIdFromUrlOrId(path);
            if (video == null) throw StateError('This stream cannot be downloaded');
            final local = await const TrackSourceRepository().findLocalTrackByYoutubeId(video);
            if (local != null) {
              await files.replaceStreamWithDownload(number, path, local);
            } else {
              final metadata = await MetadataCacheService.get(path);
              final downloaded = await queue.enqueue(
                YoutubeTrack(
                  url: path,
                  title: metadata?.title ?? 'YouTube video',
                  artist: metadata?.artist ?? 'Unknown artist',
                  thumbnailUrl: metadata?.artworkUrl,
                ),
                number,
                replaceStream: true,
              );
              if (downloaded == null) throw StateError('Download failed. Retry this track.');
            }
          }
          state.completed++;
        } catch (error) {
          state.failures[path] = '$error';
        }
        await _persist(number, state);
        notifyListeners();
      }
    } finally {
      state.running = false;
      state.current = null;
      await _persist(number, state);
      notifyListeners();
    }
  }

  // The shared queue is serialized; cancellation never interrupts another job.
  // Complete the current file safely, then stop this playlist's remaining work.
  void cancel(int number) {
    progress[number]?.stopping = true;
    notifyListeners();
  }

  Future<void> _persist(int number, OfflineProgress state) async {
    await (await SharedPreferences.getInstance()).setString(
      'offline_playlist_$number',
      jsonEncode({
        'total': state.total,
        'completed': state.completed,
        'failures': state.failures,
        'stopped': state.stopping,
      }),
    );
  }

  Future<int> removeManagedDownloads(int number) async {
    if (progress[number]?.running == true) throw StateError('Stop the playlist download first');
    final tracks = await files.readPlaylistTracks(number);
    final sources = const TrackSourceRepository();
    var removed = 0;
    final replaced = <String>[];
    final candidates = <String>[];
    for (final path in tracks) {
      final source = path.startsWith('http') ? null : await sources.getSourceForTrack(path);
      if (source?.method == TrackSourceMethod.downloadedByResonance) {
        replaced.add(source!.canonicalUrl);
        candidates.add(path);
        final metadata = await MetadataCacheService.get(path);
        if (metadata != null) {
          await MetadataCacheService.set(
            source.canonicalUrl,
            metadata.title,
            metadata.artist,
            artworkUrl: metadata.artworkUrl,
          );
        }
      } else {
        replaced.add(path);
      }
    }
    await files.replacePlaylistTracks(number, replaced);
    for (final path in candidates.toSet()) {
      var stillUsed = false;
      for (final playlist in await files.listPlaylistNumbers()) {
        if ((await files.readPlaylistTracks(playlist)).any((entry) => files.sameTrackPath(entry, path))) {
          stillUsed = true;
          break;
        }
      }
      if (!stillUsed && await File(path).exists()) {
        await File(path).delete();
        await sources.removeSourceForTrack(path);
        removed++;
      }
    }
    await (await SharedPreferences.getInstance()).remove('offline_playlist_$number');
    notifyListeners();
    return removed;
  }
}
