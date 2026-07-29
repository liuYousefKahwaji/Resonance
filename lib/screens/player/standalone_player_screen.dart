import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/widgets/common/overflowing_text.dart';
import 'package:resonance/widgets/player/audio_visualizer.dart';
import 'package:resonance/widgets/player/player_controls.dart';
import 'package:resonance/widgets/player/upcoming_queue.dart';
import 'package:resonance/widgets/player/vinyl_disc.dart';

const nowPlayingArtworkHeroTag = 'resonance-now-playing-artwork';

@visibleForTesting
const standaloneArtworkRevealKey = Key('standalone-artwork-vinyl-reveal');

@visibleForTesting
const standaloneVinylKey = Key('standalone-vinyl');

@visibleForTesting
const standaloneVinylRevealTransformKey = Key('standalone-vinyl-reveal-transform');

@visibleForTesting
const standaloneArtworkCoverKey = Key('standalone-artwork-cover');

@visibleForTesting
double standaloneArtworkSize(BoxConstraints constraints) {
  final compact = constraints.maxWidth < 760;
  final widthLimit = constraints.maxWidth * (compact ? 0.66 : 0.38);
  final heightLimit = constraints.maxHeight * (compact ? 0.76 : 0.82);
  return math.max(0, math.min(math.min(widthLimit, heightLimit), compact ? 380.0 : 420.0));
}

@visibleForTesting
List<Color> standaloneGradientColors(
  ThemeData theme, {
  Color? playerAccent,
  Color? playerSecondary,
  bool preserveOledSurface = false,
}) {
  final base = theme.scaffoldBackgroundColor;
  if (preserveOledSurface) return [base, base, base];
  final accent = playerAccent ?? theme.colorScheme.primary;
  final secondary = playerSecondary ?? accent;
  final dark = theme.brightness == Brightness.dark;
  return [
    Color.alphaBlend(accent.withValues(alpha: dark ? 0.68 : 0.44), base),
    Color.alphaBlend(secondary.withValues(alpha: dark ? 0.46 : 0.28), base),
    base,
  ];
}

@immutable
class StandaloneGradientFrame {
  final Offset primaryCenter;
  final Offset secondaryCenter;
  final Offset tertiaryCenter;
  final double primaryRadius;
  final double secondaryRadius;
  final double tertiaryRadius;

  const StandaloneGradientFrame({
    required this.primaryCenter,
    required this.secondaryCenter,
    required this.tertiaryCenter,
    required this.primaryRadius,
    required this.secondaryRadius,
    required this.tertiaryRadius,
  });
}

/// Samples three closed orbital paths. Sine and cosine make both the position
/// and velocity continuous when the repeating controller wraps back to zero.
@visibleForTesting
StandaloneGradientFrame standaloneGradientFrame(double progress) {
  final phase = progress.clamp(0.0, 1.0) * math.pi * 2;
  const orbit = math.pi * 2 / 3;
  return StandaloneGradientFrame(
    primaryCenter: Offset(0.50 + math.cos(phase) * 0.42, 0.28 + math.sin(phase) * 0.25),
    secondaryCenter: Offset(0.50 + math.cos(phase + orbit) * 0.45, 0.64 + math.sin(phase + orbit) * 0.30),
    tertiaryCenter: Offset(0.50 + math.cos(phase + orbit * 2) * 0.38, 0.54 + math.sin(phase + orbit * 2) * 0.36),
    primaryRadius: 0.68 + math.sin(phase + 0.45) * 0.10,
    secondaryRadius: 0.64 + math.sin(phase + orbit + 0.75) * 0.09,
    tertiaryRadius: 0.58 + math.sin(phase + orbit * 2 + 1.10) * 0.08,
  );
}

@visibleForTesting
class StandaloneGradientPainter extends CustomPainter {
  final List<Color> colors;
  final StandaloneGradientFrame frame;

