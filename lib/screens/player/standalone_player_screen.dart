import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/models/lyrics.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/services/lyrics_service.dart';
import 'package:resonance/services/lyrics_display_preferences.dart';
import 'package:resonance/services/sync/sync_session_service.dart';
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
const standaloneVinylCompositionTransformKey = Key('standalone-vinyl-composition-transform');

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
double standaloneLyricsVerticalInset(BoxConstraints constraints) => (constraints.maxHeight * 0.035).clamp(10.0, 24.0);

@visibleForTesting
double standaloneVinylCompositionShift(double coverSize, double revealProgress) =>
    coverSize * 0.13 * revealProgress.clamp(0.0, 1.0);

@visibleForTesting
List<Color> standaloneGradientColors(
  ThemeData theme, {
  Color? playerAccent,
  Color? playerSecondary,
  List<Color>? playerColors,
  bool preserveOledSurface = false,
}) {
  final base = theme.scaffoldBackgroundColor;
  if (preserveOledSurface) return [base, base, base];
  final accent = playerAccent ?? theme.colorScheme.primary;
  final secondary = playerSecondary ?? accent;
  final sources = playerColors ?? <Color>[accent, secondary];
  return <Color>[
    for (final color in sources)
      Color.alphaBlend(color.withValues(alpha: theme.brightness == Brightness.dark ? 0.64 : 0.42), base),
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
    final swatches = colors.length > 1 ? colors.sublist(0, colors.length - 1) : <Color>[base];
    final secondary = swatches.length > 1 ? swatches[1] : swatches.first;
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

    final centers = <Offset>[frame.primaryCenter, frame.secondaryCenter, frame.tertiaryCenter];
    final radii = <double>[frame.primaryRadius, frame.secondaryRadius, frame.tertiaryRadius];
    for (var index = swatches.length - 1; index >= 0; index--) {
      final orbit = index % centers.length;
      final ring = index ~/ centers.length;
      final ringOffset = ring == 0 ? Offset.zero : Offset(index.isEven ? 0.11 : -0.11, index.isEven ? -0.08 : 0.08);
      final center = Offset(
        (centers[orbit].dx + ringOffset.dx).clamp(-0.12, 1.12),
        (centers[orbit].dy + ringOffset.dy).clamp(-0.12, 1.12),
      );
      _drawBlob(
        canvas,
        size,
        swatches[index],
        center,
        radii[orbit] * (ring == 0 ? 1 : 0.82),
        (0.96 - index * 0.07).clamp(0.54, 0.96),
      );
    }
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
  final bool queueOnly;

  const StandalonePlayerGestureSurface({
    super.key,
    required this.child,
    required this.onNext,
    required this.onPrevious,
    required this.onQueue,
    required this.onExit,
    this.queueOnly = false,
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
    if (widget.queueOnly) {
      if (action == StandalonePlayerSwipeAction.queue) widget.onQueue();
      return;
    }
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

class StandalonePlayerScreen extends StatefulWidget {
  final bool playlistTrack;
  final bool syncPeer;

  const StandalonePlayerScreen({super.key, this.playlistTrack = false, this.syncPeer = false});

  @override
  State<StandalonePlayerScreen> createState() => _StandalonePlayerScreenState();
}

class _StandalonePlayerScreenState extends State<StandalonePlayerScreen> {
  bool _lyricsVisible = false;
  bool _queueDrawerOpen = false;
  bool _leavingSync = false;

  @override
  void initState() {
    super.initState();
    if (widget.syncPeer) SyncSessionService.instance.addListener(_onSyncChanged);
  }

  void _onSyncChanged() {
    if (!mounted || _leavingSync || SyncSessionService.instance.isPeer) return;
    setState(() => _leavingSync = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.maybePop(context);
    });
  }

  @override
  void dispose() {
    if (widget.syncPeer) SyncSessionService.instance.removeListener(_onSyncChanged);
    super.dispose();
  }

  Future<void> _leaveSync() async {
    if (_leavingSync) return;
    setState(() => _leavingSync = true);
    await SyncSessionService.instance.leave();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final handler = context.read<PlayerHandler>();
    final theme = Theme.of(context);
    final themeProvider = context.watch<ThemeProvider>();
    final playerAccent = themeProvider.playerAccent(theme.colorScheme.primary, theme.brightness);
    final playerSecondary = themeProvider.playerSecondary(theme.colorScheme.secondary, theme.brightness);
    final gradientPalette = themeProvider.playerGradientColors(theme.colorScheme.primary, theme.colorScheme.secondary);
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
          playerColors: gradientPalette,
          preserveOledSurface: themeProvider.hasArtworkPalette && themeProvider.preserveOledPlayerSurface,
        );
        return PopScope(
          canPop: !widget.syncPeer || _leavingSync,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop && widget.playlistTrack) handler.setStandalonePresentation(false);
          },
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
                    icon: Icon(widget.syncPeer ? Icons.logout_rounded : Icons.keyboard_arrow_down_rounded),
                    tooltip: widget.syncPeer ? 'Leave Resonance Sync' : 'Back to playlist',
                    onPressed: widget.syncPeer ? _leaveSync : () => Navigator.pop(context),
                  ),
                  title: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.syncPeer ? 'PLAYING WITH' : 'PLAYING FROM',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.3,
                        ),
                      ),
                      Text(
                        widget.syncPeer
                            ? SyncSessionService.instance.hostName ?? 'Resonance Sync'
                            : artist == null || artist.isEmpty
                            ? 'Resonance'
                            : artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                  actions: [
                    if (Platform.isWindows)
                      IconButton(
                        key: const Key('standalone-queue-toggle'),
                        tooltip: _queueDrawerOpen ? 'Hide queue' : 'Show queue',
                        onPressed: () => _toggleUpcomingQueue(context, handler),
                        icon: Icon(_queueDrawerOpen ? Icons.queue_music_rounded : Icons.queue_music_outlined),
                      ),
                    IconButton(
                      key: const Key('standalone-lyrics-toggle'),
                      tooltip: _lyricsVisible ? 'Hide lyrics' : 'Show lyrics',
                      onPressed: () => setState(() => _lyricsVisible = !_lyricsVisible),
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: Icon(
                          _lyricsVisible ? Icons.lyrics_rounded : Icons.lyrics_outlined,
                          key: ValueKey(_lyricsVisible),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                body: _buildStandaloneBody(
                  context,
                  handler,
                  ValueListenableBuilder<PlaybackVisualState>(
                    valueListenable: handler.playbackVisualNotifier,
                    builder: (context, playback, _) => Column(
                      children: [
                        Expanded(
                          child: ValueListenableBuilder<TrackTransitionState>(
                            valueListenable: handler.trackTransitionNotifier,
                            builder: (context, transition, _) => LayoutBuilder(
                              builder: (context, constraints) {
                                final artwork = _AnimatedTrackContent(
                                  item: item,
                                  isPlaying: playback.playing,
                                  direction: transition.direction,
                                );
                                if (!_lyricsVisible) return artwork;
                                final lyrics = Padding(
                                  key: const Key('standalone-lyrics-panel-padding'),
                                  padding: EdgeInsets.symmetric(vertical: standaloneLyricsVerticalInset(constraints)),
                                  child: _LyricsPanel(item: item, handler: handler),
                                );
                                if (constraints.maxWidth < 960) return lyrics;
                                return Row(
                                  children: [
                                    Expanded(child: artwork),
                                    SizedBox(width: math.min(500, constraints.maxWidth * 0.43), child: lyrics),
                                    const SizedBox(width: 22),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                        _StandaloneMetadata(item: item),
                        PlayerControls(standalone: true, transportLocked: widget.syncPeer),
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

  void _toggleUpcomingQueue(BuildContext context, PlayerHandler handler) {
    if (Platform.isWindows) {
      setState(() => _queueDrawerOpen = !_queueDrawerOpen);
      return;
    }
    if (Platform.isAndroid) {
      _showAndroidUpcomingQueue(context, handler, allowSelection: !widget.syncPeer);
    }
  }

  Widget _buildStandaloneBody(BuildContext context, PlayerHandler handler, Widget player) {
    final playerPane = StandalonePlayerGestureSurface(
      key: const Key('standalone-player-gesture-surface'),
      onNext: handler.next,
      onPrevious: handler.previous,
      onQueue: () => _toggleUpcomingQueue(context, handler),
      onExit: () => Navigator.maybePop(context),
      queueOnly: widget.syncPeer,
      child: player,
    );
    if (!Platform.isWindows || !_queueDrawerOpen) return playerPane;
    return LayoutBuilder(
      builder: (context, constraints) {
        final drawerWidth = (constraints.maxWidth * 0.30).clamp(280.0, 380.0);
        return Row(
          children: [
            Expanded(child: playerPane),
            SizedBox(
              key: const Key('standalone-windows-queue'),
              width: drawerWidth,
              child: UpcomingQueuePanel(
                mediaItemStream: handler.mediaItem,
                initialMediaItem: handler.mediaItem.value,
                revision: handler.playbackModeRevision,
                loadSnapshot: handler.playbackQueueSnapshot,
                resolveArtwork: handler.queueArtworkUri,
                onPlay: widget.syncPeer ? null : handler.playPlaybackQueueEntry,
                onClose: () => setState(() => _queueDrawerOpen = false),
              ),
            ),
          ],
        );
      },
    );
  }
}

void _showAndroidUpcomingQueue(BuildContext context, PlayerHandler handler, {required bool allowSelection}) {
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
          resolveArtwork: handler.queueArtworkUri,
          onPlay: allowSelection ? handler.playPlaybackQueueEntry : null,
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

class _LyricsPanel extends StatefulWidget {
  final MediaItem? item;
  final PlayerHandler handler;

  const _LyricsPanel({required this.item, required this.handler});

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

enum _LyricsFollowState { following, pausedByUser }

class _LyricsPanelState extends State<_LyricsPanel> with SingleTickerProviderStateMixin {
  final _scrollController = ScrollController();
  LyricsDocument? _document;
  Object? _error;
  bool _loading = true;
  int _generation = 0;
  int _activeLine = -1;
  _LyricsFollowState _followState = _LyricsFollowState.following;
  StreamSubscription<Duration>? _positionSubscription;
  final ValueNotifier<Duration> _lyricPosition = ValueNotifier(Duration.zero);
  final Stopwatch _interpolationClock = Stopwatch()..start();
  late final Ticker _lyricsTicker;
  Duration _anchorPosition = Duration.zero;
  Duration _anchorClock = Duration.zero;
  Duration _lastFrameClock = Duration.zero;
  bool _anchorPlaying = false;
  double _anchorSpeed = 1;
  bool _scrollScheduled = false;
  int? _pendingScrollIndex;
  bool _pendingScrollJump = false;
  List<GlobalKey> _lineKeys = const [];

  @override
  void initState() {
    super.initState();
    _anchorPosition = widget.handler.currentPosition;
    _anchorClock = _interpolationClock.elapsed;
    _anchorPlaying = widget.handler.playbackVisualNotifier.value.playing;
    _anchorSpeed = widget.handler.speedNotifier.value;
    _lyricsTicker = createTicker(_onLyricsTick)..start();
    widget.handler.playbackVisualNotifier.addListener(_onPlaybackVisualChanged);
    widget.handler.speedNotifier.addListener(_onPlaybackSpeedChanged);
    _positionSubscription = widget.handler.positionStream.listen(_onPosition);
    _load();
  }

  @override
  void didUpdateWidget(covariant _LyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.handler != widget.handler) {
      oldWidget.handler.playbackVisualNotifier.removeListener(_onPlaybackVisualChanged);
      oldWidget.handler.speedNotifier.removeListener(_onPlaybackSpeedChanged);
      unawaited(_positionSubscription?.cancel());
      _anchorPosition = widget.handler.currentPosition;
      _anchorClock = _interpolationClock.elapsed;
      _anchorPlaying = widget.handler.playbackVisualNotifier.value.playing;
      _anchorSpeed = widget.handler.speedNotifier.value;
      widget.handler.playbackVisualNotifier.addListener(_onPlaybackVisualChanged);
      widget.handler.speedNotifier.addListener(_onPlaybackSpeedChanged);
      _positionSubscription = widget.handler.positionStream.listen(_onPosition);
    }
    final oldItem = oldWidget.item;
    final item = widget.item;
    final durationBecameAvailable = (oldItem?.duration?.inSeconds ?? 0) <= 0 && (item?.duration?.inSeconds ?? 0) > 0;
    if (oldItem?.id != item?.id ||
        oldItem?.title != item?.title ||
        oldItem?.artist != item?.artist ||
        oldItem?.album != item?.album ||
        durationBecameAvailable) {
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.handler.playbackVisualNotifier.removeListener(_onPlaybackVisualChanged);
    widget.handler.speedNotifier.removeListener(_onPlaybackSpeedChanged);
    unawaited(_positionSubscription?.cancel());
    _lyricsTicker.dispose();
    _lyricPosition.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final generation = ++_generation;
    final item = widget.item;
    setState(() {
      _loading = true;
      _document = null;
      _error = null;
      _activeLine = -1;
      _lyricPosition.value = Duration.zero;
      _followState = _LyricsFollowState.following;
      _lineKeys = const [];
    });
    if (item == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final document = await const LyricsService().fetch(
        trackId: item.id,
        title: item.title,
        artist: item.artist ?? '',
        album: item.album ?? '',
        duration: item.duration,
        forceRefresh: forceRefresh,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _document = document;
        _lineKeys = List.generate(document?.lines.length ?? 0, (_) => GlobalKey());
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _chooseLyrics() async {
    final item = widget.item;
    if (item == null) return;
    final picker = _LyricsPicker(
      initialQuery: [
        item.artist,
        item.title,
      ].whereType<String>().map((part) => part.trim()).where((part) => part.isNotEmpty).join(' '),
      targetDuration: item.duration,
    );
    final candidate = Platform.isWindows
        ? await showDialog<LrclibCandidate>(
            context: context,
            builder: (context) => Dialog(
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: 640,
                height: math.min(MediaQuery.sizeOf(context).height * 0.78, 720),
                child: picker,
              ),
            ),
          )
        : await showModalBottomSheet<LrclibCandidate>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            showDragHandle: true,
            builder: (context) => SizedBox(height: MediaQuery.sizeOf(context).height * 0.82, child: picker),
          );
    if (candidate == null || !mounted) return;

    final previous = _document;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final document = await const LyricsService().selectLrclibCandidate(
        trackId: item.id,
        title: item.title,
        artist: item.artist ?? '',
        album: item.album ?? '',
        duration: item.duration,
        candidate: candidate,
      );
      if (!mounted) return;
      if (document == null) throw StateError('The selected lyrics could not be loaded.');
      setState(() {
        _document = document;
        _lineKeys = List.generate(document.lines.length, (_) => GlobalKey());
        _activeLine = -1;
        _followState = _LyricsFollowState.following;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _document = previous;
        _loading = false;
        _error = previous == null ? error : null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not use those lyrics: $error')));
    }
  }

  int _lineAt(LyricsDocument document, Duration position) {
    if (document.timingQuality == LyricTimingQuality.plain) return -1;
    var active = -1;
    for (var index = 0; index < document.lines.length; index++) {
      final start = document.lines[index].start;
      if (start == null || start > position) break;
      active = index;
    }
    return active;
  }

  Duration _interpolatedPosition() {
    if (!_anchorPlaying) return _anchorPosition;
    final elapsed = _interpolationClock.elapsed - _anchorClock;
    return _anchorPosition + Duration(microseconds: (elapsed.inMicroseconds * _anchorSpeed).round());
  }

  void _reanchor({bool? playing, double? speed}) {
    _anchorPosition = _interpolatedPosition();
    _anchorClock = _interpolationClock.elapsed;
    _anchorPlaying = playing ?? _anchorPlaying;
    _anchorSpeed = speed ?? _anchorSpeed;
  }

  void _onPlaybackVisualChanged() => _reanchor(playing: widget.handler.playbackVisualNotifier.value.playing);

  void _onPlaybackSpeedChanged() => _reanchor(speed: widget.handler.speedNotifier.value);

  void _onLyricsTick(Duration _) {
    final clock = _interpolationClock.elapsed;
    final interval = lyricsFrameInterval(LyricsDisplayPreferences.instance.framesPerSecond.value);
    // A small tolerance avoids 30 FPS accidentally falling to 20 FPS on
    // displays whose nominal 16.67 ms frame callbacks arrive just early.
    if (clock - _lastFrameClock < interval - const Duration(milliseconds: 1)) return;
    _lastFrameClock = clock;
    if (!_anchorPlaying && _lyricPosition.value == _anchorPosition) return;
    _publishPosition(_interpolatedPosition());
  }

  void _onPosition(Duration position) {
    final predicted = _interpolatedPosition();
    final drift = position - predicted;
    if (!_anchorPlaying || drift.abs() > const Duration(milliseconds: 220)) {
      _anchorPosition = position;
      _anchorClock = _interpolationClock.elapsed;
      _publishPosition(position);
      return;
    }
    // Backend samples can arrive a few milliseconds late. Snapping to each
    // one creates a visible saw-tooth even though every individual correction
    // is small. Ignore imperceptible drift and ease larger drift into the
    // display clock while it continues moving forward.
    if (drift.abs() > const Duration(milliseconds: 45)) {
      _anchorPosition = predicted + Duration(microseconds: (drift.inMicroseconds * .18).round());
      _anchorClock = _interpolationClock.elapsed;
    }
  }

  void _publishPosition(Duration position) {
    _lyricPosition.value = position;
    final document = _document;
    if (document == null) return;
    final index = _lineAt(document, position);
    if (index == _activeLine) return;
    if (mounted) setState(() => _activeLine = index);
    if (_followState == _LyricsFollowState.following) _scrollToLine(index);
  }

  void _scrollToLine(int index, {bool jumpToUnbuilt = false}) {
    if (index < 0) return;
    _pendingScrollIndex = index;
    _pendingScrollJump = _pendingScrollJump || jumpToUnbuilt;
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_drainPendingLyricsScroll());
    });
  }

  Future<void> _drainPendingLyricsScroll() async {
    try {
      while (mounted && _pendingScrollIndex != null) {
        final index = _pendingScrollIndex!;
        final jumpToUnbuilt = _pendingScrollJump;
        _pendingScrollIndex = null;
        _pendingScrollJump = false;
        await _revealLyricsLine(index, jumpToUnbuilt: jumpToUnbuilt);
      }
    } finally {
      _scrollScheduled = false;
      if (mounted && _pendingScrollIndex != null) _scrollToLine(_pendingScrollIndex!);
    }
  }

  Future<void> _revealLyricsLine(int index, {required bool jumpToUnbuilt}) async {
    if (index < 0 || index >= _lineKeys.length || !_scrollController.hasClients) return;
    for (var attempt = 0; attempt < 4 && mounted; attempt++) {
      final lineContext = _lineKeys[index].currentContext;
      if (lineContext != null) {
        await Scrollable.ensureVisible(
          lineContext,
          duration: const Duration(milliseconds: 480),
          curve: Curves.easeOutCubic,
          alignment: 0.38,
        );
        return;
      }

      // ListView.builder has no render object for distant rows. Move to the
      // target's proportional position first so Flutter materializes it, then
      // use ensureVisible for the exact variable-height alignment.
      final fraction = _lineKeys.length <= 1 ? 0.0 : index / (_lineKeys.length - 1);
      final target = (_scrollController.position.maxScrollExtent * fraction).clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      );
      if (jumpToUnbuilt || attempt > 0) {
        _scrollController.jumpTo(target);
      } else {
        await _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _resumeFollowing() {
    if (_document?.timingQuality == LyricTimingQuality.plain) return;
    setState(() => _followState = _LyricsFollowState.following);
    _scrollToLine(_activeLine, jumpToUnbuilt: true);
  }

  Future<void> _seekLine(LyricLine line) async {
    if (line.start == null) return;
    setState(() => _followState = _LyricsFollowState.following);
    await widget.handler.seek(line.start!);
    _scrollToLine(_activeLine);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const _LyricsMessage(icon: Icons.graphic_eq_rounded, title: 'Finding lyrics…', loading: true);
    }
    final document = _document;
    if (_error != null || document == null) {
      return _LyricsMessage(
        icon: Icons.lyrics_outlined,
        title: 'Lyrics unavailable',
        subtitle: 'No local or online lyrics were found.',
        action: () => _load(forceRefresh: true),
        secondaryAction: _chooseLyrics,
        secondaryActionLabel: 'Choose lyrics',
      );
    }
    if (document.instrumental) {
      return _LyricsMessage(
        icon: Icons.music_note_rounded,
        title: 'Instrumental',
        subtitle: 'This track does not have vocals.',
        secondaryAction: _chooseLyrics,
        secondaryActionLabel: 'Choose lyrics',
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 20, 8),
            child: Row(
              children: [
                Text(
                  'LYRICS',
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w900, letterSpacing: 1.5),
                ),
                const Spacer(),
                Text(
                  document.source,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('lyrics-follow-button'),
                  tooltip: document.timingQuality == LyricTimingQuality.plain
                      ? 'Timed lyrics are required for auto-scroll'
                      : _followState == _LyricsFollowState.following
                      ? 'Following current lyric'
                      : 'Return to current lyric',
                  visualDensity: VisualDensity.compact,
                  onPressed: document.timingQuality == LyricTimingQuality.plain ? null : _resumeFollowing,
                  isSelected: _followState == _LyricsFollowState.following,
                  icon: const Icon(Icons.my_location_outlined, size: 20),
                  selectedIcon: const Icon(Icons.my_location_rounded, size: 20),
                ),
                IconButton(
                  key: const Key('change-lyrics-button'),
                  tooltip: 'Choose different lyrics',
                  visualDensity: VisualDensity.compact,
                  onPressed: _chooseLyrics,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                final manuallyScrolled =
                    (notification is ScrollStartNotification && notification.dragDetails != null) ||
                    (notification is ScrollUpdateNotification && notification.dragDetails != null) ||
                    (notification is OverscrollNotification && notification.dragDetails != null);
                if (manuallyScrolled && _followState != _LyricsFollowState.pausedByUser) {
                  // Cancel any queued reveal from the automatic follower. It
                  // must stay paused until the user explicitly presses Follow.
                  _pendingScrollIndex = null;
                  _pendingScrollJump = false;
                  setState(() => _followState = _LyricsFollowState.pausedByUser);
                }
                return false;
              },
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 120),
                itemCount: document.lines.length,
                itemBuilder: (context, index) {
                  final line = document.lines[index];
                  final isActive = index == _activeLine;
                  final isPast = _activeLine >= 0 && index < _activeLine;
                  return InkWell(
                    key: _lineKeys[index],
                    borderRadius: BorderRadius.circular(18),
                    onTap: line.start == null ? null : () => _seekLine(line),
                    child: AnimatedScale(
                      scale: isActive ? 1.025 : 1,
                      alignment: Alignment.centerLeft,
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutBack,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        margin: EdgeInsets.symmetric(vertical: isActive ? 5 : 2),
                        padding: EdgeInsets.fromLTRB(isActive ? 14 : 8, isActive ? 16 : 10, 10, isActive ? 16 : 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          gradient: isActive
                              ? LinearGradient(
                                  colors: [
                                    theme.colorScheme.primary.withValues(alpha: .22),
                                    theme.colorScheme.secondary.withValues(alpha: .08),
                                    Colors.transparent,
                                  ],
                                )
                              : null,
                          border: isActive ? Border.all(color: theme.colorScheme.primary.withValues(alpha: .34)) : null,
                          boxShadow: isActive
                              ? [
                                  BoxShadow(
                                    color: theme.colorScheme.primary.withValues(alpha: .20),
                                    blurRadius: 24,
                                    spreadRadius: -5,
                                  ),
                                ]
                              : null,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 240),
                              width: isActive ? 4 : 0,
                              height: isActive ? 30 : 0,
                              margin: EdgeInsets.only(right: isActive ? 12 : 0, top: 1),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: BorderRadius.circular(99),
                                boxShadow: isActive
                                    ? [
                                        BoxShadow(
                                          color: theme.colorScheme.primary.withValues(alpha: .75),
                                          blurRadius: 12,
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                            Expanded(
                              child: _LyricLineText(
                                line: line,
                                position: _lyricPosition,
                                active: isActive,
                                past: isPast,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
            child: Text(
              document.timingQuality == LyricTimingQuality.word
                  ? 'Word-synced'
                  : document.timingQuality == LyricTimingQuality.line
                  ? 'Line-synced · word flow estimated'
                  : 'Unsynced lyrics',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricLineText extends StatelessWidget {
  final LyricLine line;
  final ValueListenable<Duration> position;
  final bool active;
  final bool past;

  const _LyricLineText({required this.line, required this.position, required this.active, required this.past});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.headlineSmall?.copyWith(
      height: 1.16,
      fontWeight: active ? FontWeight.w900 : FontWeight.w700,
      fontSize: active ? (theme.textTheme.headlineSmall?.fontSize ?? 24) * 1.08 : null,
      letterSpacing: -0.5,
      color: active ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withValues(alpha: past ? 0.48 : 0.30),
    );
    if (!active || line.words.isEmpty || base == null) {
      return Text(line.text.isEmpty ? '♪' : line.text, style: base);
    }
    return _KaraokeText(
      line: line,
      position: position,
      baseStyle: base.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: .42)),
      activeStyle: base.copyWith(
        color: theme.colorScheme.primary,
        shadows: [Shadow(color: theme.colorScheme.primary.withValues(alpha: .72), blurRadius: 12)],
      ),
    );
  }
}

class _KaraokeText extends StatelessWidget {
  final LyricLine line;
  final ValueListenable<Duration> position;
  final TextStyle baseStyle;
  final TextStyle activeStyle;

  const _KaraokeText({required this.line, required this.position, required this.baseStyle, required this.activeStyle});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final painter = _KaraokePainter(
        line: line,
        position: position,
        baseStyle: baseStyle,
        activeStyle: activeStyle,
        maxWidth: constraints.maxWidth,
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
      );
      return RepaintBoundary(
        child: CustomPaint(size: Size(constraints.maxWidth, painter.height), painter: painter),
      );
    },
  );
}

class _KaraokePainter extends CustomPainter {
  final LyricLine line;
  final ValueListenable<Duration> position;
  final TextStyle baseStyle;
  final TextStyle activeStyle;
  final double maxWidth;
  final TextScaler textScaler;
  final TextDirection textDirection;
  late final String text = line.words.map((word) => word.text).join();
  late final TextPainter _base = _layout(baseStyle);
  late final TextPainter _active = _layout(activeStyle);

  _KaraokePainter({
    required this.line,
    required this.position,
    required this.baseStyle,
    required this.activeStyle,
    required this.maxWidth,
    required this.textScaler,
    required this.textDirection,
  }) : super(repaint: position);

  TextPainter _layout(TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textScaler: textScaler,
    textDirection: textDirection,
  )..layout(maxWidth: maxWidth);

  double get height => _base.height;

  @override
  void paint(Canvas canvas, Size size) {
    _base.paint(canvas, Offset.zero);
    final path = Path();
    var offset = 0;
    final currentPosition = position.value;
    for (final word in line.words) {
      final end = offset + word.text.length;
      final span = word.end - word.start;
      final fraction = currentPosition <= word.start
          ? 0.0
          : currentPosition >= word.end || span <= Duration.zero
          ? 1.0
          : (currentPosition - word.start).inMicroseconds / span.inMicroseconds;
      if (fraction > 0) {
        for (final box in _active.getBoxesForSelection(TextSelection(baseOffset: offset, extentOffset: end))) {
          final filledRight = box.left + box.toRect().width * fraction;
          path.addRect(Rect.fromLTRB(box.left, box.top, filledRight, box.bottom));
        }
      }
      offset = end;
    }
    canvas.save();
    canvas.clipPath(path);
    _active.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _KaraokePainter oldDelegate) =>
      oldDelegate.line != line ||
      oldDelegate.maxWidth != maxWidth ||
      oldDelegate.baseStyle != baseStyle ||
      oldDelegate.activeStyle != activeStyle;
}

class _LyricsMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool loading;
  final VoidCallback? action;
  final VoidCallback? secondaryAction;
  final String? secondaryActionLabel;

  const _LyricsMessage({
    required this.icon,
    required this.title,
    this.subtitle,
    this.loading = false,
    this.action,
    this.secondaryAction,
    this.secondaryActionLabel,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox.square(dimension: 42, child: CircularProgressIndicator())
          else
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (action != null || secondaryAction != null) ...[
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (action != null)
                  TextButton.icon(
                    onPressed: action,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                  ),
                if (secondaryAction != null)
                  FilledButton.tonalIcon(
                    key: const Key('choose-lyrics-button'),
                    onPressed: secondaryAction,
                    icon: const Icon(Icons.search_rounded),
                    label: Text(secondaryActionLabel ?? 'Choose lyrics'),
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

class _LyricsPicker extends StatefulWidget {
  final String initialQuery;
  final Duration? targetDuration;

  const _LyricsPicker({required this.initialQuery, required this.targetDuration});

  @override
  State<_LyricsPicker> createState() => _LyricsPickerState();
}

class _LyricsPickerState extends State<_LyricsPicker> {
  late final TextEditingController _queryController;
  List<LrclibCandidate> _results = const [];
  bool _loading = true;
  bool _searched = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    _search();
  }

  @override
  void dispose() {
    _generation++;
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _searched = true;
    });
    final results = await const LyricsService().searchLrclibCandidates(query);
    if (!mounted || generation != _generation) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  String _duration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String? _difference(LrclibCandidate candidate) {
    final target = widget.targetDuration;
    if (target == null || target.inSeconds <= 0 || candidate.duration.inSeconds <= 0) return null;
    final difference = candidate.duration.inSeconds - target.inSeconds;
    if (difference == 0) return 'exact duration';
    return '${difference > 0 ? '+' : ''}${difference}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
            child: Row(
              children: [
                Expanded(child: Text('Choose lyrics', style: theme.textTheme.titleLarge)),
                IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              key: const Key('lyrics-search-field'),
              controller: _queryController,
              autofocus: Platform.isWindows,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Artist and song title',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(tooltip: 'Search', onPressed: _search, icon: const Icon(Icons.arrow_forward)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
            child: Text(
              'Automatic matching only accepts results within 3 seconds. You can deliberately choose any version here.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _searched ? 'No LRCLIB results for this search.' : 'Search LRCLIB to choose a result.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final candidate = _results[index];
                      final difference = _difference(candidate);
                      final details = [
                        candidate.artistName,
                        if (candidate.albumName.isNotEmpty) candidate.albumName,
                      ].where((part) => part.isNotEmpty).join(' · ');
                      return ListTile(
                        key: ValueKey('lrclib-candidate-${candidate.id}'),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        title: Text(candidate.trackName, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                        trailing: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 116),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(_duration(candidate.duration), style: theme.textTheme.labelLarge),
                              Text(
                                candidate.instrumental
                                    ? 'Instrumental'
                                    : candidate.hasSyncedLyrics
                                    ? 'Synced'
                                    : 'Plain',
                                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                              ),
                              if (difference != null)
                                Text(
                                  difference,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: difference == 'exact duration'
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        onTap: () => Navigator.pop(context, candidate),
                      );
                    },
                  ),
          ),
        ],
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
                return Transform.translate(
                  key: standaloneVinylCompositionTransformKey,
                  offset: Offset(-standaloneVinylCompositionShift(coverSize, clampedProgress), 0),
                  child: Stack(
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
                  ),
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
