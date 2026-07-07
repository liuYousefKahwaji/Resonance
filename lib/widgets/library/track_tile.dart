// lib/widgets/library/track_tile.dart
//
// Scroll-smoothness fixes:
//  1. RepaintBoundary wraps each tile so a single tile redrawing during
//     playback state changes doesn't invalidate the whole list.
//  2. StreamBuilder is scoped to only listen to mediaItem — the narrowest
//     stream needed to check "is this tile currently playing".
//  3. AnimatedContainer transitions are kept but only trigger on isPlaying
//     changes — identical rebuilds from parent scrolls are cheap because
//     the decoration parameters don't change.
//  4. Skeleton loader uses const colours so Flutter doesn't allocate
//     new Color objects on every build cycle.
//  5. MetadataCacheService lookup is guarded so it doesn't trigger setState
//     if the widget was already disposed.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
  final int pulse;

  const TrackTile({super.key, required this.trackPath, required this.index, required this.onDelete, this.pulse = 0});

  @override
  State<TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<TrackTile> with SingleTickerProviderStateMixin {
  bool _loading = true;
  String? _title;
  String? _artist;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 850));
    _loadMetadata();
  }

  @override
  void didUpdateWidget(covariant TrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackPath != widget.trackPath) {
      if (mounted) {
        setState(() {
          _loading = true;
          _title = null;
          _artist = null;
        });
      }
      _loadMetadata();
    }
    if (widget.pulse != 0 && oldWidget.pulse != widget.pulse) {
      _pulseController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadMetadata() async {
    final isStream = widget.trackPath.startsWith('http://') || widget.trackPath.startsWith('https://');
    final fileName = isStream ? widget.trackPath : p.basenameWithoutExtension(widget.trackPath);

    final cached = await MetadataCacheService.get(widget.trackPath);
    if (!mounted) return;
    if (cached != null) {
      setState(() {
        _title = cached.title;
        _artist = cached.artist;
        _loading = false;
      });
      return;
    }

    if (isStream) {
      if (mounted) {
        setState(() {
          _title = 'Streaming Audio';
          _artist = 'YouTube';
          _loading = false;
        });
      }
      return;
    }

    try {
      final metadata = await AudioMetadata.extract(File(widget.trackPath));
      if (!mounted) return;
      final title = (metadata?.trackName?.trim().isNotEmpty ?? false) ? metadata!.trackName! : fileName;
      final artist = (metadata?.firstArtists?.trim().isNotEmpty ?? false) ? metadata!.firstArtists! : 'Unknown Artist';

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

  void _showMetadataEditor(BuildContext context, String currentTitle, String currentArtist) {
    final titleController = TextEditingController(text: currentTitle);
    final artistController = TextEditingController(text: currentArtist);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.edit_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
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
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  await MetadataGod.writeMetadata(
                    file: widget.trackPath,
                    metadata: Metadata(title: titleController.text, artist: artistController.text),
                  );
                  await MetadataCacheService.set(widget.trackPath, titleController.text, artistController.text);
                  if (mounted) {
                    setState(() {
                      _title = titleController.text;
                      _artist = artistController.text;
                    });
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Failed to update metadata: $e')));
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
    // RepaintBoundary: this tile can redraw (e.g. playing state) without
    // triggering repaints of neighbouring tiles in the list.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final wave = math.sin(_pulseController.value * math.pi);
          return Transform.scale(
            scale: 1 + wave * 0.012,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  if (wave > 0)
                    BoxShadow(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: wave * 0.42),
                      blurRadius: 24 * wave,
                      spreadRadius: 2 * wave,
                    ),
                ],
              ),
              child: child,
            ),
          );
        },
        child: _TrackTileContent(
          trackPath: widget.trackPath,
          index: widget.index,
          onDelete: widget.onDelete,
          loading: _loading,
          title: _title,
          artist: _artist,
          onEditMetadata: _showMetadataEditor,
        ),
      ),
    );
  }
}

// Separated into its own widget so StreamBuilder rebuilds are contained
// inside it and don't touch the parent StatefulWidget's state.
class _TrackTileContent extends StatelessWidget {
  final String trackPath;
  final int index;
  final VoidCallback onDelete;
  final bool loading;
  final String? title;
  final String? artist;
  final void Function(BuildContext, String, String) onEditMetadata;

  const _TrackTileContent({
    required this.trackPath,
    required this.index,
    required this.onDelete,
    required this.loading,
    required this.title,
    required this.artist,
    required this.onEditMetadata,
  });

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final fileName = p.basenameWithoutExtension(trackPath);
    final isStream = trackPath.startsWith('http://') || trackPath.startsWith('https://');