  const StandaloneGradientPainter({required this.colors, required this.frame});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final base = colors.isEmpty ? Colors.transparent : colors.last;
    final primary = colors.isEmpty ? base : colors.first;
    final secondary = colors.length > 1 ? colors[1] : primary;
    final tertiary = Color.lerp(primary, secondary, 0.54) ?? primary;
    final bounds = Offset.zero & size;

    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color.lerp(base, secondary, 0.30) ?? base, base],
        ).createShader(bounds),
    );

    _drawBlob(canvas, size, tertiary, frame.tertiaryCenter, frame.tertiaryRadius, 0.70);
    _drawBlob(canvas, size, secondary, frame.secondaryCenter, frame.secondaryRadius, 0.86);
    _drawBlob(canvas, size, primary, frame.primaryCenter, frame.primaryRadius, 0.96);
  }

  void _drawBlob(
    Canvas canvas,
    Size size,
    Color color,
    Offset normalizedCenter,
    double normalizedRadius,
    double opacity,
  ) {
    final center = Offset(normalizedCenter.dx * size.width, normalizedCenter.dy * size.height);
    final radius = math.max(size.width, size.height) * normalizedRadius;
    final blobBounds = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            color.withValues(alpha: opacity),
            color.withValues(alpha: opacity * 0.58),
            color.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.38, 1],
        ).createShader(blobBounds),
    );
  }

  @override
  bool shouldRepaint(covariant StandaloneGradientPainter oldDelegate) =>
      !listEquals(colors, oldDelegate.colors) ||
      frame.primaryCenter != oldDelegate.frame.primaryCenter ||
      frame.secondaryCenter != oldDelegate.frame.secondaryCenter ||
      frame.tertiaryCenter != oldDelegate.frame.tertiaryCenter ||
      frame.primaryRadius != oldDelegate.frame.primaryRadius ||
      frame.secondaryRadius != oldDelegate.frame.secondaryRadius ||
      frame.tertiaryRadius != oldDelegate.frame.tertiaryRadius;
}

class StandaloneGradientSurface extends StatefulWidget {
  final List<Color> colors;
  final Widget child;

  const StandaloneGradientSurface({super.key, required this.colors, required this.child});

  @override
  State<StandaloneGradientSurface> createState() => _StandaloneGradientSurfaceState();
}

class _StandaloneGradientSurfaceState extends State<StandaloneGradientSurface> with TickerProviderStateMixin {
  late final AnimationController _motionController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  );
  late final AnimationController _paletteController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
    value: 1,
  );
  late List<Color> _fromColors = List<Color>.from(widget.colors);
  late List<Color> _toColors = List<Color>.from(widget.colors);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant StandaloneGradientSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.colors, widget.colors)) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _fromColors = List<Color>.from(widget.colors);
        _toColors = List<Color>.from(widget.colors);
        _paletteController
          ..stop()
          ..value = 1;
      } else {
        _fromColors = _interpolatedColors();
        _toColors = List<Color>.from(widget.colors);
        _paletteController.forward(from: 0);
      }
    }
    _syncMotion();
  }

  void _syncMotion() {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion) {
      _fromColors = List<Color>.from(widget.colors);
      _toColors = List<Color>.from(widget.colors);
      _paletteController
        ..stop()
        ..value = 1;
    }
    final solid = widget.colors.isEmpty || widget.colors.every((color) => color == widget.colors.first);
    if (!reducedMotion && !solid) {
      if (!_motionController.isAnimating) _motionController.repeat();
    } else {
      _motionController
        ..stop()
        ..value = 0;
    }
  }

  List<Color> _interpolatedColors() {
    final t = Curves.easeInOutCubic.transform(_paletteController.value);
    final length = math.max(_fromColors.length, _toColors.length);
    if (length == 0) return const <Color>[Colors.transparent, Colors.transparent, Colors.transparent];
    return List<Color>.generate(length, (index) {
      final from = _fromColors[math.min(index, _fromColors.length - 1)];
      final to = _toColors[math.min(index, _toColors.length - 1)];
      return Color.lerp(from, to, t)!;
    });
  }

  @override
  void dispose() {
    _motionController.dispose();
    _paletteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_motionController, _paletteController]),
      child: widget.child,
      builder: (context, child) {
        final frame = standaloneGradientFrame(_motionController.value);
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                key: const Key('standalone-animated-gradient'),
                painter: StandaloneGradientPainter(colors: _interpolatedColors(), frame: frame),
              ),
            ),
            if (child != null) child,
          ],
        );
      },
    );
  }
}

enum StandalonePlayerSwipeAction { next, previous, queue, exit }

const double _standaloneSwipeMinDistance = 56;
const double _standaloneSwipeAxisDominance = 1.2;

