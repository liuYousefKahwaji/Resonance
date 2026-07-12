// lib/widgets/player/seek_bar.dart
//
// Fixes:
//  1. Duration format: H:MM:SS only when track >= 1 hour.
//  2. Loading indicator: only shown while audio is genuinely loading a new
//     track (AudioProcessingState.loading). Buffering state (which fires
//     during seeks on streamed tracks) shows a dimmed seek bar but NOT
//     the spinner, so local-file seeks feel instant.
//  3. Pending seek position: after the user releases the thumb the bar
//     shows the chosen position immediately instead of snapping back.
//     _pendingSeekPosition is cleared as soon as the player's reported
//     position catches up (within 1 s for local files, 3 s for streams).

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SeekBar extends StatefulWidget {
  const SeekBar({super.key});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double _sliderValue = 0.0;
  bool _isScrubbing = false;
  bool _isHovering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Only true while a brand-new track is loading (not during seeks).
  bool _isLoadingNewTrack = false;

  // True while the player is buffering (stream re-buffers after seek, etc.)
  // Does NOT block interaction — the seek bar stays interactive.
  bool _isBuffering = false;

  // Whether the current track is a stream URL.
  bool _currentTrackIsStream = false;

  // After a seek, hold the target position until the player catches up.
  Duration? _pendingSeekPosition;
  int _seekStepSeconds = 5;

  double _hoverX = 0.0;
  Duration _hoverDuration = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlaybackState>? _playbackSub;

  @override
  void initState() {
    super.initState();
    _loadSeekStep();
    _listenToPlayer();
  }

  Future<void> _loadSeekStep() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _seekStepSeconds = (prefs.getInt('seek_step_seconds') ?? 5).clamp(1, 15));
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    handler.seekStepNotifier.value = _seekStepSeconds;
    handler.seekStepNotifier.addListener(_onSeekStepChanged);
  }

  void _onSeekStepChanged() {
    if (mounted) {
      setState(() => _seekStepSeconds = Provider.of<PlayerHandler>(context, listen: false).seekStepNotifier.value);
    }
  }

  void _listenToPlayer() {
    final handler = Provider.of<PlayerHandler>(context, listen: false);

    _positionSub = handler.positionStream.listen((position) {
      if (!mounted || _isScrubbing) return;

      if (_pendingSeekPosition != null) {
        // Catchup window: 1 s for local files, 3 s for streams.
        final window = _currentTrackIsStream ? const Duration(seconds: 3) : const Duration(seconds: 1);
        final diff = (position - _pendingSeekPosition!).abs();
        if (diff > window) {
          // Not caught up yet — keep showing pending position.
          return;
        }
        _pendingSeekPosition = null;
      }

      setState(() {
        _position = position;
        if (_duration.inMilliseconds > 0) {
          _sliderValue = _position.inMilliseconds / _duration.inMilliseconds;
        }
      });
    });

    _durationSub = handler.durationStream.listen((duration) {
      if (duration != null && mounted) {
        setState(() => _duration = duration);
      }
    });

    _playbackSub = handler.playbackState.listen((state) {
      if (!mounted) return;

      // Determine if the current item is a stream.
      final handler2 = Provider.of<PlayerHandler>(context, listen: false);
      final currentId = handler2.mediaItem.value?.id ?? '';
      _currentTrackIsStream = currentId.startsWith('http://') || currentId.startsWith('https://');

      final isLoading = state.processingState == AudioProcessingState.loading;
      final isBuffering = state.processingState == AudioProcessingState.buffering;
      final isIdle = state.processingState == AudioProcessingState.idle;

      setState(() {
        _isLoadingNewTrack = isLoading;
        // Only show buffering indicator for streamed tracks.
        _isBuffering = isBuffering && _currentTrackIsStream;

        if (isIdle) {
          _pendingSeekPosition = null;
          _position = Duration.zero;
          _sliderValue = 0.0;
        }
        // When a new track starts loading, clear stale pending seek.
        if (isLoading) {
          _pendingSeekPosition = null;
        }
      });
    });
  }

  @override
  void dispose() {
    Provider.of<PlayerHandler>(context, listen: false).seekStepNotifier.removeListener(_onSeekStepChanged);
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playbackSub?.cancel();
    super.dispose();
  }

  void _updateHoverPosition(double localX, double maxWidth) {
    if (maxWidth <= 0 || _duration.inMilliseconds <= 0) return;
    final ratio = (localX / maxWidth).clamp(0.0, 1.0);
    setState(() {
      _hoverX = localX;
      _hoverDuration = _duration * ratio;
    });
  }

  String _formatDuration(Duration duration, {required bool showHours}) {
    if (showHours) {
      final h = duration.inHours;
      final m = duration.inMinutes.remainder(60);
      final s = duration.inSeconds.remainder(60);
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    } else {
      final m = duration.inMinutes.remainder(60);
      final s = duration.inSeconds.remainder(60);
      return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
  }

  Duration get _displayPosition => _pendingSeekPosition ?? _position;

  double get _displaySliderValue {
    if (_pendingSeekPosition != null && _duration.inMilliseconds > 0) {
      return (_pendingSeekPosition!.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    }
    return _sliderValue.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    final showHours = _duration.inHours >= 1;

    final previewBgColor = isDark ? const Color(0xFF242436) : primary;
    final previewTextColor = isDark ? primary : Colors.white;

    final timestampStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
      color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
    );

    // Dim the track while loading a new track OR while a stream is buffering
    // after a seek. Local-file seeks never dim the bar.
    final isDimmed = _isLoadingNewTrack || _isBuffering;
    final activeTrackColor = isDimmed ? (isDark ? const Color(0xFF3D3D55) : const Color(0xFFABA8C8)) : primary;

    // Slider is disabled only while a NEW track is loading (not during seeks).
    final sliderDisabled = _isLoadingNewTrack;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_formatDuration(_displayPosition, showHours: showHours), style: timestampStyle),
        const SizedBox(width: 8),
        _SeekStepButton(
          label: '-$_seekStepSeconds',
          icon: Icons.replay_rounded,
          onPressed: sliderDisabled ? null : () => handler.seekBySeconds(-_seekStepSeconds),
        ),
        const SizedBox(width: 6),

        // Spinner: only shown while a genuinely new track is loading.
        if (_isLoadingNewTrack)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
              ),
            ),
          ),

        Flexible(
          flex: 2,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth;

              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _isHovering = true),
                onExit: (_) => setState(() => _isHovering = false),
                onHover: (event) => _updateHoverPosition(event.localPosition.dx, maxWidth),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        showValueIndicator: ShowValueIndicator.never,
                        activeTrackColor: activeTrackColor,
                        inactiveTrackColor: Theme.of(context).colorScheme.outline,
                        thumbColor: isDimmed ? (isDark ? const Color(0xFF3D3D55) : const Color(0xFFABA8C8)) : primary,
                        tickMarkShape: SliderTickMarkShape.noTickMark,
                        trackHeight: _isHovering ? 4.0 : 3.0,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: (_isHovering && !sliderDisabled) ? 6.0 : 0.0,
                          elevation: 2,
                        ),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                        overlayColor: primary.withValues(alpha: 0.15),
                      ),
                      child: Slider(
                        value: _isScrubbing ? _sliderValue.clamp(0.0, 1.0) : _displaySliderValue,
                        min: 0,
                        max: 1,
                        divisions: null,
                        onChanged: sliderDisabled
                            ? null
                            : (value) {
                                setState(() {
                                  _isScrubbing = true;
                                  _sliderValue = value;
                                });
                                _updateHoverPosition(value * maxWidth, maxWidth);
                              },
                        onChangeEnd: sliderDisabled
                            ? null
                            : (value) {
                                final newPosition = _duration * value;
                                setState(() {
                                  _pendingSeekPosition = newPosition;
                                  _isScrubbing = false;
                                });
                                handler.seek(newPosition);
                              },
                      ),
                    ),

                    // Floating timestamp preview
                    AnimatedPositioned(
                      duration: Duration(milliseconds: _isScrubbing ? 0 : 50),
                      curve: Curves.easeOutCubic,
                      left: (_hoverX - 28).clamp(0.0, maxWidth - 56),
                      top: -34,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity: (_isHovering || _isScrubbing) && !_isLoadingNewTrack ? 1.0 : 0.0,
                        child: IgnorePointer(
                          child: Container(
                            width: 56,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            decoration: BoxDecoration(
                              color: previewBgColor,
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                _formatDuration(_hoverDuration, showHours: showHours),
                                style: TextStyle(
                                  color: previewTextColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        _SeekStepButton(
          label: '+$_seekStepSeconds',
          icon: Icons.redo_rounded,
          onPressed: sliderDisabled ? null : () => handler.seekBySeconds(_seekStepSeconds),
        ),
        const SizedBox(width: 6),
        Text(_formatDuration(_duration, showHours: showHours), style: timestampStyle),
      ],
    );
  }
}

class _SeekStepButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const _SeekStepButton({required this.label, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: '$label seconds',
      child: SizedBox(
        width: 36,
        height: 30,
        child: IconButton(
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          icon: Icon(icon, size: 23, color: onPressed == null ? const Color(0xFF64748B) : primary),
        ),
      ),
    );
  }
}
