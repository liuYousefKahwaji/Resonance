// lib/widgets/player/album_cover.dart

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/widgets/common/artwork_thumbnail.dart';

class AlbumCover extends StatefulWidget {
  final ValueChanged<String>? onTap;
  final int artworkRevision;
  const AlbumCover({super.key, this.onTap, this.artworkRevision = 0});

  @override
  State<AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<AlbumCover> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
    _pulseAnimation = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
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
        final title = rawTitle.isNotEmpty ? rawTitle : 'Nothing playing';
        final artist = item?.artist ?? '';

        return ValueListenableBuilder<PlaybackVisualState>(
          valueListenable: handler.playbackVisualNotifier,
          builder: (context, playback, _) {
            final isPlaying = playback.playing;
            final isLoading = playback.loading;

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (isLoading) {
                if (_pulseController.isAnimating) _pulseController.stop();
              } else if (isPlaying && !_pulseController.isAnimating) {
                _pulseController.repeat(reverse: true);
              } else if (!isPlaying && _pulseController.isAnimating) {
                _pulseController.stop();
              }
            });

            final maxW = screenWidth < 500 ? (screenWidth - 32.0).clamp(0.0, double.infinity) : 640.0;

            return Center(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                constraints: BoxConstraints(maxWidth: maxW),
                width: double.infinity,
                child: AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    final glowOpacity = isPlaying && !isLoading ? _pulseAnimation.value * 0.55 : 0.0;

                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(color: primary.withValues(alpha: glowOpacity), blurRadius: 20, spreadRadius: 0),
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
                    path: path,
                    artworkUri: item?.artUri,
                    isPlaying: isPlaying,
                    isLoading: isLoading,
                    hasTrack: item != null,
                    isDark: isDark,
                    artworkRevision: widget.artworkRevision,
                    onTap: item == null ? null : () => widget.onTap?.call(path),
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
  final String path;
  final Uri? artworkUri;
  final bool isPlaying;
  final bool isLoading;
  final bool hasTrack;
  final bool isDark;
  final int artworkRevision;
  final VoidCallback? onTap;

  const _NowPlayingCard({
    required this.title,
    required this.artist,
    required this.path,
    required this.artworkUri,
    required this.isPlaying,
    required this.isLoading,
    required this.hasTrack,
    required this.isDark,
    required this.artworkRevision,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final surface = Theme.of(context).colorScheme.surface;
    final border = Theme.of(context).colorScheme.outline;
    final textPrimary = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);

    final isActive = isPlaying || isLoading;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isActive ? primary.withValues(alpha: 0.4) : border, width: isActive ? 1.5 : 1),
          ),
          child: Row(
            // Prevent the Row from overflowing — each child must be sized.
            mainAxisSize: MainAxisSize.max,
            children: [
              Hero(
                tag: nowPlayingArtworkHeroTag,
                child: _AlbumIcon(
                  isPlaying: isPlaying,
                  hasTrack: hasTrack,
                  isLoading: isLoading,
                  path: path,
                  artworkUri: artworkUri,
                  artworkRevision: artworkRevision,
                ),
              ),
              const SizedBox(width: 14),
              // Expanded forces the text column to take remaining space and
              // enables Text overflow / ellipsis to work correctly.
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
                        letterSpacing: -0.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                    if (artist.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        artist,
                        style: const TextStyle(color: textMuted, fontSize: 12, fontWeight: FontWeight.w400),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
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
        ),
      ),
    );
  }
}

class _AlbumIcon extends StatefulWidget {
  final bool isPlaying;
  final bool isLoading;
  final bool hasTrack;
  final String path;
  final Uri? artworkUri;
  final int artworkRevision;

  const _AlbumIcon({
    required this.isPlaying,
    required this.hasTrack,
    required this.path,
    required this.artworkUri,
    required this.isLoading,
    required this.artworkRevision,
  });

  @override
  State<_AlbumIcon> createState() => _AlbumIconState();
}

class _AlbumIconState extends State<_AlbumIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Uint8List? _albumArt;
  String? _loadedPath;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    if (widget.isPlaying && !widget.isLoading) _controller.repeat();
    _loadAlbumArt();
  }

  @override
  void didUpdateWidget(covariant _AlbumIcon old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path ||
        old.artworkUri != widget.artworkUri ||
        old.artworkRevision != widget.artworkRevision) {
      _albumArt = null;
      _loadedPath = null;
      _loadAlbumArt();
    }
    if (widget.isPlaying && !widget.isLoading && !_controller.isAnimating) {
      _controller.repeat();
    } else if ((!widget.isPlaying || widget.isLoading) && _controller.isAnimating) {
      _controller.stop();
    }
  }

  Future<void> _loadAlbumArt() async {
    final path = widget.path;
    if (path.isEmpty || path.startsWith('http://') || path.startsWith('https://')) return;
    _loadedPath = path;
    try {
      final metadata = await MetadataGod.readMetadata(file: path);
      final data = metadata.picture?.data;
      if (!mounted || _loadedPath != path || data == null || data.isEmpty) return;
      setState(() => _albumArt = Uint8List.fromList(data));
    } catch (_) {}
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
    final bgColor = isDark ? primary.withValues(alpha: 0.15) : primary.withValues(alpha: 0.08);

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (widget.isPlaying || widget.isLoading) ? primary.withValues(alpha: 0.3) : Colors.transparent,
            width: 1,
          ),
        ),
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child:
                widget.artworkUri != null &&
                    (widget.artworkUri!.scheme == 'http' || widget.artworkUri!.scheme == 'https')
                ? Image.network(
                    widget.artworkUri.toString(),
                    key: ValueKey('remote-art-${widget.artworkUri}'),
                    width: 42,
                    height: 42,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.music_note_rounded, color: primary),
                  )
                : _albumArt != null
                ? ArtworkThumbnail(key: ValueKey('art-${widget.path}'), bytes: _albumArt!, size: 42, borderRadius: 10)
                : widget.isLoading
                ? Padding(
                    key: const ValueKey('loading'),
                    padding: const EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2, color: primary),
                  )
                : widget.isPlaying
                ? _WaveformIcon(key: const ValueKey('wave'), color: primary)
                : Icon(
                    key: const ValueKey('idle'),
                    widget.hasTrack ? Icons.music_note_rounded : Icons.music_off_rounded,
                    size: 20,
                    color: primary.withValues(alpha: 0.6),
                  ),
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

class _WaveformIconState extends State<_WaveformIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => SizedBox(
        height: 20,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(4, (index) {
            final wave = (math.sin((_controller.value * math.pi * 2) + index * 1.35) + 1) / 2;
            return Padding(
              padding: EdgeInsets.only(right: index == 3 ? 0 : 2),
              child: Container(
                width: 2.8,
                height: 4 + wave * 12,
                decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(2)),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _LoadingBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
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
          SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 1.5, color: color)),
          const SizedBox(width: 5),
          Text(
            'LOADING',
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: color),
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
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: primary),
      ),
    );
  }
}