@visibleForTesting
StandalonePlayerSwipeAction? standalonePlayerSwipeAction(Offset dragOffset) {
  final horizontalDistance = dragOffset.dx.abs();
  final verticalDistance = dragOffset.dy.abs();

  if (horizontalDistance >= _standaloneSwipeMinDistance &&
      horizontalDistance >= verticalDistance * _standaloneSwipeAxisDominance) {
    return dragOffset.dx < 0 ? StandalonePlayerSwipeAction.next : StandalonePlayerSwipeAction.previous;
  }
  if (dragOffset.dy >= _standaloneSwipeMinDistance &&
      verticalDistance >= horizontalDistance * _standaloneSwipeAxisDominance) {
    return StandalonePlayerSwipeAction.exit;
  }
  if (dragOffset.dy <= -_standaloneSwipeMinDistance &&
      verticalDistance >= horizontalDistance * _standaloneSwipeAxisDominance) {
    return StandalonePlayerSwipeAction.queue;
  }
  return null;
}

/// Recognizes touch swipes on Android and click-drags on Windows without
/// stealing simple taps from the controls contained in [child].
@visibleForTesting
class StandalonePlayerGestureSurface extends StatefulWidget {
  final Widget child;
  final VoidCallback onNext;
  final void Function({required bool restartCurrent}) onPrevious;
  final VoidCallback onQueue;
  final VoidCallback onExit;

  const StandalonePlayerGestureSurface({
    super.key,
    required this.child,
    required this.onNext,
    required this.onPrevious,
    required this.onQueue,
    required this.onExit,
  });

  @override
  State<StandalonePlayerGestureSurface> createState() => _StandalonePlayerGestureSurfaceState();
}

class _StandalonePlayerGestureSurfaceState extends State<StandalonePlayerGestureSurface> {
  Offset _dragOffset = Offset.zero;

  void _handlePanStart(DragStartDetails _) => _dragOffset = Offset.zero;

  void _handlePanUpdate(DragUpdateDetails details) => _dragOffset += details.delta;

  void _handlePanCancel() => _dragOffset = Offset.zero;

  void _handlePanEnd(DragEndDetails _) {
    final action = standalonePlayerSwipeAction(_dragOffset);
    _dragOffset = Offset.zero;
    switch (action) {
      case StandalonePlayerSwipeAction.next:
        widget.onNext();
      case StandalonePlayerSwipeAction.previous:
        widget.onPrevious(restartCurrent: false);
      case StandalonePlayerSwipeAction.queue:
        widget.onQueue();
      case StandalonePlayerSwipeAction.exit:
        widget.onExit();
      case null:
        return;
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    supportedDevices: const {
      PointerDeviceKind.touch,
      PointerDeviceKind.mouse,
      PointerDeviceKind.stylus,
      PointerDeviceKind.invertedStylus,
      PointerDeviceKind.trackpad,
    },
    onPanStart: _handlePanStart,
    onPanUpdate: _handlePanUpdate,
    onPanCancel: _handlePanCancel,
    onPanEnd: _handlePanEnd,
    child: widget.child,
  );
}

class StandalonePlayerScreen extends StatelessWidget {
  final bool playlistTrack;

  const StandalonePlayerScreen({super.key, this.playlistTrack = false});

