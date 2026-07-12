import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A square artwork treatment which never stretches the source image.
///
/// Non-square covers use a softly tinted edge-to-edge copy behind a contained
/// foreground, preserving the complete artwork while still filling the tile.
class ArtworkThumbnail extends StatelessWidget {
  final Uint8List bytes;
  final double size;
  final double borderRadius;

  const ArtworkThumbnail({super.key, required this.bytes, required this.size, this.borderRadius = 8});

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note_rounded, color: Theme.of(context).colorScheme.primary),
    );
    Widget image(BoxFit fit, {double opacity = 1}) => Opacity(
      opacity: opacity,
      child: Image.memory(
        bytes,
        width: size,
        height: size,
        fit: fit,
        alignment: Alignment.center,
        gaplessPlayback: true,
        cacheWidth: (size * 3).round(),
        cacheHeight: (size * 3).round(),
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            image(BoxFit.cover, opacity: 0.32),
            ColoredBox(color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.18)),
            image(BoxFit.contain),
          ],
        ),
      ),
    );
  }
}
