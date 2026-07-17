import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/models/download_history_entry.dart';
import 'package:resonance/services/download_history_repository.dart';

class DownloadHistoryScreen extends StatefulWidget {
  const DownloadHistoryScreen({super.key});

  @override
  State<DownloadHistoryScreen> createState() => _DownloadHistoryScreenState();
}

class _DownloadHistoryScreenState extends State<DownloadHistoryScreen> {
  final _repository = const DownloadHistoryRepository();
  final _searchController = TextEditingController();
  List<DownloadHistoryEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_refreshSearch);
    _load();
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_refreshSearch)
      ..dispose();
    super.dispose();
  }

  void _refreshSearch() => setState(() {});

  Future<void> _load() async {
    final entries = await _repository.load();
    if (mounted) {
      setState(() {
        _entries = entries;
        _loading = false;
      });
    }
  }

  Iterable<DownloadHistoryEntry> get _visibleEntries {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _entries;
    return _entries.where((entry) {
      return [
        entry.title,
        entry.artist,
        entry.source,
        entry.localPath,
        entry.failureMessage ?? '',
      ].join('\n').toLowerCase().contains(query);
    });
  }

  Future<void> _play(DownloadHistoryEntry entry) async {
    if (entry.localPath.isEmpty || !File(entry.localPath).existsSync()) return;
    await context.read<PlayerHandler>().playMediaItem(
      MediaItem(id: entry.localPath, title: entry.title, artist: entry.artist),
    );
  }

  Future<void> _openContainingFolder(DownloadHistoryEntry entry) async {
    if (!Platform.isWindows || entry.localPath.isEmpty) return;
    final file = File(entry.localPath);
    final arguments = file.existsSync() ? <String>['/select,', entry.localPath] : <String>[file.parent.path];
    try {
      await Process.start('explorer.exe', arguments, mode: ProcessStartMode.detached);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open folder: $error')));
      }
    }
  }

  Future<void> _remove(DownloadHistoryEntry entry) async {
    await _repository.remove(entry.id);
    await _load();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear download history?'),
        content: const Text('This removes history entries only. Downloaded audio files will not be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear History')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleEntries.toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Download History'),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(onPressed: _clear, tooltip: 'Clear history', icon: const Icon(Icons.delete_sweep_rounded)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search title, artist, source, or path',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: _searchController.clear,
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                ? _EmptyHistory(searching: _searchController.text.trim().isNotEmpty)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _HistoryCard(
                      entry: visible[index],
                      onPlay: () => _play(visible[index]),
                      onOpenFolder: Platform.isWindows ? () => _openContainingFolder(visible[index]) : null,
                      onRemove: () => _remove(visible[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final DownloadHistoryEntry entry;
  final VoidCallback onPlay;
  final VoidCallback? onOpenFolder;
  final VoidCallback onRemove;

  const _HistoryCard({required this.entry, required this.onPlay, this.onOpenFolder, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final exists = entry.localPath.isNotEmpty && File(entry.localPath).existsSync();
    final statusColor = entry.succeeded ? (exists ? Colors.green : Colors.orange) : scheme.error;
    final status = entry.succeeded ? (exists ? 'Downloaded' : 'File missing') : 'Failed';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                entry.succeeded ? Icons.download_done_rounded : Icons.error_outline_rounded,
                color: statusColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _StatusLabel(label: status, color: statusColor),
                      Text(_formatTimestamp(entry.downloadedAt), style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
                  if (entry.failureMessage case final message?) ...[
                    const SizedBox(height: 6),
                    Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.error, fontSize: 11),
                    ),
                  ],
                  if (entry.source.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      entry.source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              onPressed: exists ? onPlay : null,
              tooltip: 'Play downloaded track',
              icon: const Icon(Icons.play_arrow_rounded),
            ),
            PopupMenuButton<_HistoryAction>(
              tooltip: 'History actions',
              onSelected: (action) {
                switch (action) {
                  case _HistoryAction.openFolder:
                    onOpenFolder?.call();
                  case _HistoryAction.remove:
                    onRemove();
                }
              },
              itemBuilder: (_) => [
                if (onOpenFolder != null)
                  const PopupMenuItem(
                    value: _HistoryAction.openFolder,
                    child: ListTile(leading: Icon(Icons.folder_open_rounded), title: Text('Open containing folder')),
                  ),
                const PopupMenuItem(
                  value: _HistoryAction.remove,
                  child: ListTile(leading: Icon(Icons.delete_outline_rounded), title: Text('Remove history entry')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusLabel({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
    ),
  );
}

class _EmptyHistory extends StatelessWidget {
  final bool searching;

  const _EmptyHistory({required this.searching});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            searching ? Icons.search_off_rounded : Icons.history_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            searching ? 'No matching downloads' : 'No downloads yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 5),
          Text(
            searching
                ? 'Try another title, artist, source, or path.'
                : 'Tracks downloaded through Resonance will appear here.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

enum _HistoryAction { openFolder, remove }

String _formatTimestamp(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
