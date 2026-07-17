// lib/widgets/player/album_cover.dart

import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/widgets/player/audio_visualizer.dart';

class AlbumCover extends StatelessWidget {
  final ValueChanged<String>? onTap;
  final ValueChanged<String>? onArtworkTap;
  final VoidCallback? onQueueRequested;
  final int artworkRevision;
  const AlbumCover({super.key, this.onTap, this.onArtworkTap, this.onQueueRequested, this.artworkRevision = 0});

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;

    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, mediaSnapshot) {
        final item = mediaSnapshot.data;
        final path = item?.id ?? '';
        final rawTitle = item?.title ?? '';
        final title = rawTitle.isNotEmpty ? rawTitle : 'Nothing playing';
        final artist = item?.artist ?? '';
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) context.read<ThemeProvider>().updatePlayerArtwork(item?.artUri);
        });

        return Consumer<ThemeProvider>(
          builder: (context, themeProvider, _) {
            final theme = Theme.of(context);
            final accent = themeProvider.playerAccent(theme.colorScheme.primary, theme.brightness);
            final secondary = themeProvider.playerSecondary(theme.colorScheme.secondary, theme.brightness);
            return ValueListenableBuilder<PlaybackVisualState>(
              valueListenable: handler.playbackVisualNotifier,
              builder: (context, playback, _) {
                final isPlaying = playback.playing;
                final isLoading = playback.loading;
                final maxW = screenWidth < 500 ? (screenWidth - 32.0).clamp(0.0, double.infinity) : 640.0;

                return Center(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    constraints: BoxConstraints(maxWidth: maxW),
                    width: double.infinity,
                    child: PlaybackPulse(
                      active: isPlaying && !isLoading,
                      borderRadius: 16,
                      reach: 14,
                      color: accent,
                      amplitudeProvider: () => handler.visualizerAmplitude,
                      child: NowPlayingCard(
                        title: title,
                        artist: artist,
                        artworkUri: item?.artUri,
                        isPlaying: isPlaying,
                        isLoading: isLoading,
                        hasTrack: item != null,
                        isDark: isDark,
                        playerAccent: accent,
                        playerSecondary: secondary,
                        tintSurface: themeProvider.hasArtworkPalette && !themeProvider.preserveOledPlayerSurface,
                        showQueueButton: Platform.isWindows && item != null && onQueueRequested != null,
                        onQueueTap: onQueueRequested,
                        onTap: item == null ? null : () => onTap?.call(path),
                        onArtworkTap: item == null ? null : () => onArtworkTap?.call(path),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

@visibleForTesting
const nowPlayingCardTapKey = Key('now-playing-card-tap');

@visibleForTesting
const nowPlayingArtworkTapKey = Key('now-playing-artwork-tap');

@visibleForTesting
class NowPlayingCard extends StatelessWidget {
  final String title;
  final String artist;
  final Uri? artworkUri;
  final bool isPlaying;
  final bool isLoading;
  final bool hasTrack;
  final bool isDark;
  final VoidCallback? onTap;
  final VoidCallback? onArtworkTap;
  final Color? playerAccent;
  final Color? playerSecondary;
  final bool tintSurface;
  final bool showQueueButton;
  final VoidCallback? onQueueTap;

  const NowPlayingCard({
    super.key,
    required this.title,
    required this.artist,
    required this.artworkUri,
    required this.isPlaying,
    required this.isLoading,
    required this.hasTrack,
    required this.isDark,
    required this.onTap,
    required this.onArtworkTap,
    this.playerAccent,
    this.playerSecondary,
    this.tintSurface = false,
    this.showQueueButton = false,
    this.onQueueTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = playerAccent ?? Theme.of(context).colorScheme.primary;
    final secondary = playerSecondary ?? primary;
    final surface = Theme.of(context).colorScheme.surface;
    final border = Theme.of(context).colorScheme.outline;
    final textPrimary = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);

    final isActive = isPlaying || isLoading;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: nowPlayingCardTapKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: tintSurface ? null : surface,
            gradient: tintSurface
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.alphaBlend(primary.withValues(alpha: isDark ? 0.18 : 0.10), surface),
                      Color.alphaBlend(secondary.withValues(alpha: isDark ? 0.11 : 0.06), surface),
                    ],
                  )
                : null,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isActive ? primary.withValues(alpha: 0.4) : border, width: isActive ? 1.5 : 1),
          ),
          child: Row(
            // Prevent the Row from overflowing — each child must be sized.
            mainAxisSize: MainAxisSize.max,
            children: [
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  key: nowPlayingArtworkTapKey,
                  onTap: onArtworkTap,
                  borderRadius: BorderRadius.circular(10),
                  child: Hero(
                    tag: nowPlayingArtworkHeroTag,
                    child: _AlbumIcon(
                      isPlaying: isPlaying,
                      hasTrack: hasTrack,
                      isLoading: isLoading,
                      artworkUri: artworkUri,
                    ),
                  ),
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
              if (showQueueButton) ...[
                const SizedBox(width: 6),
                IconButton(
                  key: const Key('upcoming-queue-button'),
                  onPressed: onQueueTap,
                  tooltip: 'Upcoming tracks',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.queue_music_rounded, size: 20, color: primary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumIcon extends StatelessWidget {
  final bool isPlaying;
  final bool isLoading;
  final bool hasTrack;
  final Uri? artworkUri;

  const _AlbumIcon({
    required this.isPlaying,
    required this.hasTrack,
    required this.artworkUri,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? primary.withValues(alpha: 0.15) : primary.withValues(alpha: 0.08);
    final uri = artworkUri;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (isPlaying || isLoading) ? primary.withValues(alpha: 0.3) : Colors.transparent,
            width: 1,
          ),
        ),
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
                ? Image.network(
                    uri.toString(),
                    key: ValueKey('remote-art-$uri'),
                    width: 42,
                    height: 42,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.music_note_rounded, color: primary),
                  )
                : uri != null && uri.scheme == 'file'
                ? Image.file(
                    File.fromUri(uri),
                    key: ValueKey('local-art-$uri'),
                    width: 42,
                    height: 42,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.music_note_rounded, color: primary),
                  )
                : isLoading
                ? Padding(
                    key: const ValueKey('loading'),
                    padding: const EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2, color: primary),
                  )
                : isPlaying
                ? _PulsingMusicIcon(key: const ValueKey('pulse'), color: primary)
                : Icon(
                    key: const ValueKey('idle'),
                    hasTrack ? Icons.music_note_rounded : Icons.music_off_rounded,
                    size: 20,
                    color: primary.withValues(alpha: 0.6),
                  ),
          ),
        ),
      ),
    );
  }
}

class _PulsingMusicIcon extends StatefulWidget {
  final Color color;
  const _PulsingMusicIcon({super.key, required this.color});

  @override
  State<_PulsingMusicIcon> createState() => _PulsingMusicIconState();
}

class _PulsingMusicIconState extends State<_PulsingMusicIcon> with SingleTickerProviderStateMixin {
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
      builder: (context, _) {
        final pulse = (math.sin(_controller.value * math.pi * 2) + 1) / 2;
        return Transform.scale(
          scale: 0.88 + pulse * 0.16,
          child: Icon(
            Icons.music_note_rounded,
            size: 22,
            color: widget.color.withValues(alpha: 0.70 + pulse * 0.30),
            shadows: [
              Shadow(
                color: widget.color.withValues(alpha: 0.24 + pulse * 0.30),
                blurRadius: 5 + pulse * 7,
              ),
            ],
          ),
        );
      },
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
