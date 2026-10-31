import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/widgets/common/progressive_network_artwork.dart';

/// A small mosaic of existing track art, without resolving any stream URLs.
class PlaylistArtwork extends StatefulWidget {
  const PlaylistArtwork({super.key, required this.tracks, required this.favorite, this.revision = 0});
  final List<String> tracks;
  final bool favorite;
  final int revision;
  @override
  State<PlaylistArtwork> createState() => _PlaylistArtworkState();
}

class _PlaylistArtworkState extends State<PlaylistArtwork> {
  late List<String> _paths;
  late Future<List<Object?>> _art;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _paths = widget.tracks.take(4).toList();
    _art = widget.favorite
        ? Future.value(const [])
        : Future.wait(
            _paths.map((path) async {
              try {
                if (Uri.tryParse(path)?.hasScheme == true && !File(path).isAbsolute) {
                  return (await MetadataCacheService.get(path))?.artworkUrl;
                }
                final bytes = (await MetadataGod.readMetadata(file: path)).picture?.data;
                return bytes == null || bytes.isEmpty ? null : Uint8List.fromList(bytes);
              } catch (_) {
                return null;
              }
            }),
          );
  }

  @override
  void didUpdateWidget(PlaylistArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    final paths = widget.tracks.take(4).toList();
    if (widget.favorite != oldWidget.favorite ||
        widget.revision != oldWidget.revision ||
        paths.length != _paths.length ||
        List.generate(paths.length, (i) => paths[i] == _paths[i]).contains(false)) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = widget.favorite ? const Color(0xFFFFD740) : colors.primary;
    Widget fallback() => ColoredBox(
      color: Color.alphaBlend(accent.withValues(alpha: .12), colors.surface),
      child: Center(
        child: Icon(widget.favorite ? Icons.star_rounded : Icons.music_note_rounded, color: accent, size: 34),
      ),
    );
    Widget artwork(Object? item) => switch (item) {
      Uint8List bytes => Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => fallback(),
      ),
      String url when url.isNotEmpty => ProgressiveNetworkArtwork(url: url, fit: BoxFit.cover, fallback: fallback()),
      _ => fallback(),
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: FutureBuilder<List<Object?>>(
        future: _art,
        builder: (context, snapshot) {
          final images = snapshot.data?.where((image) => image != null).toList() ?? [];
          if (widget.favorite || images.isEmpty) return fallback();
          if (images.length < 4) return artwork(images.first);
          return Column(
            children: [
              for (var row = 0; row < 2; row++)
                Expanded(
                  child: Row(
                    children: [
                      for (var column = 0; column < 2; column++)
                        Expanded(child: SizedBox.expand(child: artwork(images[row * 2 + column]))),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
