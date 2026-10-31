import 'package:resonance/widgets/common/resonance_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/screens/playlist_transfer/playlist_export_screen.dart';
import 'package:resonance/screens/playlist_transfer/playlist_import_screen.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';
import 'package:resonance/services/google_drive/google_drive_service.dart';
import 'package:resonance/services/google_drive/playlist_sync_service.dart';
import 'package:resonance/services/playlist_transfer_export_service.dart';

class GoogleDrivePlaylistsScreen extends StatefulWidget {
  const GoogleDrivePlaylistsScreen({super.key, this.service, this.sync, this.files});
  final GoogleDriveService? service;
  final PlaylistSyncService? sync;
  final FileService? files;
  @override
  State<GoogleDrivePlaylistsScreen> createState() => _GoogleDrivePlaylistsScreenState();
}

class _GoogleDrivePlaylistsScreenState extends State<GoogleDrivePlaylistsScreen> {
  late final service = widget.service ?? GoogleDriveService.instance;
  late final files = widget.files ?? FileService();
  late final sync =
      widget.sync ?? (identical(service, GoogleDriveService.instance) ? PlaylistSyncService.instance : null);
  bool _working = false;
  String? _localError;
  bool get _busy => _working || service.busy;

  @override
  void initState() {
    super.initState();
    // Defer initial notifications until the route is in the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
      if (sync != null) unawaited(sync!.start());
    });
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _localError = null);
    try {
      await service.refresh();
      await sync?.syncNow();
    } catch (_) {
      /* Render the service error. */
    }
  }

  Future<void> _open(DrivePlaylist playlist) async {
    if (_busy) return;
    if (sync?.forFile(playlist.id) case final link?) {
      await _syncOptions(link);
      return;
    }
    setState(() {
      _working = true;
      _localError = null;
    });
    try {
      final snapshot = await service.openSnapshot(playlist);
      final manifest = snapshot.manifest;
      if (!mounted) return;
      if (manifest.youtubeVideoIds.isEmpty) {
        setState(() => _working = false);
        var keep = false;
        final add = await showResonanceDialog<bool>(
          context: context,
          builder: (dialog) => StatefulBuilder(
            builder: (dialog, update) => ResonanceDialog(
              title: Text(manifest.playlistName),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(dialog.tr('This playlist is empty.')),
                  if (sync != null)
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(dialog.tr('Keep in sync')),
                      value: keep,
                      onChanged: (value) => update(() => keep = value),
                    ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(dialog.tr('Cancel'))),
                FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(dialog.tr('Add playlist'))),
              ],
            ),
          ),
        );
        if (add == true && mounted) {
          setState(() => _working = true);
          final created = await files.createImportedPlaylist(manifest.playlistName, []);
          if (keep) {
            await sync!.link(
              number: created.number,
              remote: playlist,
              mode: PlaylistSyncMode.stream,
              initial: snapshot,
            );
          }
        }
        return;
      }
      ({int number, bool streaming, bool keep})? result;
      final imported = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PlaylistImportScreen(
            files: files,
            initialManifest: manifest,
            onImported: sync == null
                ? null
                : (number, streaming, keep) => result = (number: number, streaming: streaming, keep: keep),
          ),
        ),
      );
      if (result case final saved? when saved.keep) {
        await sync!.link(
          number: saved.number,
          remote: playlist,
          mode: saved.streaming ? PlaylistSyncMode.stream : PlaylistSyncMode.download,
          initial: snapshot,
        );
      }
      if (mounted && imported == true) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('Playlist added to your library.'))));
      }
    } on GoogleDriveCancelled {
      return;
    } catch (_) {
      if (mounted && service.error == null) {
        setState(() => _localError = 'Could not open this playlist. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _upload({DrivePlaylist? replace}) async {
    if (_busy) return;
    setState(() {
      _working = true;
      _localError = null;
    });
    try {
      final names = await files.getPlaylistNames();
      if (!mounted) return;
      final selected = await showResonanceDialog<int>(
        context: context,
        builder: (dialog) => ResonanceChoiceDialog(
          title: Text(context.tr('Save a playlist to Drive')),
          children: [
            for (final entry in names.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialog, entry.key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(entry.key == FileService.favoritesPlaylistNumber ? context.tr('Favorites') : entry.value),
                ),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      final tracks = await files.readPlaylistTracks(selected);
      if (tracks.isEmpty) throw const GoogleDriveException('Add at least one track before transferring this playlist.');
      final scan = await const PlaylistTransferExportService().scanPlaylist(names[selected]!, tracks);
      if (!mounted) return;
      if (scan.unresolved.isNotEmpty) {
        final confirmed = await Navigator.of(
          context,
        ).push<bool>(MaterialPageRoute(builder: (_) => PlaylistSourceResolutionScreen(scan: scan)));
        if (confirmed != true || !mounted) return;
      }
      final manifest = scan.createManifest();
      if (manifest.youtubeVideoIds.isEmpty) {
        throw const GoogleDriveException('No matched tracks are available to save.');
      }
      // Refresh before offering replacement; never silently replace by name.
      await service.refresh();
      if (!mounted) return;
      final existing = replace == null
          ? service.playlists.where((item) => item.name == scan.playlistName.trim()).firstOrNull
          : service.playlists.where((item) => item.id == replace.id).firstOrNull;
      if (replace != null && existing == null) {
        throw const GoogleDriveException('This Drive playlist no longer exists.');
      }
      var keepInSync = existing != null && sync?.forFile(existing.id) != null;
      final action = await showResonanceDialog<String>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (dialog, setDialogState) => ResonanceDialog(
            title: Text(
              context.tr(existing == null ? 'Save playlist to Google Drive?' : 'This playlist is already on Drive'),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(scan.playlistName, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                Text(context.tr('{0} tracks ready to transfer', [manifest.youtubeVideoIds.length])),
                if (scan.skippedEntryCount > 0)
                  Text(context.tr('{0} unmatched tracks will be skipped.', [scan.skippedEntryCount])),
                const SizedBox(height: 12),
                Text(context.tr('Saves track links and their order. Audio files stay on this device.')),
                if (sync != null)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.tr('Keep in sync')),
                    subtitle: Text(context.tr('Sync playlist edits between your connected devices.')),
                    value: keepInSync,
                    onChanged: (value) => setDialogState(() => keepInSync = value),
                  ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog), child: Text(context.tr('Cancel'))),
              if (existing != null)
                TextButton(onPressed: () => Navigator.pop(dialog, 'copy'), child: Text(context.tr('Save a copy'))),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, existing == null ? 'copy' : 'replace'),
                child: Text(context.tr(existing == null ? 'Save to Drive' : 'Replace stored playlist')),
              ),
            ],
          ),
        ),
      );
      if (action == null || !mounted) return;
      final target = action == 'replace' ? existing : null;
      final oldLink = target == null ? null : sync?.forFile(target.id);
      Future<void> save() async {
        final uploaded = await service.upload(manifest, replace: target);
        if (oldLink != null) await sync!.unlink(oldLink);
        if (keepInSync) {
          final streaming = tracks.any((track) => track.startsWith('https://'));
          try {
            await sync!.link(
              number: selected,
              remote: uploaded,
              mode: oldLink?.mode ?? (streaming ? PlaylistSyncMode.stream : PlaylistSyncMode.download),
            );
          } catch (_) {
            throw const GoogleDriveException(
              'Playlist saved to Drive, but sync could not be enabled. Try linking it again.',
            );
          }
        }
      }

      if (sync == null) {
        await save();
      } else {
        await sync!.withPaused(target?.id, save);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('Playlist saved to Google Drive.'))));
      }
    } on GoogleDriveCancelled {
      return;
    } catch (error) {
      if (mounted) {
        setState(
          () => _localError = error is GoogleDriveException ? error.message : 'Could not prepare this playlist.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _delete(DrivePlaylist playlist) async {
    if (_busy) return;
    final confirmed = await showResonanceDialog<bool>(
      context: context,
      builder: (dialog) => ResonanceDialog(
        title: Text(dialog.tr('Delete from Drive?')),
        content: Text(
          dialog.tr(
            '“{0}” will move to Google Drive Trash. Local playlists and downloaded audio stay on your devices.',
            [playlist.name],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(dialog.tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(dialog.tr('Delete from Drive'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _working = true;
      _localError = null;
    });
    try {
      Future<void> remove() async {
        await service.trashPlaylist(playlist);
        if (sync?.forFile(playlist.id) case final link?) {
          await sync!.unlink(link);
        }
      }

      if (sync == null) {
        await remove();
      } else {
        await sync!.withPaused(playlist.id, remove);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('Playlist moved to Drive Trash.'))));
      }
    } on GoogleDriveCancelled {
      /* Logout cancels the operation. */
    } catch (error) {
      if (mounted) {
        setState(
          () => _localError = error is GoogleDriveException
              ? error.message
              : 'Could not delete this Drive playlist. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _syncOptions(SyncedPlaylist link) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: AnimatedBuilder(
          animation: sync!,
          builder: (sheet, _) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(link.document.name, style: Theme.of(sheet).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(sheet.tr('Keep in sync')),
                    subtitle: Text(sheet.tr('Turning sync off keeps your local playlist and Drive copy.')),
                    value: true,
                    onChanged: (_) async {
                      await sync!.unlink(link);
                      if (sheet.mounted) Navigator.pop(sheet);
                    },
                  ),
                  const Divider(),
                  Text(sheet.tr('New tracks on this device'), style: Theme.of(sheet).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<PlaylistSyncMode>(
                    segments: [
                      ButtonSegment(
                        value: PlaylistSyncMode.stream,
                        icon: const Icon(Icons.sensors_rounded),
                        label: Text(sheet.tr('Stream')),
                      ),
                      ButtonSegment(
                        value: PlaylistSyncMode.download,
                        icon: const Icon(Icons.download_rounded),
                        label: Text(sheet.tr('Download')),
                      ),
                    ],
                    selected: {link.mode},
                    onSelectionChanged: (values) => unawaited(sync!.setMode(link, values.single)),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    sheet.tr(
                      'Sync checks while Resonance is running and when you reopen it. Audio files are never deleted by sync.',
                    ),
                    style: Theme.of(sheet).textTheme.bodySmall,
                  ),
                  if (link.unmatched > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        sheet.tr('{0} local-only tracks stay on this device until matched to YouTube.', [
                          link.unmatched,
                        ]),
                      ),
                    ),
                  if (link.error != null)
                    Padding(padding: const EdgeInsets.only(top: 8), child: Text(sheet.trRendered(link.error!))),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: link.status == PlaylistSyncStatus.syncing ? null : () => sync!.syncNow(),
                    icon: const Icon(Icons.sync_rounded),
                    label: Text(sheet.tr('Sync now')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _syncLabel(SyncedPlaylist link) => switch (link.status) {
    PlaylistSyncStatus.waiting => 'Waiting for connection',
    PlaylistSyncStatus.syncing => 'Syncing…',
    PlaylistSyncStatus.synced => 'Synced',
    PlaylistSyncStatus.attention => 'Sync needs attention',
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([service, if (sync != null) sync!]),
    builder: (context, _) {
      final theme = Theme.of(context);
      final error = _localError ?? service.error;
      final visible = [...service.playlists];
      for (final link in sync?.playlists ?? <SyncedPlaylist>[]) {
        if (!visible.any((playlist) => playlist.id == link.fileId)) {
          visible.add(
            DrivePlaylist(id: link.fileId, name: link.document.name, trackCount: link.document.active.length),
          );
        }
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(context.tr('Drive playlists')),
          actions: [
            IconButton(
              tooltip: context.tr('Refresh'),
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ResonanceMusic', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          context.tr('Open a playlist to stream its tracks or download them to this device.'),
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _busy || !service.connected ? null : _upload,
                          icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                          label: Text(context.tr('Save a playlist to Drive')),
                        ),
                      ],
                    ),
                  ),
                  if (_busy) const LinearProgressIndicator(minHeight: 2),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline_rounded, size: 20),
                          const SizedBox(width: 10),
                          Expanded(child: Text(context.trRendered(error))),
                          TextButton(onPressed: _busy ? null : _refresh, child: Text(context.tr('Retry'))),
                        ],
                      ),
                    ),
                  if (visible.isEmpty && !_busy && error == null)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        context.tr('No playlists saved yet. Save one here, then open Resonance on your other device.'),
                      ),
                    ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final playlist = visible[index];
                          final date = playlist.modifiedAt;
                          final link = sync?.forFile(playlist.id);
                          return ListTile(
                            key: ValueKey(playlist.id),
                            leading: const Icon(Icons.queue_music_rounded),
                            title: Text(
                              link?.document.name ?? playlist.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                if (playlist.trackCount != null) context.tr('{0} tracks', [playlist.trackCount]),
                                if (date != null)
                                  DateFormat.yMMMd(Localizations.localeOf(context).languageCode).format(date.toLocal()),
                                if (link != null) context.tr(_syncLabel(link)),
                              ].join(' · '),
                            ),
                            trailing: PopupMenuButton<String>(
                              tooltip: context.tr('Playlist options'),
                              enabled: !_busy,
                              onSelected: (action) =>
                                  unawaited(action == 'delete' ? _delete(playlist) : _upload(replace: playlist)),
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'replace',
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.cloud_upload_outlined),
                                    title: Text(context.tr('Replace from library')),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.delete_outline_rounded),
                                    title: Text(context.tr('Delete from Drive')),
                                  ),
                                ),
                              ],
                            ),
                            enabled: !_busy,
                            onTap: () => _open(playlist),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
