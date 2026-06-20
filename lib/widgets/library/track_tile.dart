import 'dart:async';
import 'dart:io';

import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';

class TrackTile extends StatefulWidget {
  final String trackPath;
  final int index;
  final VoidCallback onDelete;

  const TrackTile({
    super.key,
    required this.trackPath,
    required this.index,
    required this.onDelete,
  });

  @override
  State<TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<TrackTile> {
  bool _loading = true;
  String? _title;
  String? _artist;

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  @override
  void didUpdateWidget(covariant TrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackPath != widget.trackPath) {
      setState(() {
        _loading = true;
        _title = null;
        _artist = null;
      });
      _loadMetadata();
    }
  }

  Future<void> _loadMetadata() async {
    final fileName = p.basenameWithoutExtension(widget.trackPath);

    final cached = await MetadataCacheService.get(widget.trackPath);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _title = cached.title;
          _artist = cached.artist;
          _loading = false;
        });
      }
      return;
    }

    try {
      final metadata = await AudioMetadata.extract(File(widget.trackPath));
      final title = (metadata?.trackName?.trim().isNotEmpty ?? false)
          ? metadata!.trackName!
          : fileName;
      final artist = (metadata?.firstArtists?.trim().isNotEmpty ?? false)
          ? metadata!.firstArtists!
          : 'Unknown Artist';

      unawaited(MetadataCacheService.set(widget.trackPath, title, artist));

      if (mounted) {
        setState(() {
          _title = title;
          _artist = artist;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _title = fileName;
          _artist = 'Unknown Artist';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    final colorScheme = Theme.of(context).colorScheme;
    final fileName = p.basenameWithoutExtension(widget.trackPath);

    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, mediaSnapshot) {
        final isPlaying = mediaSnapshot.data?.id == widget.trackPath;

        if (_loading) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.music_note),
              title: Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text('Loading metadata...'),
            ),
          );
        }

        final title = _title ?? fileName;
        final artist = _artist ?? 'Unknown Artist';

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: isPlaying
                  ? colorScheme.primary.withValues(alpha: 0.15)
                  : Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isPlaying ? colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                onTap: () {
                  handler.loadTrack(widget.trackPath, title, artist);
                },
                // ── Leading: drag handle + now-playing indicator ─────────
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Drag handle — wrapped in ReorderableDragStartListener so
                    // only intentional drags on this icon start a reorder.
                    // This avoids gesture conflicts with onTap (play) and the
                    // trailing delete button.
                    ReorderableDragStartListener(
                      index: widget.index,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4.0),
                        child: Icon(
                          Icons.drag_handle,
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                    // Now-playing icon
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        isPlaying ? Icons.graphic_eq : Icons.music_note,
                        key: ValueKey(isPlaying),
                        color: isPlaying ? colorScheme.primary : null,
                      ),
                    ),
                  ],
                ),
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                    color: isPlaying ? colorScheme.primary : null,
                  ),
                ),
                subtitle: Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove',
                  onPressed: () {
                    MetadataCacheService.remove(widget.trackPath);
                    widget.onDelete();
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}