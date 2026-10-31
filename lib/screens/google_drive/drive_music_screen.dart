import 'package:resonance/widgets/common/resonance_dialog.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/services/google_drive/drive_music_models.dart';
import 'package:resonance/services/google_drive/drive_music_service.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';

class DriveMusicScreen extends StatefulWidget {
  const DriveMusicScreen({super.key, this.service, this.onPlay});
  final DriveMusicService? service;
  final Future<void> Function(DriveMusicItem selected, List<DriveMusicItem> queue)? onPlay;
  @override
  State<DriveMusicScreen> createState() => _DriveMusicScreenState();
}

class _DriveMusicScreenState extends State<DriveMusicScreen> {
  late final service = widget.service ?? DriveMusicService.instance;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _path = <DriveMusicItem>[];
  final _items = <DriveMusicItem>[];
  final _parents = <String, DriveMusicItem>{};
  final _parentRequests = <String>{};
  Timer? _debounce;
  Timer? _catalogDebounce;
  int _libraryRevision = 0;
  String? _next, _error, _account;
  bool _loading = true, _permission = false, _adding = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _account = service.drive.account?.id;
    service.drive.addListener(_accountChanged);
    _libraryRevision = service.libraryRevision;
    service.addListener(_libraryChanged);
    _scroll.addListener(_loadOnScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _catalogDebounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    service.drive.removeListener(_accountChanged);
    service.removeListener(_libraryChanged);
    super.dispose();
  }

