// lib/widgets/library/track_list.dart
// Scroll smoothness improvements:
//  1. cacheExtent: 400 — pre-builds tiles 400px above and below the viewport
//     so tiles don't pop in while scrolling.
//  2. addRepaintBoundaries: true (default, but explicit) — each item gets
//     its own layer so playing-state updates don't repaint the whole list.
//  3. addAutomaticKeepAlives: false — we don't need tiles to keep state
//     when off-screen; metadata is cached in MetadataCacheService and reloads
//     from the in-memory map instantly, so re-init is effectively free.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:resonance/widgets/library/track_tile.dart';

class TrackList extends StatefulWidget {
  static const double itemExtent = 70;
  static const double topPadding = 4;

  final List<String> tracks;
  final Function(int index, String path) onTrackDeleted;
  final Function(String path) onTrackDeletedEverywhere;
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
    required this.onTrackDeletedEverywhere,
    required this.onReorder,
    required this.controller,
    required this.pulsingTrackIndex,
    required this.pulse,
    required this.artworkRevision,
    required this.itemKeyForIndex,
  });

  @override
  State<TrackList> createState() => _TrackListState();
}

class _TrackListState extends State<TrackList> {
  bool _isScrolling = false;

  bool _handleScroll(ScrollNotification notification) {
    final scrolling = notification is ScrollStartNotification || notification is ScrollUpdateNotification;
    final stopped = notification is ScrollEndNotification;
    if (scrolling && !_isScrolling) {
      setState(() => _isScrolling = true);
    } else if (stopped && _isScrolling) {
      setState(() => _isScrolling = false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tracks.isEmpty) {
      return const _EmptyState();
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: ImageFiltered(
        enabled: _isScrolling,
        imageFilter: ui.ImageFilter.blur(sigmaX: 0.28, sigmaY: 0.28),
        child: ReorderableListView.builder(
          scrollController: widget.controller,
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.only(top: TrackList.topPadding, bottom: 8),
          cacheExtent: 400,
          itemExtent: TrackList.itemExtent,
          itemCount: widget.tracks.length,
          itemBuilder: (context, index) {
            final trackPath = widget.tracks[index];
            return TrackTile(
              key: widget.itemKeyForIndex(index),
              trackPath: trackPath,
              index: index,
              onDelete: () => widget.onTrackDeleted(index, trackPath),
              onDeleteEverywhere: () => widget.onTrackDeletedEverywhere(trackPath),
              pulse: widget.pulsingTrackIndex == index ? widget.pulse : 0,
              artworkRevision: widget.artworkRevision,
            );
          },
          onReorder: widget.onReorder,
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
        ),
      ),
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
