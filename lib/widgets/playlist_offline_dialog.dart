import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/services/playlist_offline_service.dart';

Future<void> showPlaylistOfflineDialog(BuildContext context, int number, {PlaylistOfflineService? service}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _PlaylistOfflineDialog(number: number, service: service),
    );

class _PlaylistOfflineDialog extends StatefulWidget {
  const _PlaylistOfflineDialog({required this.number, this.service});
  final PlaylistOfflineService? service;
  final int number;
  @override
  State<_PlaylistOfflineDialog> createState() => _PlaylistOfflineDialogState();
}

class _PlaylistOfflineDialogState extends State<_PlaylistOfflineDialog> {
  late final service = widget.service ?? PlaylistOfflineService.instance;
  late final queue = service.queue;
  int total = 0, local = 0, localBytes = 0;
  String name = '';
  bool ready = false, removing = false;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final files = service.files;
      final tracks = await files.readPlaylistTracks(widget.number);
      var available = 0, size = 0;
      for (final path in tracks) {
        if (!path.startsWith('http') && await File(path).exists()) {
          available++;
          size += await File(path).length();
        }
      }
      final names = await files.getPlaylistNames();
      if (mounted) {
        setState(() {
          total = tracks.length;
          local = available;
          localBytes = size;
          name = names[widget.number] ?? '';
          ready = true;
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = '$failure';
          ready = true;
        });
      }
    }
  }

  Future<void> _start() async {
    setState(() => error = null);
    try {
      await service.makeOffline(widget.number);
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    }
    await _refresh();
  }

  Future<void> _remove() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Remove offline downloads?')),
        content: Text(
          context.tr(
            'Return app-downloaded tracks in this playlist to streams. Imported files and downloads still used by other playlists or Favorites are kept.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Remove'))),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => removing = true);
    try {
      await service.removeManagedDownloads(widget.number);
      await _refresh();
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => removing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([service, queue]),
    builder: (context, _) {
      final state = service.progress[widget.number];
      final running = state?.running == true;
      final active = state?.current == null ? null : queue.pendingEntryFor(state!.current!, widget.number);
      final completed = running ? state!.completed : local;
      final count = running ? state!.total : total;
      final fullyOffline = !running && ready && total > 0 && local == total;
      return AlertDialog(
        title: Text(
          widget.number == 0
              ? context.tr('Favorites')
              : name.isEmpty
              ? context.tr('Offline playlist')
              : name,
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr(fullyOffline ? 'Ready to play offline' : '{0}/{1} tracks available offline', [
                    completed,
                    count,
                  ]),
                ),
                const SizedBox(height: 12),
                if (!ready || removing)
                  const LinearProgressIndicator()
                else if (running)
                  LinearProgressIndicator(value: active == null ? null : active.progress / 100)
                else if (count > 0)
                  LinearProgressIndicator(value: local / count),
                const SizedBox(height: 12),
                Text(context.tr('Local storage used: {0} MB', [(localBytes / (1024 * 1024)).toStringAsFixed(1)])),
                if (running)
                  Text(
                    context.tr('{0} remaining · {1} failed', [
                      (count - completed - state!.failures.length).clamp(0, count),
                      state.failures.length,
                    ]),
                  ),
                if (active != null) Text(active.track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (state?.stopping == true && running) Text(context.tr('Stopping after the current download…')),
                if (error != null) Text(error!),
                if (state?.failures.isNotEmpty == true) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.tr('{0} tracks could not be downloaded. Retry skips completed tracks.', [
                      state!.failures.length,
                    ]),
                  ),
                  for (final failure in state.failures.entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('${failure.key}\n${failure.value}', maxLines: 3, overflow: TextOverflow.ellipsis),
                    ),
                ],
                const SizedBox(height: 8),
                Text(context.tr('Downloads continue if you close this dialog.')),
              ],
            ),
          ),
        ),
        actions: [
          if (!running && local > 0)
            TextButton(onPressed: removing ? null : _remove, child: Text(context.tr('Remove downloads'))),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Close'))),
          if (running)
            TextButton(
              onPressed: state!.stopping ? null : () => service.cancel(widget.number),
              child: Text(context.tr('Stop after current')),
            )
          else
            FilledButton(
              onPressed: !ready || removing || fullyOffline || total == 0 ? null : _start,
              child: Text(context.tr(state?.failures.isNotEmpty == true ? 'Retry' : 'Make available offline')),
            ),
        ],
      );
    },
  );
}
