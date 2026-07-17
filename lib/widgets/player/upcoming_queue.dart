import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:resonance/models/playback_queue_snapshot.dart';

class UpcomingQueuePanel extends StatelessWidget {
  final Stream<MediaItem?> mediaItemStream;
  final MediaItem? initialMediaItem;
  final ValueListenable<int> revision;
  final Future<PlaybackQueueSnapshot> Function() loadSnapshot;
  final Future<void> Function(PlaybackQueueEntry entry)? onPlay;
  final VoidCallback? onClose;
  final bool compact;

  const UpcomingQueuePanel({
    super.key,
    required this.mediaItemStream,
    required this.initialMediaItem,
    required this.revision,
    required this.loadSnapshot,
    this.onPlay,
    this.onClose,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: mediaItemStream,
      initialData: initialMediaItem,
      builder: (context, mediaSnapshot) => ValueListenableBuilder<int>(
        valueListenable: revision,
        builder: (context, queueRevision, _) => FutureBuilder<PlaybackQueueSnapshot>(
          key: ValueKey('${mediaSnapshot.data?.id ?? ''}-$queueRevision'),
          future: loadSnapshot(),
          builder: (context, snapshot) => _QueueSurface(
            snapshot: snapshot.data,
            loading: snapshot.connectionState != ConnectionState.done,
            error: snapshot.hasError ? snapshot.error : null,
            onPlay: onPlay,
            onClose: onClose,
            compact: compact,
          ),
        ),
      ),
    );
  }
}

class _QueueSurface extends StatelessWidget {
  final PlaybackQueueSnapshot? snapshot;
  final bool loading;
  final Object? error;
  final Future<void> Function(PlaybackQueueEntry entry)? onPlay;
  final VoidCallback? onClose;
  final bool compact;

  const _QueueSurface({
    required this.snapshot,
    required this.loading,
    required this.error,
    required this.onPlay,
    required this.onClose,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final queue = snapshot ?? PlaybackQueueSnapshot.empty;
    return Material(
      color: theme.colorScheme.surface,
      elevation: compact ? 12 : 1,
      borderRadius: compact ? const BorderRadius.vertical(top: Radius.circular(24)) : null,
      child: Column(
        children: [
          if (compact) ...[
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ],
          Padding(
            padding: EdgeInsets.fromLTRB(16, compact ? 8 : 14, 8, 8),
            child: Row(
              children: [
                Icon(Icons.queue_music_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Upcoming tracks',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                if (queue.shuffled)
                  Tooltip(
                    message: 'Showing the active shuffled order',
                    child: Icon(Icons.shuffle_rounded, size: 18, color: theme.colorScheme.primary),
                  ),
                if (onClose != null)
                  IconButton(
                    key: const Key('close-upcoming-queue'),
                    onPressed: onClose,
                    tooltip: 'Close queue',
                    icon: Icon(compact ? Icons.keyboard_arrow_down_rounded : Icons.close_rounded),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (loading && queue.current == null)
            const Expanded(child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (error != null)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not load the queue.\n$error', textAlign: TextAlign.center),
                ),
              ),
            )
          else if (queue.current == null)
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Play a track to see what comes next.', textAlign: TextAlign.center),
                ),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: _QueueTrackTile(entry: queue.current!, current: true),
            ),
            if (queue.upcoming.isEmpty)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      queue.loopBehavior == QueueLoopBehavior.one
                          ? 'Repeat one is on — the current track will play again.'
                          : 'This is the last track in the current playback order.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: queue.upcoming.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final entry = queue.upcoming[index];
                    return _QueueTrackTile(
                      entry: entry,
                      position: index + 1,
                      onTap: onPlay == null ? null : () => onPlay!(entry),
                    );
                  },
                ),
              ),
            _QueueFooter(loopBehavior: queue.loopBehavior, shuffled: queue.shuffled),
          ],
        ],
      ),
    );
  }
}

class _QueueTrackTile extends StatelessWidget {
  final PlaybackQueueEntry entry;
  final int? position;
  final bool current;
  final VoidCallback? onTap;

  const _QueueTrackTile({required this.entry, this.position, this.current = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Material(
      color: current ? accent.withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.09) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              _QueueArtwork(uri: entry.artworkUri, current: current),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: current ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                    if (entry.artist.isNotEmpty)
                      Text(
                        entry.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (current)
                Text(
                  'NOW',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.7,
                  ),
                )
              else if (position != null)
                Text('$position', style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueArtwork extends StatelessWidget {
  final Uri? uri;
  final bool current;

  const _QueueArtwork({required this.uri, required this.current});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    Widget fallback() => ColoredBox(
      color: accent.withValues(alpha: 0.12),
      child: Icon(Icons.music_note_rounded, size: 19, color: accent),
    );

    final artwork = uri == null
        ? fallback()
        : uri!.scheme == 'file'
        ? Image.file(File.fromUri(uri!), fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback())
        : uri!.scheme == 'http' || uri!.scheme == 'https'
        ? Image.network(uri.toString(), fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback())
        : fallback();
    return Container(
      width: current ? 44 : 38,
      height: current ? 44 : 38,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: current ? Border.all(color: accent.withValues(alpha: 0.55), width: 1.5) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: artwork,
    );
  }
}

class _QueueFooter extends StatelessWidget {
  final QueueLoopBehavior loopBehavior;
  final bool shuffled;

  const _QueueFooter({required this.loopBehavior, required this.shuffled});

  @override
  Widget build(BuildContext context) {
    final label = switch (loopBehavior) {
      QueueLoopBehavior.one => 'Repeating the current track',
      QueueLoopBehavior.all => 'Queue repeats after the final track',
      QueueLoopBehavior.off => 'Queue ends after the final track',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 11),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Icon(
            loopBehavior == QueueLoopBehavior.one
                ? Icons.repeat_one_rounded
                : loopBehavior == QueueLoopBehavior.all
                ? Icons.repeat_rounded
                : Icons.arrow_forward_rounded,
            size: 15,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 7),
          Expanded(child: Text(label, style: Theme.of(context).textTheme.labelSmall)),
        ],
      ),
    );
  }
}
