import 'dart:async';
import 'dart:collection';

import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'youtube_link_metadata_service.dart';

/// Old ID-only transfers become playable immediately. Only rows that are
/// actually built request missing names, using small public metadata responses.
class StreamTrackMetadataService {
  StreamTrackMetadataService({Future<YoutubeTrack?> Function(YoutubeTrack)? fetch, this.concurrency = 3})
    : assert(concurrency > 0),
      _fetch = fetch ?? const YoutubeLinkMetadataService().fetch;
  static final instance = StreamTrackMetadataService();
  final Future<YoutubeTrack?> Function(YoutubeTrack) _fetch;
  final int concurrency;
  final _queue = Queue<_MetadataJob>();
  final _pending = <String, _MetadataJob>{};
  final _failedUntil = <String, DateTime>{};
  var _active = 0;
  var _draining = false;

  Future<CachedTrackMetadata?> load(String path, {required bool Function() isCurrent}) => _load(path, isCurrent, true);

  Future<CachedTrackMetadata?> _load(String path, bool Function() isCurrent, bool retryCancelled) async {
    final cached = await MetadataCacheService.get(path);
    if (cached != null || !isCurrent()) return cached;
    final id = TrackSourceRepository.videoIdFromUrlOrId(path);
    if (id == null) return null;
    final canonical = TrackSourceRepository.canonicalUrlFor(id);
    final canonicalCache = await MetadataCacheService.get(canonical);
    if (canonicalCache != null) return canonicalCache;
    if ((_failedUntil[id]?.isAfter(DateTime.now()) ?? false) || !isCurrent()) return null;
    _failedUntil.remove(id);
    final job = _pending.putIfAbsent(id, () {
      final job = _MetadataJob(id, canonical);
      _queue.add(job);
      return job;
    });
    job.owners.add(isCurrent);
    _drain();
    final result = await job.result.future;
    // A row can join a cancelled job just as it leaves the queue. Its own
    // request must still get a chance, without retrying genuine HTTP failures.
    if (result == null && retryCancelled && isCurrent() && !_failedUntil.containsKey(id)) {
      return _load(path, isCurrent, false);
    }
    return result;
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    try {
      while (_active < concurrency && _queue.isNotEmpty) {
        final job = _queue.removeFirst();
        _active++;
        unawaited(_run(job));
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _run(_MetadataJob job) async {
    CachedTrackMetadata? result;
    try {
      if (job.owners.any((owner) => owner())) {
        final link = YoutubeTrack.fromVideoLink(job.url)!;
        final track = await _fetch(link);
        // A custom title/author or playback metadata may have arrived while
        // this optional fetch was running. Keep the newer existing value.
        result = await MetadataCacheService.get(job.url);
        if (result == null && track != null) {
          result = CachedTrackMetadata(
            title: track.title,
            artist: track.artist,
            artworkUrl: track.thumbnailUrl ?? TrackSourceRepository.thumbnailUrlFor(job.id),
          );
          await MetadataCacheService.set(job.url, result.title, result.artist, artworkUrl: result.artworkUrl);
        }
        if (result == null) _recordFailure(job.id);
      }
    } catch (_) {
      _recordFailure(job.id);
    } finally {
      _pending.remove(job.id);
      _active--;
      job.result.complete(result);
      _drain();
    }
  }

  void _recordFailure(String id) {
    if (_failedUntil.length >= 500) _failedUntil.remove(_failedUntil.keys.first);
    _failedUntil[id] = DateTime.now().add(const Duration(minutes: 1));
  }
}

class _MetadataJob {
  _MetadataJob(this.id, this.url);
  final String id, url;
  final owners = <bool Function()>[];
  final result = Completer<CachedTrackMetadata?>();
}
