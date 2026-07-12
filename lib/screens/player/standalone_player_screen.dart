import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/widgets/player/player_controls.dart';

const nowPlayingArtworkHeroTag = 'resonance-now-playing-artwork';

class StandalonePlayerScreen extends StatelessWidget {
  const StandalonePlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = context.read<PlayerHandler>();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to playlist',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Now Playing'),
      ),
      body: StreamBuilder<MediaItem?>(
        stream: handler.mediaItem,
        initialData: handler.mediaItem.value,
        builder: (context, snapshot) {
          final item = snapshot.data;
          return StreamBuilder<PlaybackState>(
            stream: handler.playbackState,
            initialData: handler.playbackState.value,
            builder: (context, playbackSnapshot) => Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 760;
                      final isPlaying = playbackSnapshot.data?.playing ?? false;
                      if (compact) {
                        return SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              _ArtworkBox(item: item, isPlaying: isPlaying, size: constraints.maxWidth - 40),
                              const SizedBox(height: 28),
                              _TrackDetails(item: item, centered: true),
                            ],
                          ),
                        );
                      }

                      return Padding(
                        padding: const EdgeInsets.all(28),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 6,
                              child: Center(
                                child: _ArtworkBox(
                                  item: item,
                                  isPlaying: isPlaying,
                                  size: math.min(constraints.maxHeight - 56, constraints.maxWidth * 0.55),
                                ),
                              ),
                            ),
                            const SizedBox(width: 36),
                            Expanded(
                              flex: 5,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: _TrackDetails(item: item, centered: false),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const PlayerControls(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ArtworkBox extends StatelessWidget {
  final MediaItem? item;
  final bool isPlaying;
  final double size;

  const _ArtworkBox({required this.item, required this.isPlaying, required this.size});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: math.max(0, size),
    child: _PulsingArtwork(item: item, isPlaying: isPlaying),
  );
}

class _TrackDetails extends StatelessWidget {
  final MediaItem? item;
  final bool centered;

  const _TrackDetails({required this.item, required this.centered});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
    children: [
      Text(
        item?.title ?? 'Nothing playing',
        textAlign: centered ? TextAlign.center : TextAlign.left,
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
      ),
      if ((item?.artist ?? '').isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          item!.artist!,
          textAlign: centered ? TextAlign.center : TextAlign.left,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ],
  );
}

class _PulsingArtwork extends StatefulWidget {
  final MediaItem? item;
  final bool isPlaying;

  const _PulsingArtwork({required this.item, required this.isPlaying});

  @override
  State<_PulsingArtwork> createState() => _PulsingArtworkState();
}

class _PulsingArtworkState extends State<_PulsingArtwork> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
    _pulse = Tween<double>(
      begin: 0.22,
      end: 0.58,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    if (widget.isPlaying) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _PulsingArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isPlaying && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final opacity = widget.isPlaying ? _pulse.value : 0.14;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(color: primary.withValues(alpha: opacity), blurRadius: 34, spreadRadius: 2),
              BoxShadow(color: primary.withValues(alpha: opacity * 0.45), blurRadius: 70, spreadRadius: -8),
            ],
          ),
          child: child,
        );
      },
      child: Hero(
        tag: nowPlayingArtworkHeroTag,
        child: _LargeArtwork(item: widget.item),
      ),
    );
  }
}

class _LargeArtwork extends StatelessWidget {
  final MediaItem? item;

  const _LargeArtwork({required this.item});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final uri = item?.artUri;
    final image = uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
        ? Image.network(
            uri.toString(),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _ArtworkFallback(primary: primary),
          )
        : _ArtworkFallback(primary: primary);
    return AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(color: primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(28)),
        child: ClipRRect(borderRadius: BorderRadius.circular(28), child: image),
      ),
    );
  }
}

class _ArtworkFallback extends StatelessWidget {
  final Color primary;

  const _ArtworkFallback({required this.primary});

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: primary.withValues(alpha: 0.14),
    child: Icon(Icons.music_note_rounded, size: 112, color: primary),
  );
}
