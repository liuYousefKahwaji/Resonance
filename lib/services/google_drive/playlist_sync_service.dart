import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'google_drive_models.dart';
import 'google_drive_service.dart';
import 'playlist_sync_document.dart';

enum PlaylistSyncMode { stream, download }

enum PlaylistSyncStatus { waiting, syncing, synced, attention }

class LocalSyncEntry {
  const LocalSyncEntry(this.id, this.videoId, this.path);
  final String id, videoId, path;
  Map<String, dynamic> toJson() => {'id': id, 'videoId': videoId, 'path': path};
  factory LocalSyncEntry.fromJson(Map<String, dynamic> json) =>
      LocalSyncEntry(json['id'] as String, json['videoId'] as String, json['path'] as String);
}

class SyncedPlaylist {
  SyncedPlaylist({
    required this.accountId,
    required this.fileId,
    required this.number,
    required this.mode,
    required this.document,
    required this.localName,
    required this.localEntries,
    this.requiresSyncDocument = false,
  });
  final String accountId, fileId;
  int number;
  PlaylistSyncMode mode;
  PlaylistSyncDocument document;
  String localName;
  List<LocalSyncEntry> localEntries;
  bool requiresSyncDocument;
  String? etag, error, remoteFingerprint;
  Map<String, dynamic>? pendingApply;
  int unmatched = 0;
  PlaylistSyncStatus status = PlaylistSyncStatus.waiting;
  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'fileId': fileId,
    'number': number,
    'mode': mode.name,
    'document': document.toJson(),
    'localName': localName,
    'localEntries': localEntries.map((entry) => entry.toJson()).toList(),
    'requiresSyncDocument': requiresSyncDocument,
    if (pendingApply != null) 'pendingApply': pendingApply,
  };
  factory SyncedPlaylist.fromJson(Map<String, dynamic> json) => SyncedPlaylist(
    accountId: json['accountId'] as String,
    fileId: json['fileId'] as String,
    number: json['number'] as int,
    mode: PlaylistSyncMode.values.byName(json['mode'] as String),
    document: PlaylistSyncDocument.fromJson(Map<String, dynamic>.from(json['document'] as Map)),
    localName: json['localName'] as String,
    requiresSyncDocument: json['requiresSyncDocument'] == true,
    localEntries: (json['localEntries'] as List)
        .map((value) => LocalSyncEntry.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList(),
  )..pendingApply = json['pendingApply'] == null ? null : Map<String, dynamic>.from(json['pendingApply'] as Map);
}

typedef SyncDownload = Future<String?> Function(YoutubeTrack track, int playlist);

/// Opt-in, metadata-only synchronization. One worker owns cloud writes; persisted
/// logical clocks/tombstones merge offline edits without last-snapshot loss.
/// Android runs while the process is alive and catches up on resume; it does not
/// promise an OS wakeup or silently sign in while the application is closed.
class PlaylistSyncService extends ChangeNotifier with WidgetsBindingObserver {
  PlaylistSyncService({
    required this.drive,
    FileService? files,
    TrackSourceRepository? sources,
    SyncDownload? download,
    this.pollInterval = const Duration(seconds: 30),
    this.debounce = const Duration(seconds: 2),
  }) : files = files ?? FileService(),
       sources = sources ?? const TrackSourceRepository(),
       _download = download;
  static final instance = PlaylistSyncService(drive: GoogleDriveService.instance);
  static const storageKey = 'google_drive_playlist_sync_v1'; // Excluded from portable backups.
  final GoogleDriveService drive;
  final FileService files;
  final TrackSourceRepository sources;
  final SyncDownload? _download;
  final Duration pollInterval, debounce;
  final List<SyncedPlaylist> _links = [];
  final Set<String> _downloadAttempts = {};
  final Set<String> _paused = {};
  Future<void>? _starting, _running;
  Future<void> _writes = Future.value();
  StreamSubscription<PlaylistMutation>? _mutations;
  Timer? _poll, _debounce;
  String _device = '', _account = '';
  int _session = -1, _generation = 0;
  bool _disposed = false;
  List<SyncedPlaylist> get playlists => List.unmodifiable(_links.where((link) => link.accountId == drive.account?.id));
  SyncedPlaylist? forFile(String fileId) => playlists.where((link) => link.fileId == fileId).firstOrNull;

