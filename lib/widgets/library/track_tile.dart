// lib/widgets/library/track_tile.dart
//
// Redesigned track tile — Obsidian Pulse aesthetic.
// Now-playing state: violet left-accent border + subtle glow background.
// Logic: UNCHANGED.

import 'dart:async';
import 'dart:io';

import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:metadata_god/metadata_god.dart';

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

  void _showMetadataEditor(
    BuildContext context,
    String currentTitle,
    String currentArtist,
  ) {
    final titleController = TextEditingController(text: currentTitle);
    final artistController = TextEditingController(text: currentArtist);

    showDialog(
      context: context,
      builder: (context) {
        // ignore: unused_local_variable
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.edit_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              const Text('Edit Metadata'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  prefixIcon: Icon(Icons.music_note_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: artistController,
                decoration: const InputDecoration(
                  labelText: 'Artist',
                  prefixIcon: Icon(Icons.person_rounded, size: 18),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  await MetadataGod.writeMetadata(
                    file: widget.trackPath,
                    metadata: Metadata(
                      title: titleController.text,
                      artist: artistController.text,
                    ),
                  );
                  await MetadataCacheService.set(
                    widget.trackPath,
                    titleController.text,
                    artistController.text,
                  );
                  if (mounted) {
                    setState(() {
                      _title = titleController.text;
                      _artist = artistController.text;
                    });
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to update metadata: $e'),
                      ),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final fileName = p.basenameWithoutExtension(widget.trackPath);

    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, mediaSnapshot) {
        final isPlaying = mediaSnapshot.data?.id == widget.trackPath;

        if (_loading) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            child: Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1A1A2A)
                    : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF2D2D42)
                      : const Color(0xFFDDD9F3),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF242436)
                          : const Color(0xFFEEECF8),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 12,
                          width: 140,
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF242436)
                                : const Color(0xFFEEECF8),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          height: 10,
                          width: 80,
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF1E1E30)
                                : const Color(0xFFF5F3FF),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final title = _title ?? fileName;
        final artist = _artist ?? 'Unknown Artist';

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: isPlaying
                  ? (isDark
                      ? primary.withValues(alpha: 0.12)
                      : primary.withValues(alpha: 0.06))
                  : (isDark ? const Color(0xFF1A1A2A) : Colors.white),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isPlaying
                    ? primary.withValues(alpha: 0.45)
                    : (isDark
                        ? const Color(0xFF2D2D42)
                        : const Color(0xFFDDD9F3)),
                width: isPlaying ? 1.5 : 1,
              ),
              boxShadow: isPlaying
                  ? [
                      BoxShadow(
                        color: primary.withValues(alpha: isDark ? 0.12 : 0.08),
                        blurRadius: 12,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : [],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => handler.loadTrack(widget.trackPath, title, artist),
                onLongPress: () => _showMetadataEditor(context, title, artist),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      // ── Drag handle ─────────────────────────────────
                      ReorderableDragStartListener(
                        index: widget.index,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            Icons.drag_handle_rounded,
                            size: 18,
                            color: isPlaying
                                ? primary.withValues(alpha: 0.5)
                                : (isDark
                                    ? const Color(0xFF3D3D55)
                                    : const Color(0xFFBDB8E0)),
                          ),
                        ),
                      ),

                      // ── Album icon / playing indicator ──────────────
                      _TrackIcon(isPlaying: isPlaying),
                      const SizedBox(width: 12),

                      // ── Title + artist ──────────────────────────────
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isPlaying
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                fontSize: 13,
                                color: isPlaying
                                    ? primary
                                    : (isDark
                                        ? const Color(0xFFE2E8F0)
                                        : const Color(0xFF0F172A)),
                                letterSpacing: -0.1,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF64748B),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // ── Delete button ────────────────────────────────
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        tooltip: 'Remove',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        color: isDark
                            ? const Color(0xFF475569)
                            : const Color(0xFF94A3B8),
                        onPressed: () {
                          MetadataCacheService.remove(widget.trackPath);
                          widget.onDelete();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Small icon box: pulsing graphic_eq when playing, music note otherwise.
class _TrackIcon extends StatelessWidget {
  final bool isPlaying;

  const _TrackIcon({required this.isPlaying});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: isPlaying
            ? primary.withValues(alpha: isDark ? 0.2 : 0.12)
            : (isDark
                ? const Color(0xFF242436)
                : const Color(0xFFEEECF8)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Icon(
          isPlaying ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
          key: ValueKey(isPlaying),
          size: 17,
          color: isPlaying
              ? primary
              : (isDark
                  ? const Color(0xFF64748B)
                  : const Color(0xFF94A3B8)),
        ),
      ),
    );
  }
}