  @override
  Widget build(BuildContext context) {
    final handler = context.read<PlayerHandler>();
    final theme = Theme.of(context);
    final themeProvider = context.watch<ThemeProvider>();
    final playerAccent = themeProvider.playerAccent(theme.colorScheme.primary, theme.brightness);
    final playerSecondary = themeProvider.playerSecondary(theme.colorScheme.secondary, theme.brightness);
    final playerTheme = theme.copyWith(
      colorScheme: theme.colorScheme.copyWith(primary: playerAccent, secondary: playerSecondary),
    );
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      initialData: handler.mediaItem.value,
      builder: (context, snapshot) {
        final item = snapshot.data;
        final artist = item?.artist?.trim();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) context.read<ThemeProvider>().updatePlayerArtwork(item?.artUri);
        });
        final gradientColors = standaloneGradientColors(
          theme,
          playerAccent: playerAccent,
          playerSecondary: playerSecondary,
          preserveOledSurface: themeProvider.hasArtworkPalette && themeProvider.preserveOledPlayerSurface,
        );
        return PopScope(
          onPopInvokedWithResult: (didPop, _) {
            if (didPop && playlistTrack) handler.setStandalonePresentation(false);
          },
          child: StandalonePlayerGestureSurface(
            key: const Key('standalone-player-gesture-surface'),
            onNext: handler.next,
            onPrevious: handler.previous,
            onQueue: () => _showUpcomingQueue(context, handler),
            onExit: () => Navigator.maybePop(context),
            child: StandaloneGradientSurface(
              colors: gradientColors,
              child: Theme(
                data: playerTheme,
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  appBar: AppBar(
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    centerTitle: true,
                    leading: IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      tooltip: 'Back to playlist',
                      onPressed: () => Navigator.pop(context),
                    ),
                    title: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'PLAYING FROM',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.3,
                          ),
                        ),
                        Text(
                          artist == null || artist.isEmpty ? 'Resonance' : artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                  body: ValueListenableBuilder<PlaybackVisualState>(
                    valueListenable: handler.playbackVisualNotifier,
                    builder: (context, playback, _) => Column(
                      children: [
                        Expanded(
                          child: ValueListenableBuilder<TrackTransitionState>(
                            valueListenable: handler.trackTransitionNotifier,
                            builder: (context, transition, _) => _AnimatedTrackContent(
                              item: item,
                              isPlaying: playback.playing,
                              direction: transition.direction,
                            ),
                          ),
                        ),
                        _StandaloneMetadata(item: item),
                        const PlayerControls(standalone: true),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

void _showUpcomingQueue(BuildContext context, PlayerHandler handler) {
  if (!Platform.isAndroid) return;
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final height = MediaQuery.sizeOf(sheetContext).height;
      return SizedBox(
        height: (height * 0.62).clamp(360.0, 560.0),
        child: UpcomingQueuePanel(
          compact: true,
          mediaItemStream: handler.mediaItem,
          initialMediaItem: handler.mediaItem.value,
          revision: handler.playbackModeRevision,
          loadSnapshot: handler.playbackQueueSnapshot,
          onClose: () => Navigator.pop(sheetContext),
        ),
      );
    },
  );
}

class _AnimatedTrackContent extends StatelessWidget {
  final MediaItem? item;
  final bool isPlaying;
  final TrackTransitionDirection direction;

  const _AnimatedTrackContent({required this.item, required this.isPlaying, required this.direction});

  @override
  Widget build(BuildContext context) {
    final incomingKey = ValueKey(item?.id);
    final incomingOffset = switch (direction) {
      TrackTransitionDirection.next => const Offset(0.22, 0),
      TrackTransitionDirection.previous => const Offset(-0.22, 0),
      TrackTransitionDirection.none => Offset.zero,
    };
    final outgoingOffset = Offset(-incomingOffset.dx, 0);

    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        reverseDuration: const Duration(milliseconds: 360),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) =>
            Stack(alignment: Alignment.center, children: [...previousChildren, if (currentChild != null) currentChild]),
        transitionBuilder: (child, animation) {
          final isIncoming = child.key == incomingKey;
          final offset = isIncoming ? incomingOffset : outgoingOffset;
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(begin: offset, end: Offset.zero).animate(animation),
              child: child,
            ),
          );
        },
        child: _TrackContent(key: incomingKey, item: item, isPlaying: isPlaying),
      ),
    );
  }
}

class _TrackContent extends StatelessWidget {
  final MediaItem? item;
  final bool isPlaying;

  const _TrackContent({super.key, required this.item, required this.isPlaying});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 760;
      final size = standaloneArtworkSize(constraints);
      return Center(
        child: Padding(
          padding: EdgeInsets.all(compact ? 16 : 24),
          child: _ArtworkBox(item: item, isPlaying: isPlaying, size: size),
        ),
      );
    },
  );
}

class _ArtworkBox extends StatelessWidget {
  final MediaItem? item;
  final bool isPlaying;
  final double size;

  const _ArtworkBox({required this.item, required this.isPlaying, required this.size});

  @override
  Widget build(BuildContext context) {
    final artworkSize = math.max(0.0, size);
    return SizedBox(
      width: artworkSize * 1.30,
      height: artworkSize,
      child: StandaloneArtworkVinylReveal(
        item: item,
        isPlaying: isPlaying,
        amplitudeProvider: () => context.read<PlayerHandler>().visualizerAmplitude,
      ),
    );
  }
}

