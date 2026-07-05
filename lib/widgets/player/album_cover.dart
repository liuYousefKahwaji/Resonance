// lib/widgets/player/album_cover.dart
// Added loading state display:
//  - When AudioProcessingState is loading/buffering, show a small spinner
//    next to the track title in the now-playing card.
//  - Pulse animation pauses while loading (it would look odd to pulse while
//    the track hasn't started yet).

import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';

class AlbumCover extends StatefulWidget {
  const AlbumCover({super.key});

  @override
  State<AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<AlbumCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2400));
    _pulseAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _pulseController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final screenWidth = MediaQuery.of(context).size.width;

    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, mediaSnapshot) {
        final item = mediaSnapshot.data;
        final path = item?.id ?? '';
        final rawTitle = item?.title ?? '';
        final title = rawTitle.isNotEmpty
            ? (path.isNotEmpty ? p.basenameWithoutExtension(rawTitle) : rawTitle)
            : 'Nothing playing';
        final artist = item?.artist ?? '';

        return StreamBuilder<PlaybackState>(
          stream: handler.playbackState,
          initialData: handler.playbackState.value,
          builder: (context, playbackSnapshot) {
            final isPlaying = playbackSnapshot.data?.playing ?? false;
            final processingState =
                playbackSnapshot.data?.processingState ??
                    AudioProcessingState.idle;
            final isLoading =
                processingState == AudioProcessingState.loading ||
                    processingState == AudioProcessingState.buffering;

            // Pause glow pulse while loading
            if (isLoading) {
              if (_pulseController.isAnimating) _pulseController.stop();
            } else if (isPlaying && !_pulseController.isAnimating) {
              _pulseController.repeat(reverse: true);
            } else if (!isPlaying && _pulseController.isAnimating) {
              _pulseController.stop();
            }

            final maxW = screenWidth < 500
                ? (screenWidth - 32.0).clamp(0.0, double.infinity)
                : 640.0;

            return Center(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                constraints: BoxConstraints(maxWidth: maxW),
                width: double.infinity,
                child: AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    final glowOpacity =
                        isPlaying && !isLoading ? _pulseAnimation.value * 0.55 : 0.0;

                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                              color: primary.withValues(alpha: glowOpacity),
                              blurRadius: 20,
                              spreadRadius: 0),
                          BoxShadow(
                            color: primary.withValues(alpha: glowOpacity * 0.4),
                            blurRadius: 40,
                            spreadRadius: -4,
                          ),
                        ],
                      ),
                      child: child,
                    );
                  },
                  child: _NowPlayingCard(
                    title: title,
                    artist: artist,
                    isPlaying: isPlaying,
                    isLoading: isLoading,
                    hasTrack: item != null,
                    isDark: isDark,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  final String title;
  final String artist;
  final bool isPlaying;
  final bool isLoading;
  final bool hasTrack;
  final bool isDark;

  const _NowPlayingCard({
    required this.title,
    required this.artist,
    required this.isPlaying,
    required this.isLoading,
    required this.hasTrack,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final surface = isDark ? const Color(0xFF1A1A2A) : Colors.white;
    final border = isDark ? const Color(0xFF2D2D42) : const Color(0xFFDDD9F3);
    final textPrimary =
        isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);

    final isActive = isPlaying || isLoading;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: isActive ? primary.withValues(alpha: 0.4) : border,
            width: isActive ? 1.5 : 1),
      ),
      child: Row(
        children: [
          _AlbumIcon(
              isPlaying: isPlaying, hasTrack: hasTrack, isLoading: isLoading),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: textPrimary,
                      letterSpacing: -0.1),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (artist.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    artist,
                    style: const TextStyle(
                        color: textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w400),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (isLoading) ...[
            const SizedBox(width: 12),
            _LoadingBadge(),
          ] else if (isPlaying) ...[
            const SizedBox(width: 12),
            _PlayingBadge(),
          ],
        ],
      ),
    );
  }
}

class _AlbumIcon extends StatefulWidget {
  final bool isPlaying;
  final bool isLoading;
  final bool hasTrack;

  const _AlbumIcon(
      {required this.isPlaying,
      required this.hasTrack,
      required this.isLoading});

  @override
  State<_AlbumIcon> createState() => _AlbumIconState();
}

class _AlbumIconState extends State<_AlbumIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    if (widget.isPlaying && !widget.isLoading) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _AlbumIcon old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying && !widget.isLoading && !_controller.isAnimating) {
      _controller.repeat();
    } else if ((!widget.isPlaying || widget.isLoading) &&
        _controller.isAnimating) {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? primary.withValues(alpha: 0.15)
        : primary.withValues(alpha: 0.08);

    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: (widget.isPlaying || widget.isLoading)
                ? primary.withValues(alpha: 0.3)
                : Colors.transparent,
            width: 1),
      ),
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: widget.isLoading
              ? Padding(
                  key: const ValueKey('loading'),
                  padding: const EdgeInsets.all(10),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: primary,
                  ),
                )
              : widget.isPlaying
                  ? _WaveformIcon(key: const ValueKey('wave'), color: primary)
                  : Icon(
                      key: const ValueKey('idle'),
                      widget.hasTrack
                          ? Icons.music_note_rounded
                          : Icons.music_off_rounded,
                      size: 20,
                      color: primary.withValues(alpha: 0.6),
                    ),
        ),
      ),
    );
  }
}

class _WaveformIcon extends StatefulWidget {
  final Color color;

  const _WaveformIcon({super.key, required this.color});

  @override
  State<_WaveformIcon> createState() => _WaveformIconState();
}

class _WaveformIconState extends State<_WaveformIcon> {
  final _random = math.Random();

  late final List<double> _heights;
  late final List<int> _durations;

  @override
  void initState() {
    super.initState();

    _heights = List.generate(4, (_) => _nextHeight());
    _durations = List.generate(4, (_) => _nextDuration());

    for (int i = 0; i < 4; i++) {
      _animateBar(i);
    }
  }

  double _nextHeight() => 4 + _random.nextDouble() * 12;
  int _nextDuration() => 250 + _random.nextInt(450);

  Future<void> _animateBar(int index) async {
    while (mounted) {
      await Future.delayed(Duration(milliseconds: _durations[index]));
      if (!mounted) return;
      setState(() {
        _heights[index] = _nextHeight();
        _durations[index] = _nextDuration();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(4, (i) {
          return Padding(
            padding: EdgeInsets.only(right: i == 3 ? 0 : 2),
            child: AnimatedContainer(
              duration: Duration(milliseconds: _durations[i]),
              curve: Curves.easeInOutCubic,
              width: 2.8,
              height: _heights[i],
              decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2)),
            ),
          );
        }),
      ),
    );
  }
}

class _LoadingBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color =
        isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 8,
            height: 8,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: color,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'LOADING',
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: color),
          ),
        ],
      ),
    );
  }
}

class _PlayingBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: primary.withValues(alpha: 0.3), width: 1),
      ),
      child: Text(
        'NOW PLAYING',
        style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: primary),
      ),
    );
  }
}