// lib/widgets/player/album_cover.dart

import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/app/theme.dart';
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
            final windowsNative = useWindowsNativeControls(context);
            return ValueListenableBuilder<PlaybackVisualState>(
              valueListenable: handler.playbackVisualNotifier,
              builder: (context, playback, _) {
                final isPlaying = playback.playing;
                final isLoading = playback.loading;
                final maxW = screenWidth < 500 ? (screenWidth - 32.0).clamp(0.0, double.infinity) : 640.0;

                return Center(
                  child: Container(
                    margin: EdgeInsets.fromLTRB(16, windowsNative ? 8 : 12, 16, windowsNative ? 8 : 12),
                    constraints: BoxConstraints(maxWidth: maxW),
                    width: double.infinity,
                    child: PlaybackPulse(
                      active: isPlaying && !isLoading,
                      borderRadius: windowsNative ? 8 : 16,
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
                        amplitudeProvider: () => handler.visualizerAmplitude,
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
  final double Function()? amplitudeProvider;

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
    this.amplitudeProvider,
  });

  @override
  Widget build(BuildContext context) {
    final primary = playerAccent ?? Theme.of(context).colorScheme.primary;
    final secondary = playerSecondary ?? primary;
    final surface = Theme.of(context).colorScheme.surface;
    final border = Theme.of(context).colorScheme.outline;
    final textPrimary = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A);
    const textMuted = Color(0xFF64748B);
    final windowsNative = useWindowsNativeControls(context);
    final cardRadius = windowsNative ? 8.0 : 16.0;

    final isActive = isPlaying || isLoading;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: nowPlayingCardTapKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(cardRadius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(horizontal: windowsNative ? 12 : 16, vertical: windowsNative ? 10 : 14),
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
            borderRadius: BorderRadius.circular(cardRadius),
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
                  child: _PocketVinyl(
                    isPlaying: isPlaying && !isLoading,
                    accent: primary,
                    amplitudeProvider: amplitudeProvider,
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

@visibleForTesting
const pocketVinylKey = Key('pocket-vinyl');

class _PocketVinyl extends StatefulWidget {
  final bool isPlaying;
  final Color accent;
  final double Function()? amplitudeProvider;
  final Widget child;

  const _PocketVinyl({required this.isPlaying, required this.accent, required this.child, this.amplitudeProvider});

  @override
  State<_PocketVinyl> createState() => _PocketVinylState();
}

class _PocketVinylState extends State<_PocketVinyl> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(seconds: 11));

  @override
  void initState() {
    super.initState();
    if (widget.isPlaying) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _PocketVinyl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying == oldWidget.isPlaying) return;
    if (widget.isPlaying) {
      _controller.repeat();
    } else {
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
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion) {
      _controller.stop();
    } else if (widget.isPlaying && !_controller.isAnimating) {
      _controller.repeat();
    }
    final recordLeft = widget.isPlaying && !reducedMotion ? 17.0 : 12.0;
    return SizedBox(
      key: pocketVinylKey,
      width: 58,
      height: 42,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedPositioned(
            duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 520),
            curve: Curves.easeOutBack,
            left: recordLeft,
            top: 1,
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final rawAmplitude = widget.isPlaying ? (widget.amplitudeProvider?.call() ?? 0.28) : 0.0;
                      final amplitude = math.sqrt(rawAmplitude.clamp(0.0, 1.0));
                      return Transform.rotate(
                        angle: _controller.value * math.pi * 2,
                        child: CustomPaint(
                          size: const Size.square(40),
                          painter: _PocketVinylPainter(
                            accent: widget.accent,
                            phase: _controller.value,
                            amplitude: amplitude,
                            active: widget.isPlaying && !reducedMotion,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          Positioned(left: 0, top: 0, child: widget.child),
        ],
      ),
    );
  }
}

class _PocketVinylPainter extends CustomPainter {
  final Color accent;
  final double phase;
  final double amplitude;
  final bool active;

  const _PocketVinylPainter({required this.accent, required this.phase, required this.amplitude, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    if (active) {
      canvas.drawCircle(
        center,
        radius - 0.5,
        Paint()
          ..color = accent.withValues(alpha: 0.13 + amplitude * 0.17)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + amplitude * 3.5),
      );
    }

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.30, -0.35),
          radius: 1.05,
          colors: <Color>[Color(0xFF393941), Color(0xFF15151A), Color(0xFF08080B)],
          stops: <double>[0, 0.48, 1],
        ).createShader(Offset.zero & size),
    );
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.55
      ..color = const Color(0xFF666672).withValues(alpha: 0.62);
    for (final fraction in <double>[0.41, 0.50, 0.59, 0.68, 0.77, 0.86]) {
      canvas.drawCircle(center, radius * fraction, groove);
    }

    // A diagonal lacquer reflection rotates with the record, making the spin
    // readable even when the label artwork is visually symmetrical.
    canvas.save();
    canvas.clipPath(Path()..addOval(Offset.zero & size));
    canvas.rotate(-0.16);
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.39, -5, size.width * 0.20, size.height + 10),
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.16 + amplitude * 0.10),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(size.width * 0.39, 0, size.width * 0.20, size.height)),
    );
    canvas.restore();

    final highlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.9
      ..color = Colors.white.withValues(alpha: 0.18 + amplitude * 0.14);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius * 0.73), -1.12, 0.72, false, highlight);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 0.55),
      2.02,
      0.48,
      false,
      highlight..color = Colors.white.withValues(alpha: 0.10 + amplitude * 0.08),
    );

    canvas.drawCircle(center, radius * 0.32, Paint()..color = accent);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 0.25),
      -math.pi / 2,
      math.pi * 0.72,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.75),
    );
    canvas.drawCircle(center, radius * 0.07, Paint()..color = const Color(0xFF111116));

    // Three brief glints per revolution mimic dust catching the light. The
    // high exponent keeps them rare instead of turning into a constant strobe.
    if (active) {
      final sparkle = math.pow(math.max(0.0, math.sin(phase * math.pi * 6)), 20).toDouble();
      if (sparkle > 0.02) {
        final point = Offset(size.width * 0.88, size.height * 0.22);
        final sparklePaint = Paint()
          ..color = Colors.white.withValues(alpha: sparkle * (0.55 + amplitude * 0.35))
          ..strokeWidth = 0.8
          ..strokeCap = StrokeCap.round;
        final reach = 1.2 + sparkle * 1.8;
        canvas.drawLine(point.translate(-reach, 0), point.translate(reach, 0), sparklePaint);
        canvas.drawLine(point.translate(0, -reach), point.translate(0, reach), sparklePaint);
        canvas.drawCircle(point, 0.7 + sparkle * 0.6, Paint()..color = accent.withValues(alpha: sparkle * 0.8));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PocketVinylPainter oldDelegate) =>
      oldDelegate.accent != accent ||
      oldDelegate.phase != phase ||
      oldDelegate.amplitude != amplitude ||
      oldDelegate.active != active;
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
    final artworkRadius = useWindowsNativeControls(context) ? 4.0 : 10.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(artworkRadius),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(artworkRadius),
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
