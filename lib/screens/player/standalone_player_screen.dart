import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/widgets/common/overflowing_text.dart';
import 'package:resonance/widgets/player/audio_visualizer.dart';
import 'package:resonance/widgets/player/player_controls.dart';

const nowPlayingArtworkHeroTag = 'resonance-now-playing-artwork';

@visibleForTesting
double standaloneArtworkSize(BoxConstraints constraints) {
  final compact = constraints.maxWidth < 760;
  final widthLimit = constraints.maxWidth * (compact ? 0.66 : 0.38);
  final heightLimit = constraints.maxHeight * (compact ? 0.76 : 0.82);
  return math.max(0, math.min(math.min(widthLimit, heightLimit), compact ? 380.0 : 420.0));
}

@visibleForTesting
List<Color> standaloneGradientColors(ThemeData theme) {
  final base = theme.scaffoldBackgroundColor;
  final accent = theme.colorScheme.primary;
  final dark = theme.brightness == Brightness.dark;
  return [
    Color.alphaBlend(accent.withValues(alpha: dark ? 0.46 : 0.30), base),
    Color.alphaBlend(accent.withValues(alpha: dark ? 0.20 : 0.13), base),
    base,
  ];
}

enum StandalonePlayerSwipeAction { next, previous, exit }

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
  return null;
}

/// Recognizes touch swipes on Android and click-drags on Windows without
/// stealing simple taps from the controls contained in [child].
@visibleForTesting
class StandalonePlayerGestureSurface extends StatefulWidget {
  final Widget child;
  final VoidCallback onNext;
  final void Function({required bool restartCurrent}) onPrevious;
  final VoidCallback onExit;

  const StandalonePlayerGestureSurface({
    super.key,
    required this.child,
    required this.onNext,
    required this.onPrevious,
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
    final gradientColors = standaloneGradientColors(theme);
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      initialData: handler.mediaItem.value,
      builder: (context, snapshot) {
        final item = snapshot.data;
        final artist = item?.artist?.trim();
        return PopScope(
          onPopInvokedWithResult: (didPop, _) {
            if (didPop && playlistTrack) handler.setStandalonePresentation(false);
          },
          child: StandalonePlayerGestureSurface(
            key: const Key('standalone-player-gesture-surface'),
            onNext: handler.next,
            onPrevious: handler.previous,
            onExit: () => Navigator.maybePop(context),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, 0.50, 1],
                  colors: gradientColors,
                ),
              ),
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
        );
      },
    );
  }
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
  Widget build(BuildContext context) => SizedBox.square(
    dimension: math.max(0, size),
    child: _VisualizedArtwork(item: item, isPlaying: isPlaying),
  );
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

class _VisualizedArtwork extends StatelessWidget {
  final MediaItem? item;
  final bool isPlaying;

  const _VisualizedArtwork({required this.item, required this.isPlaying});

  @override
  Widget build(BuildContext context) {
    return PlaybackPulse(
      active: isPlaying,
      borderRadius: 28,
      reach: 22,
      amplitudeProvider: () => context.read<PlayerHandler>().visualizerAmplitude,
      child: Hero(
        tag: nowPlayingArtworkHeroTag,
        child: _LargeArtwork(item: item),
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