  /// User actions on a cloud file must not compete with this device's worker.
  Future<T> withPaused<T>(String? fileId, Future<T> Function() action) async {
    if (fileId != null) _paused.add(fileId);
    try {
      await _running;
      return await action();
    } finally {
      if (fileId != null) _paused.remove(fileId);
      if (!_disposed) _schedule();
    }
  }

  Future<void> start({bool polling = true}) => _starting ??= _start(polling);
  Future<void> _start(bool polling) async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    try {
      final saved = jsonDecode(prefs.getString(storageKey) ?? '{}') as Map;
      _device = saved['device'] as String? ?? '';
      for (final value in (saved['links'] as List? ?? [])) {
        final link = SyncedPlaylist.fromJson(Map<String, dynamic>.from(value as Map));
        if (link.number >= 0 && !_links.any((old) => old.accountId == link.accountId && old.fileId == link.fileId)) {
          _links.add(link);
        }
      }
    } catch (_) {
      // Never infer cloud deletions from a damaged local binding file.
      _links.clear();
    }
    if (_device.isEmpty) {
      _device = List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    }
    drive.addListener(_accountChanged);
    WidgetsBinding.instance.addObserver(this);
    _mutations = FileService.mutations.listen(_onMutation);
    if (polling) _poll = Timer.periodic(pollInterval, (_) => unawaited(syncNow()));
    if (_links.isNotEmpty) {
      try {
        await drive.initialize();
      } catch (_) {
        /* Retry on resume/next poll. */
      }
    }
    _accountChanged();
  }

  void _accountChanged() {
    if (_disposed) return;
    final account = drive.account?.id ?? '';
    if (account == _account && _session == drive.sessionRevision) return;
    _account = account;
    _session = drive.sessionRevision;
    _generation++;
    _downloadAttempts.clear();
    for (final link in _links) {
      link.etag = null;
      link.status = PlaylistSyncStatus.waiting;
    }
    notifyListeners();
    if (account.isNotEmpty) _schedule();
  }

  void _onMutation(PlaylistMutation mutation) {
    if (_disposed) return;
    if (mutation.kind == PlaylistMutationKind.deleted) {
      // Playlist 1 promotes another numbered file. Carry that binding with the
      // file instead of accidentally attaching the deleted playlist's cloud ID.
      _links.removeWhere((link) => link.number == mutation.playlistNumber);
      if (mutation.promotedFrom case final number?) {
        for (final link in _links.where((link) => link.number == number)) {
          link.number = mutation.playlistNumber;
        }
      }
      unawaited(_save());
      notifyListeners();
    }
    if (_links.any((link) => link.number == mutation.playlistNumber)) _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    if (_disposed || playlists.isEmpty) return;
    _debounce = Timer(debounce, () => unawaited(syncNow()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(syncNow());
  }

  Future<void> _save() {
    final value = jsonEncode({'device': _device, 'links': _links.map((link) => link.toJson()).toList()});
    final write = _writes.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(storageKey, value)) throw StateError('Could not save playlist sync state.');
    });
    _writes = write;
    return write;
  }

  Future<void> link({
    required int number,
    required DrivePlaylist remote,
    required PlaylistSyncMode mode,
    DriveSyncSnapshot? initial,
  }) async {
    await start();
    await _running;
    final account = drive.account?.id;
    final generation = _generation;
    if (account == null) throw const GoogleDriveException('Connect Google Drive to continue.');
    final snapshot = initial ?? await drive.readForSync(remote);
    if (snapshot == null || generation != _generation || _disposed) throw const GoogleDriveCancelled();
    final names = await files.getPlaylistNames();
    if (!names.containsKey(number)) throw const GoogleDriveException('This local playlist no longer exists.');
    final doc = snapshot.document ?? PlaylistSyncDocument.seed(remote.id, snapshot.manifest);
    final tracks = await files.readPlaylistTracks(number);
    final ids = await sources.youtubeIdsByLocalPath();
    final remaining = <String, Queue<SyncEntry>>{};
    for (final entry in doc.active) {
      (remaining[entry.videoId] ??= Queue()).add(entry);
    }
    final local = <LocalSyncEntry>[];
    for (final path in tracks) {
      final video = _video(path, ids);
      final candidates = remaining[video];
      final match = candidates == null || candidates.isEmpty ? null : candidates.removeFirst();
      if (match != null) {
        local.add(LocalSyncEntry(match.id, match.videoId, path));
      }
    }
    if (generation != _generation || _disposed) throw const GoogleDriveCancelled();
    _links.removeWhere((link) => link.number == number || (link.accountId == account && link.fileId == remote.id));
    _links.add(
      SyncedPlaylist(
        accountId: account,
        fileId: remote.id,
        number: number,
        mode: mode,
        document: doc,
        localName: names[number]!,
        localEntries: local,
        requiresSyncDocument: snapshot.document != null,
      ),
    );
    await _save();
    notifyListeners();
    _schedule();
  }

  Future<void> unlink(SyncedPlaylist link) async {
    _links.remove(link);
    if (playlists.isEmpty) _debounce?.cancel();
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> setMode(SyncedPlaylist link, PlaylistSyncMode mode) async {
    link.mode = mode;
    _downloadAttempts.clear();
    await _save();
    _schedule();
    if (!_disposed) notifyListeners();
  }

  Future<void> syncNow() async {
    await start();
    if (_disposed || _running != null || !drive.connected || drive.busy || playlists.isEmpty) return;
    final future = _syncAll();
    _running = future;
    try {
      await future;
    } finally {
      _running = null;
    }
  }

  Future<void> _syncAll() async {
    final generation = _generation;
    for (final link in playlists) {
      if (_paused.contains(link.fileId)) continue;
      if (!_current(link, generation)) return;
      link.status = PlaylistSyncStatus.syncing;
      link.error = null;
      notifyListeners();
      try {
        await _sync(link, generation);
        if (_current(link, generation) && link.status == PlaylistSyncStatus.syncing) {
          link.status = PlaylistSyncStatus.synced;
        }
      } catch (error) {
        if (_current(link, generation) && error is GoogleDriveException && error.statusCode == 404) {
          await unlink(link); // The cloud copy is gone; local tracks stay intact.
          continue;
        }
        if (_current(link, generation)) {
          link.status = error is GoogleDriveCancelled ? PlaylistSyncStatus.waiting : PlaylistSyncStatus.attention;
          link.error = error is GoogleDriveException
              ? error.message
              : 'Could not sync this playlist. Your local changes are saved; try again.';
          link.etag = null;
        }
      }
      if (!_disposed) notifyListeners();
    }
  }

  bool _current(SyncedPlaylist link, int generation) =>
      !_disposed &&
      generation == _generation &&
      link.accountId == drive.account?.id &&
      _links.contains(link) &&
      !_paused.contains(link.fileId);
  String? _video(String path, Map<String, String> ids) {
    final identity = files.favoriteIdentity(path, sourceIds: ids);
    return identity.startsWith('youtube:') ? identity.substring(8) : null;
  }

  Future<void> _sync(SyncedPlaylist link, int generation) async {
    final names = await files.getPlaylistNames();
    if (!_current(link, generation)) return;
    if (!names.containsKey(link.number)) {
      await unlink(link);
      return;
    }
    var name = names[link.number]!;
    final tracks = await files.readPlaylistTracks(link.number);
    if (link.pendingApply case final pending?) {
      // File writes and this journal are serialized against local mutations.
      // If a process exits between writing the playlist and saving its binding,
      // recover the exact occurrence IDs instead of adding duplicate entries.
      final target = List<String>.from(pending['tracks'] as List)..sort();
      final expected = List<String>.from(pending['expectedTracks'] as List? ?? [])..sort();
      final targetName = pending['name'] as String? ?? name;
      if (jsonEncode(target) == jsonEncode(tracks.toList()..sort()) &&
          (jsonEncode(target) != jsonEncode(expected) || name == targetName)) {
        if (name != targetName && name == pending['expectedName']) {
          final recovered = await files.applySyncedPlaylist(
            link.number,
            expectedTracks: tracks,
            expectedName: name,
            tracks: tracks,
            name: targetName,
            isCurrent: () => _current(link, generation),
          );
          if (!recovered) {
            _schedule();
            return;
          }
          name = (await files.getPlaylistNames())[link.number] ?? targetName;
        }
        link.document = PlaylistSyncDocument.fromJson(Map<String, dynamic>.from(pending['document'] as Map));
        link.localEntries = (pending['entries'] as List)
            .map((item) => LocalSyncEntry.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
        link.localName = targetName;
        link.requiresSyncDocument = true;
      }
      link.pendingApply = null;
      await _save();
    }
    final ids = await sources.youtubeIdsByLocalPath();
    if (!_current(link, generation)) return;
    final byPath = <String, Queue<LocalSyncEntry>>{}, byVideo = <String, Queue<LocalSyncEntry>>{};
    for (final entry in link.localEntries) {
      (byPath[entry.path] ??= Queue()).add(entry);
      (byVideo[entry.videoId] ??= Queue()).add(entry);
    }
    final used = <String>{};
    LocalSyncEntry? take(Queue<LocalSyncEntry>? queue) {
      while (queue != null && queue.isNotEmpty) {
        final entry = queue.removeFirst();
        if (!used.contains(entry.id)) return entry;
      }
      return null;
    }

    final desired = <({String? entryId, String videoId})>[];
    final desiredPaths = <String>[];
    final localOnly = <({int index, String path})>[];
    for (var index = 0; index < tracks.length; index++) {
      final path = tracks[index];
      final exact = take(byPath[path]);
      final video = _video(path, ids) ?? exact?.videoId;
      if (video == null) {
        localOnly.add((index: index, path: path));
        continue;
      }
      final previous = exact ?? take(byVideo[video]);
      if (previous != null) used.add(previous.id);
      desired.add((entryId: previous?.id, videoId: video));
      desiredPaths.add(path);
    }
    link.unmatched = localOnly.length;
    link.document = link.document.edit(
      device: _device,
      tracks: desired,
      renamed: name == link.localName ? null : name,
      observedIds: link.localEntries.map((entry) => entry.id).toSet(),
    );
    link.localName = name;
    // Persist local changes BEFORE reaching the network, including their exact
    // occurrence IDs, so a retry/restart cannot generate duplicate additions.
    final edited = link.document.active.map((entry) => entry.id).toSet();
    link.localEntries = [
      for (var i = 0; i < desired.length; i++)
        LocalSyncEntry(desired[i].entryId ?? '$_device:${link.document.clock}:$i', desired[i].videoId, desiredPaths[i]),
    ];
    // Existing deleted IDs can only appear in stale snapshots, not a normal edit.
    link.localEntries.removeWhere((entry) => !edited.contains(entry.id));
    await _save();
    if (!_current(link, generation)) return;
    final remote = DrivePlaylist(id: link.fileId, name: link.document.name);
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final snapshot = await drive.readForSync(remote, knownEtag: link.etag);
        if (!_current(link, generation)) return;
        if (snapshot == null) {
          if (link.remoteFingerprint == link.document.fingerprint) return;
          // The remote version is unchanged, but the local document may have
          // changed. Read it again for a merge unless we already know equality.
          link.etag = null;
          continue;
        }
        if (link.requiresSyncDocument && snapshot.document == null) {
          throw const GoogleDriveException(
            'This Drive playlist was replaced outside sync. Turn sync off and link it again.',
          );
        }
        final cloud = snapshot.document ?? PlaylistSyncDocument.seed(link.fileId, snapshot.manifest);
        final merged = link.document.merge(cloud);
        final metadata = {...snapshot.manifest.trackMetadata};
        for (final entry in link.localEntries) {
          final cached = await MetadataCacheService.get(entry.path);
          if (cached != null) {
            metadata[entry.videoId] = PlaylistTransferTrackMetadata(title: cached.title, artist: cached.artist);
          }
        }
        if (!_current(link, generation)) return;
        final uploaded = snapshot.document == null || merged.fingerprint != cloud.fingerprint;
        if (uploaded) {
          await drive.upload(
            merged.manifest(metadata: metadata),
            replace: remote,
            sync: merged,
            ifMatch: snapshot.etag,
          );
        }
        if (!_current(link, generation)) return;
        final localFiles = link.mode == PlaylistSyncMode.download
            ? await sources.findLocalTracksByYoutubeIds(merged.active.map((entry) => entry.videoId))
            : <String, String>{};
        final byEntry = {for (final entry in link.localEntries) entry.id: entry.path};
        final localEntries = [
          for (final entry in merged.active)
            LocalSyncEntry(
              entry.id,
              entry.videoId,
              localFiles[entry.videoId] ?? byEntry[entry.id] ?? TrackSourceRepository.canonicalUrlFor(entry.videoId),
            ),
        ];
        final result = localEntries.map((entry) => entry.path).toList();
        for (final extra in localOnly) {
          result.insert(extra.index.clamp(0, result.length), extra.path);
        }
        if (!_current(link, generation)) return;
        var targetName = merged.name == link.document.name && name == link.localName ? name : merged.name;
        targetName = targetName.substring(0, min(targetName.length, FileService.maxPlaylistNameLength)).trimRight();
        if (FileService.isFavoritesPlaylist(link.number)) targetName = name;
        link.pendingApply = {
          'tracks': result,
          'expectedTracks': tracks,
          'expectedName': name,
          'name': targetName,
          'document': merged.toJson(),
          'entries': localEntries.map((entry) => entry.toJson()).toList(),
        };
        await _save();
        if (!_current(link, generation)) return;
        final applied = await files.applySyncedPlaylist(
          link.number,
          expectedTracks: tracks,
          expectedName: name,
          tracks: result,
          name: targetName,
          isCurrent: () => _current(link, generation),
          onApplied: () async {
            link.document = merged;
            link.localEntries = localEntries;
            link.localName = (await files.getPlaylistNames())[link.number] ?? merged.name;
            link.requiresSyncDocument = true;
            link.pendingApply = null;
            await _save();
          },
        );
        if (!applied) {
          link.pendingApply = null;
          await _save();
          link.etag = null;
          link.status = PlaylistSyncStatus.waiting;
          _schedule();
          return;
        }
        if (!_current(link, generation)) return;
        link.document = merged;
        link.localEntries = localEntries;
        link.localName = (await files.getPlaylistNames())[link.number] ?? merged.name;
        link.requiresSyncDocument = true;
        link.etag = uploaded ? null : snapshot.etag;
        link.remoteFingerprint = merged.fingerprint;
        await _save();
        if (merged.active.isNotEmpty) await _cacheNames(merged.manifest(metadata: metadata));
        if (_current(link, generation) && link.mode == PlaylistSyncMode.download) {
          for (final entry in localEntries) {
            if (TrackSourceRepository.videoIdFromUrlOrId(entry.path) == null) continue;
            final key = '${link.accountId}/${link.fileId}/${entry.videoId}';
            if (!_downloadAttempts.add(key)) continue;
            final meta = metadata[entry.videoId];
            final track = YoutubeTrack(
              title: meta?.title ?? 'Streaming Audio',
              artist: meta?.artist ?? 'YouTube',
              url: TrackSourceRepository.canonicalUrlFor(entry.videoId),
              thumbnailUrl: TrackSourceRepository.thumbnailUrlFor(entry.videoId),
            );
            unawaited(
              (_download?.call(track, link.number) ??
                      DownloadQueueController.instance.enqueue(
                        track,
                        link.number,
                        replaceStream: true,
                        automaticKey: key,
                      ))
                  .catchError((Object _) => null),
            );
          }
        }
        return;
      } on GoogleDriveException catch (error) {
        if (error.statusCode != 409 && error.statusCode != 412) rethrow;
        link.etag = null;
        if (attempt == 2) rethrow;
      }
    }
  }

  Future<void> _cacheNames(PlaylistTransferManifest manifest) async {
    await MetadataCacheService.setStreams({
      for (final entry in manifest.trackMetadata.entries)
        TrackSourceRepository.canonicalUrlFor(entry.key): CachedTrackMetadata(
          title: entry.value.title,
          artist: entry.value.artist,
          artworkUrl: TrackSourceRepository.thumbnailUrlFor(entry.key),
        ),
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _poll?.cancel();
    _debounce?.cancel();
    unawaited(_mutations?.cancel());
    drive.removeListener(_accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
