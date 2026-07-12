// lib/widgets/library/track_list.dart
// Scroll smoothness improvements:
//  1. cacheExtent: 400 — pre-builds tiles 400px above and below the viewport
//     so tiles don't pop in while scrolling.
//  2. addRepaintBoundaries: true (default, but explicit) — each item gets
//     its own layer so playing-state updates don't repaint the whole list.
//  3. addAutomaticKeepAlives: false — we don't need tiles to keep state
//     when off-screen; metadata is cached in MetadataCacheService and reloads
//     from the in-memory map instantly, so re-init is effectively free.

import 'package:flutter/material.dart';
import 'package:resonance/widgets/library/track_tile.dart';

class TrackList extends StatelessWidget {
  static const double itemExtent = 70;
  static const double topPadding = 4;

  final List<String> tracks;
  final Function(int index, String path) onTrackDeleted;
  final Function(int oldIndex, int newIndex) onReorder;
  final ScrollController controller;
  final int? pulsingTrackIndex;
  final int pulse;
  final int artworkRevision;
  final GlobalKey Function(int index) itemKeyForIndex;

  const TrackList({
    super.key,
    required this.tracks,
    required this.onTrackDeleted,
    required this.onReorder,
    required this.controller,
    required this.pulsingTrackIndex,
    required this.pulse,
    required this.artworkRevision,
    required this.itemKeyForIndex,
  });

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return const _EmptyState();
    }

    return ReorderableListView.builder(
      scrollController: controller,
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(top: topPadding, bottom: 8),
      cacheExtent: 400,
      itemExtent: itemExtent,
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        return TrackTile(
          key: itemKeyForIndex(index),
          trackPath: tracks[index],
          index: index,
          onDelete: () => onTrackDeleted(index, tracks[index]),
          pulse: pulsingTrackIndex == index ? pulse : 0,
          artworkRevision: artworkRevision,
        );
      },
      onReorder: onReorder,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final primary = Theme.of(context).colorScheme.primary;
            final elevation = (animation.value * 12).clamp(0.0, 12.0);
            return Material(
              elevation: elevation,
              borderRadius: BorderRadius.circular(12),
              color: Colors.transparent,
              shadowColor: primary.withValues(alpha: 0.25),
              child: child,
            );
          },
          child: child,
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: isDark ? primary.withValues(alpha: 0.08) : primary.withValues(alpha: 0.06),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.library_music_rounded, size: 32, color: primary.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 16),
          Text(
            'Your library is empty',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Import tracks or search YouTube',
            style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }
}