    if (loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: _SkeletonTile(isDark: isDark),
      );
    }

    final resolvedTitle = title ?? fileName;
    final resolvedArtist = artist ?? 'Unknown Artist';

    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, mediaSnapshot) {
        // Check both id match AND processing state for stream loading
        final isCurrentTrack = mediaSnapshot.data?.id == trackPath;
        // Also listen to playback state to show loading on stream
        return StreamBuilder<PlaybackState>(
          stream: handler.playbackState,
          builder: (context, playbackSnapshot) {
            final isLoading =
                isCurrentTrack &&
                (playbackSnapshot.data?.processingState == AudioProcessingState.loading ||
                    playbackSnapshot.data?.processingState == AudioProcessingState.buffering);
            // "playing" = is current track AND actually playing (not loading)
            final isPlaying = isCurrentTrack && !isLoading;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  color: isCurrentTrack
                      ? (isDark ? primary.withValues(alpha: 0.12) : primary.withValues(alpha: 0.06))
                      : (isDark ? const Color(0xFF1A1A2A) : Colors.white),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isCurrentTrack
                        ? primary.withValues(alpha: 0.45)
                        : (isDark ? const Color(0xFF2D2D42) : const Color(0xFFDDD9F3)),
                    width: isCurrentTrack ? 1.5 : 1,
                  ),
                  boxShadow: isCurrentTrack
                      ? [
                          BoxShadow(
                            color: primary.withValues(alpha: isDark ? 0.12 : 0.08),
                            blurRadius: 12,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : const [],
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: () => handler.loadTrack(trackPath, resolvedTitle, resolvedArtist),
                    onLongPress: isStream ? null : () => onEditMetadata(context, resolvedTitle, resolvedArtist),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          // ── Drag handle ───────────────────────────
                          ReorderableDragStartListener(
                            index: index,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Icon(
                                Icons.drag_handle_rounded,
                                size: 18,
                                color: isCurrentTrack
                                    ? primary.withValues(alpha: 0.5)
                                    : (isDark ? const Color(0xFF3D3D55) : const Color(0xFFBDB8E0)),
                              ),
                            ),
                          ),

                          // ── Icon ─────────────────────────────────
                          _TrackIcon(isPlaying: isPlaying, isStream: isStream, isLoading: isLoading),
                          const SizedBox(width: 12),

                          // ── Title + artist ────────────────────────
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  resolvedTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: isCurrentTrack ? FontWeight.w700 : FontWeight.w500,
                                    fontSize: 13,
                                    color: isCurrentTrack
                                        ? primary
                                        : (isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A)),
                                    letterSpacing: -0.1,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  resolvedArtist,
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

                          // ── Delete button ─────────────────────────
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 16),
                            tooltip: 'Remove',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
                            onPressed: () {
                              MetadataCacheService.remove(trackPath);
                              onDelete();
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
      },
    );
  }
}

/// Skeleton loader with const colors.
class _SkeletonTile extends StatelessWidget {
  final bool isDark;
  const _SkeletonTile({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A2A) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? const Color(0xFF2D2D42) : const Color(0xFFDDD9F3), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF242436) : const Color(0xFFEEECF8),
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
                    color: isDark ? const Color(0xFF242436) : const Color(0xFFEEECF8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 10,
                  width: 80,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E1E30) : const Color(0xFFF5F3FF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Track icon — shows a loading spinner for streams that are buffering,
/// a waveform for playing, or a music/sensor icon otherwise.
class _TrackIcon extends StatelessWidget {
  final bool isPlaying;
  final bool isStream;
  final bool isLoading;

  const _TrackIcon({required this.isPlaying, this.isStream = false, this.isLoading = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final isActive = isPlaying || isLoading;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: isActive
            ? primary.withValues(alpha: isDark ? 0.2 : 0.12)
            : (isDark ? const Color(0xFF242436) : const Color(0xFFEEECF8)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: isLoading
            ? Padding(
                key: const ValueKey('loading'),
                padding: const EdgeInsets.all(8),
                child: CircularProgressIndicator(strokeWidth: 2, color: primary),
              )
            : Icon(
                isPlaying ? Icons.graphic_eq_rounded : (isStream ? Icons.sensors_rounded : Icons.music_note_rounded),
                key: ValueKey(
                  isPlaying
                      ? 'playing'
                      : isStream
                      ? 'stream'
                      : 'local',
                ),
                size: 17,
                color: isPlaying ? primary : (isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
              ),
      ),
    );
  }
}
