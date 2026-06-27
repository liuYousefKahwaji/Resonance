// lib/widgets/library/track_list.dart
// Logic: UNCHANGED. proxyDecorator updated for Obsidian Pulse.

import 'package:flutter/material.dart';
import 'package:resonance/widgets/library/track_tile.dart';

class TrackList extends StatelessWidget {
  final List<String> tracks;
  final Function(int index, String path) onTrackDeleted;
  final Function(int oldIndex, int newIndex) onReorder;

  const TrackList({
    super.key,
    required this.tracks,
    required this.onTrackDeleted,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return _EmptyState();
    }

    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        return TrackTile(
          key: ValueKey('$index-${tracks[index]}'),
          trackPath: tracks[index],
          index: index,
          onDelete: () => onTrackDeleted(index, tracks[index]),
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
              color: isDark
                  ? primary.withValues(alpha: 0.08)
                  : primary.withValues(alpha: 0.06),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.library_music_rounded,
              size: 32,
              color: primary.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Your library is empty',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isDark
                  ? const Color(0xFF94A3B8)
                  : const Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Import tracks or download from YouTube',
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? const Color(0xFF475569)
                  : const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }
}