class _StandaloneMetadata extends StatelessWidget {
  final MediaItem? item;

  const _StandaloneMetadata({required this.item});

  @override
  Widget build(BuildContext context) {
    final artist = item?.artist ?? '';
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(Platform.isWindows ? 32 : 24, 8, Platform.isWindows ? 32 : 24, 6),
      child: Align(
        alignment: Platform.isWindows ? Alignment.centerLeft : Alignment.center,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: Platform.isWindows ? double.infinity : 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 28,
                width: double.infinity,
                child: OverflowingText(
                  text: item?.title ?? 'Nothing playing',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.2),
                ),
              ),
              if (artist.isNotEmpty) ...[
                const SizedBox(height: 2),
                SizedBox(
                  height: 20,
                  width: double.infinity,
                  child: OverflowingText(
                    text: artist,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
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
class StandaloneArtworkVinylReveal extends StatefulWidget {
  final MediaItem? item;
  final bool isPlaying;
  final double Function() amplitudeProvider;

  const StandaloneArtworkVinylReveal({
    super.key,
    required this.item,
    required this.isPlaying,
    required this.amplitudeProvider,
  });

  @override
  State<StandaloneArtworkVinylReveal> createState() => _StandaloneArtworkVinylRevealState();
}

class _StandaloneArtworkVinylRevealState extends State<StandaloneArtworkVinylReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _revealController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    reverseDuration: const Duration(milliseconds: 520),
  );
  late final Animation<double> _revealAnimation = CurvedAnimation(
    parent: _revealController,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInOutCubic,
  );
  bool _vinylRequested = false;

  @override
  void didUpdateWidget(covariant StandaloneArtworkVinylReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.id != widget.item?.id) {
      _revealController.value = 0;
      _vinylRequested = false;
    }
  }

  @override
  void dispose() {
    _revealController.dispose();
    super.dispose();
  }

  void _toggleVinyl() {
    if (widget.item == null) return;
    if (_vinylRequested) {
      setState(() => _vinylRequested = false);
      _revealController.reverse();
    } else {
      setState(() => _vinylRequested = true);
      _revealController.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: widget.item != null,
      label: _vinylRequested
          ? 'Album cover with vinyl revealed. Tap to tuck the vinyl away'
          : 'Album cover. Tap to reveal the vinyl',
      child: GestureDetector(
        key: standaloneArtworkRevealKey,
        behavior: HitTestBehavior.opaque,
        onTap: widget.item == null ? null : _toggleVinyl,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final coverSize = math.min(constraints.maxHeight, constraints.maxWidth / 1.30);
            return AnimatedBuilder(
              animation: _revealAnimation,
              builder: (context, _) {
                final progress = _revealAnimation.value;
                final clampedProgress = progress.clamp(0.0, 1.0);
                final discSize = coverSize * 0.92;
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Transform.translate(
                      key: standaloneVinylRevealTransformKey,
                      offset: Offset(
                        coverSize * 0.30 * progress,
                        -coverSize * 0.025 * math.sin(clampedProgress * math.pi),
                      ),
                      child: Transform.rotate(
                        angle: -0.08 + clampedProgress * 0.12,
                        child: Transform.scale(
                          scale: 0.97 + clampedProgress * 0.03,
                          child: ResonanceVinylDisc(
                            key: standaloneVinylKey,
                            size: discSize,
                            spinning: widget.isPlaying && (_vinylRequested || _revealController.value > 0),
                            accent: accent,
                            amplitudeProvider: widget.amplitudeProvider,
                          ),
                        ),
                      ),
                    ),
                    SizedBox.square(
                      key: standaloneArtworkCoverKey,
                      dimension: coverSize,
                      child: PlaybackPulse(
                        active: widget.isPlaying,
                        borderRadius: 28,
                        reach: 22,
                        amplitudeProvider: widget.amplitudeProvider,
                        child: Hero(
                          tag: nowPlayingArtworkHeroTag,
                          child: _LargeArtwork(item: widget.item),
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
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
    final image = uri != null && uri.scheme == 'file'
        ? Image.file(
            File.fromUri(uri),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _ArtworkFallback(primary: primary),
          )
        : uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
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
