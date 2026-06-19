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
      return const Center(child: Text('No tracks found.'));
    }

    return ReorderableListView.builder(
      // Use ReorderableDelayedDragStartListener for touch to avoid conflicts
      // with scroll gestures on Android. The handle widget below uses
      // ReorderableDragStartListener (immediate) since users tap the handle
      // icon intentionally — delay is only needed for whole-tile dragging.
      itemCount: tracks.length,
      // Combine position + path so keys are unique even with duplicate paths
      itemBuilder: (context, index) {
        return TrackTile(
          key: ValueKey('$index-${tracks[index]}'),
          trackPath: tracks[index],
          index: index,
          onDelete: () => onTrackDeleted(index, tracks[index]),
        );
      },
      onReorder: onReorder,
      // Remove the default drag handle proxy decoration to keep the existing
      // AnimatedContainer card look during drag
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final elevation = (animation.value * 8).clamp(0.0, 8.0);
            return Material(
              elevation: elevation,
              borderRadius: BorderRadius.circular(14),
              color: Colors.transparent,
              child: child,
            );
          },
          child: child,
        );
      },
    );
  }
}