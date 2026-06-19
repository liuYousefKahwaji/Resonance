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
      // IMPORTANT: disable the default trailing drag handle that
      // ReorderableListView auto-inserts. TrackTile already has its own
      // ReorderableDragStartListener on the leading drag_handle icon, so
      // the default handle is redundant and visually out of place.
      buildDefaultDragHandles: false,
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
      // Preserve the AnimatedContainer card look during drag by not
      // replacing it with a default opaque Material proxy.
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