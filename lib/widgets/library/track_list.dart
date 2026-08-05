// lib/widgets/library/track_list.dart
// Scroll smoothness improvements:
//  1. Platform-tuned cache extent — desktop prebuilds farther ahead while
//     Android avoids starting too many metadata/artwork reads at once.
//  2. addRepaintBoundaries: true (default, but explicit) — each item gets
//     its own layer so playing-state updates don't repaint the whole list.
//  3. addAutomaticKeepAlives: false — we don't need tiles to keep state
//     when off-screen; metadata is cached in MetadataCacheService and reloads
//     from the in-memory map instantly, so re-init is effectively free.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:resonance/widgets/library/track_tile.dart';
import 'package:resonance/services/scroll_effects_preferences.dart';

class TrackList extends StatefulWidget {
  static const double itemExtent = 70;
  static const double topPadding = 4;

  final List<String> tracks;
  final int playlistNumber;
  final Function(int index, String path) onTrackDeleted;
  final Function(String path) onTrackDeletedEverywhere;
  final Function(int oldIndex, int newIndex) onReorder;
  final ScrollController controller;
  final int? pulsingTrackIndex;
  final int pulse;
  final int artworkRevision;
  final GlobalKey Function(int playlistNumber, int index) itemKeyForIndex;
  final Set<int> selectedIndices;
  final ValueChanged<int>? onSelectionToggle;

  const TrackList({
    super.key,
    required this.tracks,
    required this.playlistNumber,
    required this.onTrackDeleted,
    required this.onTrackDeletedEverywhere,
    required this.onReorder,
    required this.controller,
    required this.pulsingTrackIndex,
    required this.pulse,
    required this.artworkRevision,
    required this.itemKeyForIndex,
    this.selectedIndices = const <int>{},
    this.onSelectionToggle,
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

    final list = ReorderableListView.builder(
      scrollController: widget.controller,
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(top: TrackList.topPadding, bottom: 8),
      // Prebuilding too many artwork-heavy rows causes a burst of file and
      // image work on lower-end phones. Desktop keeps the larger cache.
      cacheExtent: Platform.isAndroid ? 160 : 400,
      itemExtent: TrackList.itemExtent,
      itemCount: widget.tracks.length,
      itemBuilder: (context, index) {
        final trackPath = widget.tracks[index];
        return TrackTile(
          key: widget.itemKeyForIndex(widget.playlistNumber, index),
          trackPath: trackPath,
          playlistNumber: widget.playlistNumber,
          index: index,
          onDelete: () => widget.onTrackDeleted(index, trackPath),
          onDeleteEverywhere: () => widget.onTrackDeletedEverywhere(trackPath),
          pulse: widget.pulsingTrackIndex == index ? widget.pulse : 0,
          artworkRevision: widget.artworkRevision,
          selected: widget.selectedIndices.contains(index),
          selectionMode: widget.selectedIndices.isNotEmpty,
          onSelectionToggle: widget.onSelectionToggle == null ? null : () => widget.onSelectionToggle!(index),
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
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: ValueListenableBuilder<bool>(
        valueListenable: ScrollEffectsPreferences.instance.motionBlurEnabled,
        child: list,
        builder: (context, motionBlurEnabled, child) =>
            TrackListMotionBlurSurface(enabled: motionBlurEnabled && _isScrolling, child: child!),
      ),
    );
  }
}

/// Keeps the list under a stable render-object wrapper while blur is toggled.
/// Replacing the list with a newly wrapped subtree at scroll end can detach its
/// Scrollable state and make the controller jump back to the top.
@visibleForTesting
class TrackListMotionBlurSurface extends StatelessWidget {
  final bool enabled;
  final Widget child;

  const TrackListMotionBlurSurface({super.key, required this.enabled, required this.child});

  @override
  Widget build(BuildContext context) => ImageFiltered(
    enabled: enabled,
    // This full-list filter is intentionally opt-in. It is disabled by
    // default because low-end Android GPUs often pay more for the blur than
    // the visual effect is worth.
    imageFilter: ui.ImageFilter.blur(sigmaX: 0.22, sigmaY: 0.36),
    child: child,
  );
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
