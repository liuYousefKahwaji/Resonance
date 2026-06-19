import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:path/path.dart' as p;

class AlbumCover extends StatelessWidget {
  const AlbumCover({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    final screenWidth = MediaQuery.of(context).size.width;

    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, snapshot) {
        final item = snapshot.data;
        final path = item?.title ?? "No track selected";
        final title = p.basenameWithoutExtension(path);
        final artist = item?.artist ?? "Unknown Artist";

        // Clamp to avoid BoxConstraints crash when screenWidth is 0
        // on the very first build frame before layout resolves.
        final maxW = screenWidth < 500
            ? (screenWidth - 32.0).clamp(0.0, double.infinity)
            : 600.0;

        return Center(
          child: Container(
            margin: const EdgeInsets.only(top: 20.0, left: 16.0, right: 16.0, bottom: 0.0),
            constraints: BoxConstraints(maxWidth: maxW),
            width: double.infinity, // fills available space up to maxWidth
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4, offset: const Offset(0, 2)),
              ],
            ),
            child: Row(
              children: [
                const SizedBox(width: 2),
                const Icon(Icons.music_note, size: 24, color: Colors.deepPurple),
                const SizedBox(width: 20),
                Expanded(
                  // ← forces text to shrink
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (artist.isNotEmpty)
                        Text(
                          artist,
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