  void _libraryChanged() {
    if (service.libraryRevision == _libraryRevision) return;
    _libraryRevision = service.libraryRevision;
    _catalogDebounce?.cancel();
    _catalogDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) unawaited(_load());
    });
  }

  void _accountChanged() {
    if (_account == service.drive.account?.id || !mounted) return;
    _account = service.drive.account?.id;
    _path.clear();
    _parents.clear();
    _parentRequests.clear();
    unawaited(_load());
  }

  void _loadOnScroll() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 300 && !_loading && _next != null) {
      unawaited(_load(more: true));
    }
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || _next == null)) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _items.clear();
        _next = null;
        if (_path.isEmpty) {
          _parents.clear();
          _parentRequests.clear();
        }
      }
    });
    try {
      await service.drive.initialize();
      if (!mounted || generation != _generation) return;
      if (!service.drive.connected) {
        setState(() => _loading = false);
        return;
      }
      final page = _path.isEmpty
          ? await service.discover(pageToken: more ? _next : null, query: _search.text)
          : await service.folder(_path.last.id, pageToken: more ? _next : null, query: _search.text);
      if (!mounted || generation != _generation) return;
      final seen = _items.map((e) => e.id).toSet();
      setState(() {
        _items.addAll(page.items.where((e) => seen.add(e.id)));
        _next = page.nextPageToken;
      });
      unawaited(service.cacheNames(page.items, artist: _path.isEmpty ? 'Google Drive' : _path.last.name));
      if (_path.isEmpty) unawaited(_hydrateFolders(page.items, generation));
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = _message(error));
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _hydrateFolders(List<DriveMusicItem> items, int generation) async {
    final ids = items
        .expand((e) => e.parents)
        .where((id) => !_parents.containsKey(id) && _parentRequests.add(id))
        .toList();
    for (var index = 0; index < ids.length; index += 3) {
      if (!mounted || generation != _generation) return;
      await Future.wait(
        ids.skip(index).take(3).map((id) async {
          try {
            final folder = await service.metadata(id);
            if (mounted && generation == _generation && folder.isFolder) setState(() => _parents[id] = folder);
          } catch (_) {
            /* A shared parent may be inaccessible while its audio is readable. */
          } finally {
            _parentRequests.remove(id);
          }
        }),
      );
    }
  }

  String _message(Object error) => error is GoogleDriveException
      ? error.message
      : 'Could not load Drive music. Check your connection and try again.';
  void _notice(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.trRendered(text))));
  }

  Future<void> _browseExisting() async {
    setState(() => _permission = true);
    try {
      await service.drive.enableMusicLibrary();
      if (mounted) await _load();
    } on GoogleDriveCancelled {
      /* Keep existing uploads and playlist access. */
    } catch (error) {
      _notice(_message(error));
    } finally {
      if (mounted) setState(() => _permission = false);
    }
  }

  void _openFolder(DriveMusicItem folder) {
    _debounce?.cancel();
    _search.clear();
    _path.add(folder);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_load());
  }

  void _back() {
    if (_path.isEmpty) {
      Navigator.maybePop(context);
      return;
    }
    _path.removeLast();
    _search.clear();
    unawaited(_load());
  }

  Future<void> _play(DriveMusicItem selected) async {
    final queue = _items.where((e) => e.isAudio && e.canDownload).toList();
    try {
      if (widget.onPlay case final play?) {
        await play(selected, queue);
        return;
      }
      final owner = service.drive.account!.id;
      final playback = context.read<PlayerHandler>().playStandaloneStream(
        url: selected.streamUrl(owner),
        title: selected.title,
        artist: _path.isEmpty ? 'Google Drive' : _path.last.name,
        queueItems: [
          for (final item in queue)
            StandaloneStreamQueueItem(url: item.streamUrl(owner), title: item.title, artist: 'Google Drive'),
        ],
        queueIndex: queue.indexWhere((e) => e.id == selected.id),
        relatedQueue: false,
      );
      final route = MaterialPageRoute<void>(builder: (_) => const StandalonePlayerScreen());
      unawaited(Navigator.of(context).push(route));
      try {
        await playback;
      } catch (_) {
        if (mounted && route.isCurrent) Navigator.of(context).pop();
        rethrow;
      }
    } catch (error) {
      _notice(_message(error));
    }
  }

  void _download(DriveMusicItem item, {int? playlist}) {
    unawaited(service.download(item, playlistNumber: playlist).catchError((Object _) => ''));
  }

  Future<void> _addTrack(DriveMusicItem item) async {
    try {
      await service.cacheNames([item]);
      final playlist = await service.files.getActivePlaylistNumber();
      await service.files.addToPlaylist(playlist, item.streamUrl(service.drive.account!.id));
      _notice('Added to your library.');
    } catch (error) {
      _notice(_message(error));
    }
  }

  Future<void> _addFolder(bool download) async {
    if (_adding || _path.isEmpty) return;
    setState(() => _adding = true);
    final folder = _path.last;
    try {
      final audio = <DriveMusicItem>[];
      String? token;
      do {
        final page = await service.folder(folder.id, pageToken: token);
        audio.addAll(page.items.where((e) => e.isAudio && e.canDownload));
        if (audio.length > 10000) {
          throw const GoogleDriveException('This folder has too many tracks. Choose a smaller folder.');
        }
        token = page.nextPageToken;
      } while (token != null);
      final playlist = await service.addStreams(audio, folder.name);
      if (download) {
        for (final item in audio) {
          _download(item, playlist: playlist);
        }
      }
      _notice(
        download ? 'Folder added. Tracks will stream while their downloads finish.' : 'Folder added to your library.',
      );
    } catch (error) {
      _notice(_message(error));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _uploadFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: driveAudioExtensions,
        allowMultiple: true,
      );
      if (result == null) return;
      for (final file in result.files) {
        if (file.path case final path?) unawaited(service.upload(path).then<void>((_) {}, onError: (Object _) {}));
      }
    } catch (error) {
      _notice(_message(error));
    }
  }

  Future<void> _uploadPlaylist() async {
    try {
      final names = await service.files.getPlaylistNames();
      if (!mounted) return;
      final number = await showResonanceDialog<int>(
        context: context,
        builder: (context) => ResonanceChoiceDialog(
          title: Text(context.tr('Choose a playlist')),
          children: [
            for (final entry in names.entries)
              SimpleDialogOption(onPressed: () => Navigator.pop(context, entry.key), child: Text(entry.value)),
          ],
        ),
      );
      if (number == null) return;
      final tracks = await service.files.readPlaylistTracks(number);
      final paths = <String>[];
      for (final path in tracks.toSet()) {
        if (path.startsWith('http://') || path.startsWith('https://')) continue;
        if (await File(path).exists()) paths.add(path);
      }
      if (paths.isEmpty) {
        _notice('This playlist has no local audio to upload.');
        return;
      }
      if (!mounted) return;
      final confirm = await showResonanceDialog<bool>(
        context: context,
        builder: (context) => ResonanceDialog(
          title: Text(context.tr('Upload local tracks?')),
          content: Text(
            context.tr('{0} local tracks will upload to ResonanceMusic/Audio. Streamed tracks are skipped.', [
              paths.length,
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Upload'))),
          ],
        ),
      );
      if (confirm == true) {
        for (final path in paths) {
          unawaited(service.upload(path).then<void>((_) {}, onError: (Object _) {}));
        }
      }
    } catch (error) {
      _notice(_message(error));
    }
  }

  void _transfers() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: AnimatedBuilder(
            animation: service,
            builder: (context, _) => Column(
              children: [
                ListTile(
                  title: Text(context.tr('Drive transfers')),
                  trailing: TextButton(onPressed: service.clearFinished, child: Text(context.tr('Clear finished'))),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: service.transfers.length,
                    itemBuilder: (context, index) {
                      final job = service.transfers[index];
                      final pending =
                          job.state == DriveMusicTransferState.running || job.state == DriveMusicTransferState.queued;
                      return ListTile(
                        leading: Icon(job.upload ? Icons.cloud_upload_outlined : Icons.download_outlined),
                        title: Text(job.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(context.trRendered(job.error ?? _state(job))),
                            if (job.state == DriveMusicTransferState.running)
                              LinearProgressIndicator(value: job.progress),
                          ],
                        ),
                        trailing: pending
                            ? IconButton(
                                tooltip: context.tr('Cancel'),
                                icon: const Icon(Icons.close),
                                onPressed: () => service.cancel(job),
                              )
                            : job.state == DriveMusicTransferState.failed ||
                                  job.state == DriveMusicTransferState.cancelled
                            ? IconButton(
                                tooltip: context.tr('Retry'),
                                icon: const Icon(Icons.refresh),
                                onPressed: () {
                                  unawaited(service.retry(job).then<void>((_) {}, onError: (Object _) {}));
                                },
                              )
                            : const Icon(Icons.check_rounded),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _state(DriveMusicTransfer job) => switch (job.state) {
    DriveMusicTransferState.queued => context.tr('Queued'),
    DriveMusicTransferState.running =>
      '${context.tr(job.upload ? 'Uploading' : 'Downloading')} · ${_bytes(job.transferred)}${job.total == null ? '' : ' / ${_bytes(job.total!)}'}',
    DriveMusicTransferState.complete => context.tr('Complete'),
    DriveMusicTransferState.failed => context.tr('Failed'),
    DriveMusicTransferState.cancelled => context.tr('Cancelled'),
  };
  String _bytes(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: service,
    builder: (context, _) {
      final connected = service.drive.connected;
      final permission = service.drive.musicLibraryAccess;
      final audio = _items.where((e) => e.isAudio).toList();
      final grouped = <String, List<DriveMusicItem>>{};
      if (_path.isEmpty && _search.text.trim().isEmpty) {
        for (final item in audio) {
          for (final parent in item.parents) {
            grouped.putIfAbsent(parent, () => []).add(item);
          }
        }
      }
      final folders = _path.isEmpty ? <DriveMusicItem>[] : _items.where((e) => e.isFolder).toList();
      final loose = _path.isEmpty && _search.text.trim().isEmpty
          ? audio.where((e) => e.parents.isEmpty).toList()
          : audio;
      return PopScope(
        canPop: _path.isEmpty,
        onPopInvokedWithResult: (popped, _) {
          if (!popped) _back();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: _back),
            title: Text(context.tr('Drive music')),
            actions: [
              IconButton(
                tooltip: context.tr('Refresh'),
                onPressed: connected && !_loading ? () => _load() : null,
                icon: const Icon(Icons.refresh_rounded),
              ),
              if (connected)
                PopupMenuButton<String>(
                  tooltip: context.tr('Upload music'),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  onSelected: (value) {
                    if (value == 'files') {
                      unawaited(_uploadFiles());
                    } else {
                      unawaited(_uploadPlaylist());
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'files', child: Text(context.tr('Choose audio files'))),
                    PopupMenuItem(value: 'playlist', child: Text(context.tr('Upload from a playlist'))),
                  ],
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 16),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!connected) ...[
                              const SizedBox(height: 24),
                              const Icon(Icons.cloud_outlined, size: 42),
                              const SizedBox(height: 16),
                              Text(
                                context.tr('Your music, from Google Drive'),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(context.tr('Connect Google Drive to browse, play and upload audio.')),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: service.drive.busy
                                    ? null
                                    : () async {
                                        try {
                                          await service.drive.connect();
                                          if (mounted) await _load();
                                        } catch (error) {
                                          _notice(_message(error));
                                        }
                                      },
                                child: Text(context.tr('Connect Google Drive')),
                              ),
                            ] else ...[
                              Text(service.drive.account!.name, style: Theme.of(context).textTheme.bodySmall),
                              const SizedBox(height: 12),
                              if (!permission)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 20),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        context.tr('Find music already in Drive'),
                                        style: Theme.of(context).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        context.tr(
                                          'Allow read-only access to discover your existing music folders. Uploads work without it.',
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      OutlinedButton.icon(
                                        onPressed: _permission ? null : _browseExisting,
                                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                                        label: Text(context.tr(_permission ? 'Connecting…' : 'Browse existing music')),
                                      ),
                                    ],
                                  ),
                                ),
                              Wrap(
                                spacing: 2,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  TextButton(
                                    onPressed: _path.isEmpty
                                        ? null
                                        : () {
                                            _path.clear();
                                            _search.clear();
                                            unawaited(_load());
                                          },
                                    child: Text(context.tr('Music folders')),
                                  ),
                                  for (var index = 0; index < _path.length; index++) ...[
                                    const Icon(Icons.chevron_right_rounded, size: 18),
                                    TextButton(
                                      onPressed: () {
                                        _path.removeRange(index + 1, _path.length);
                                        _search.clear();
                                        unawaited(_load());
                                      },
                                      child: Text(_path[index].name),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _search,
                                decoration: InputDecoration(
                                  hintText: context.tr(_path.isEmpty ? 'Search Drive music' : 'Search this folder'),
                                  prefixIcon: const Icon(Icons.search),
                                  border: OutlineInputBorder(borderRadius: resonanceBorderRadius(context, 10)),
                                  isDense: true,
                                ),
                                onChanged: (_) {
                                  _debounce?.cancel();
                                  _debounce = Timer(const Duration(milliseconds: 350), () => _load());
                                },
                              ),
                              if (_path.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Wrap(
                                    spacing: 8,
                                    children: [
                                      TextButton.icon(
                                        onPressed: _adding ? null : () => _addFolder(false),
                                        icon: const Icon(Icons.playlist_add),
                                        label: Text(context.tr('Stream folder')),
                                      ),
                                      TextButton.icon(
                                        onPressed: _adding ? null : () => _addFolder(true),
                                        icon: const Icon(Icons.download_outlined),
                                        label: Text(context.tr('Download folder')),
                                      ),
                                    ],
                                  ),
                                ),
                              if (service.transfers.isNotEmpty)
                                Padding(padding: const EdgeInsets.only(top: 12), child: _transferSummary()),
                              if (_error case final error?)
                                Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(context.trRendered(error)),
                                      TextButton(onPressed: () => _load(), child: Text(context.tr('Retry'))),
                                    ],
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (connected) ...[
                      if (_loading || _adding) const SliverToBoxAdapter(child: LinearProgressIndicator()),
                      if (!_loading && _error == null && _items.isEmpty && _next == null)
                        SliverPadding(
                          padding: const EdgeInsets.all(24),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.tr(_search.text.isEmpty ? 'No music found yet.' : 'No matching audio found.'),
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  context.tr(
                                    'Upload audio files to ResonanceMusic/Audio, then play them on your other devices.',
                                  ),
                                ),
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: _uploadFiles,
                                  icon: const Icon(Icons.cloud_upload_outlined),
                                  label: Text(context.tr('Upload music')),
                                ),
                              ],
                            ),
                          ),
                        ),
                      SliverList.list(
                        children: [
                          for (final entry in grouped.entries)
                            _folderRow(
                              _parents[entry.key] ??
                                  DriveMusicItem(
                                    id: entry.key,
                                    name: context.tr('Music folder'),
                                    mimeType: driveFolderMime,
                                  ),
                              count: entry.value.length,
                            ),
                          for (final folder in folders) _folderRow(folder),
                        ],
                      ),
                      SliverList.builder(
                        itemCount: loose.length,
                        itemBuilder: (context, index) => _trackRow(loose[index]),
                      ),
                      if (_next != null && !_loading)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Center(
                              child: TextButton(
                                onPressed: () => _load(more: true),
                                child: Text(context.tr('Load more')),
                              ),
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 28)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  Widget _folderRow(DriveMusicItem folder, {int? count}) => ListTile(
    contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 24, vertical: 4),
    leading: const Icon(Icons.folder_outlined, size: 32),
    title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: count == null
        ? null
        : Text(count == 1 ? context.tr('1 track found') : context.tr('{0} tracks found', [count])),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => _openFolder(folder),
  );
  Widget _trackRow(DriveMusicItem item) => ListTile(
    contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 24, vertical: 2),
    leading: Icon(Icons.music_note_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant),
    title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      [
        item.name.split('.').last.toUpperCase(),
        if (item.bytes != null) _bytes(item.bytes!),
        if (!item.canDownload) context.tr('Download restricted'),
      ].join(' · '),
    ),
    onTap: item.canDownload ? () => _play(item) : null,
    trailing: PopupMenuButton<String>(
      tooltip: context.tr('Track options'),
      onSelected: (value) {
        if (value == 'download') {
          _download(item);
        } else {
          unawaited(_addTrack(item));
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'stream', enabled: item.canDownload, child: Text(context.tr('Add stream to library'))),
        PopupMenuItem(value: 'download', enabled: item.canDownload, child: Text(context.tr('Download to library'))),
      ],
    ),
  );
  Widget _transferSummary() {
    final active = service.transfers.where((job) => job.state == DriveMusicTransferState.running).firstOrNull;
    final failed = service.transfers.where((job) => job.state == DriveMusicTransferState.failed).length;
    return InkWell(
      borderRadius: resonanceBorderRadius(context, 8),
      onTap: _transfers,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_vert_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    active == null ? context.tr('Drive transfers') : active.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(active == null ? '${service.transfers.length}' : '${((active.progress ?? 0) * 100).round()}%'),
                const Icon(Icons.chevron_right_rounded, size: 18),
              ],
            ),
            if (active != null)
              Text(
                _state(active),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (active != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(value: active.progress),
              ),
            if (failed > 0)
              Text(context.tr('{0} transfers need attention', [failed]), style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
