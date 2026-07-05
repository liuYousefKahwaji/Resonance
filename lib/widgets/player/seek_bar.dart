// lib/widgets/player/seek_bar.dart
//
// Fixes:
//  1. Duration format: H:MM:SS only when track >= 1 hour.
//  2. Loading indicator: grey out + spinner while audio is buffering/loading.
//  3. Pending seek position: after the user releases the thumb the bar
//     shows the chosen position immediately instead of snapping back to
//     the pre-seek position while the player is still buffering.
//     _pendingSeekPosition is held until the player's reported position
//     "catches up" (within 2 s of the target), then cleared so normal
//     tracking resumes. This makes stream-seeks feel responsive even
//     though re-buffering takes a few seconds.

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';

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
  bool _isLoading = false;

  // After a seek, hold the target position until the player catches up.
  // This prevents the thumb from snapping back during stream re-buffering.
  Duration? _pendingSeekPosition;

  double _hoverX = 0.0;
  Duration _hoverDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _listenToPlayer();
  }

  void _listenToPlayer() {
    final handler = Provider.of<PlayerHandler>(context, listen: false);

    handler.positionStream.listen((position) {
      if (!mounted) return;
      if (_isScrubbing) return;

      // If we have a pending seek, check whether the player has caught up.
      // "Caught up" = reported position is within 2 s of the target.
      if (_pendingSeekPosition != null) {
        final diff = (position - _pendingSeekPosition!).abs();
        if (diff > const Duration(seconds: 2)) {
          // Player hasn't arrived yet — keep showing the pending position.
          return;
        }
        // Player has caught up — resume normal tracking.
        _pendingSeekPosition = null;
      }

      setState(() {
        _position = position;
        if (_duration.inMilliseconds > 0) {
          _sliderValue = _position.inMilliseconds / _duration.inMilliseconds;
        }
      });
    });

    handler.durationStream.listen((duration) {
      if (duration != null && mounted) {
        setState(() => _duration = duration);
      }
    });

    handler.playbackState.listen((state) {
      if (!mounted) return;
      final loading = state.processingState == AudioProcessingState.loading ||
          state.processingState == AudioProcessingState.buffering;

      // When a new track starts loading, clear any stale pending seek
      // from the previous track.
      final isIdle = state.processingState == AudioProcessingState.idle;

      setState(() {
        _isLoading = loading;
        if (isIdle) {
          _pendingSeekPosition = null;
          _position = Duration.zero;
          _sliderValue = 0.0;
        }
      });
    });
  }

  void _updateHoverPosition(double localX, double maxWidth) {
    if (maxWidth <= 0 || _duration.inMilliseconds <= 0) return;
    final ratio = (localX / maxWidth).clamp(0.0, 1.0);
    setState(() {
      _hoverX = localX;
      _hoverDuration = _duration * ratio;
    });
  }

  /// Format duration — H:MM:SS only when track is >= 1 hour.
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

  // The position we actually display: pending seek target (if any),
  // otherwise the live player position.
  Duration get _displayPosition => _pendingSeekPosition ?? _position;

  double get _displaySliderValue {
    if (_pendingSeekPosition != null && _duration.inMilliseconds > 0) {
      return (_pendingSeekPosition!.inMilliseconds / _duration.inMilliseconds)
          .clamp(0.0, 1.0);
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

    // Dim the track while loading OR while waiting for a seek to settle.
    final isWaiting = _isLoading || _pendingSeekPosition != null;
    final activeTrackColor = isWaiting
        ? (isDark ? const Color(0xFF3D3D55) : const Color(0xFFABA8C8))
        : primary;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_formatDuration(_displayPosition, showHours: showHours),
            style: timestampStyle),
        const SizedBox(width: 8),

        // Spinner shown while loading OR re-buffering after a seek
        if (isWaiting)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: isDark
                    ? const Color(0xFF64748B)
                    : const Color(0xFF94A3B8),
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
                onHover: (event) =>
                    _updateHoverPosition(event.localPosition.dx, maxWidth),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        showValueIndicator: ShowValueIndicator.never,
                        activeTrackColor: activeTrackColor,
                        inactiveTrackColor: isDark
                            ? const Color(0xFF2D2D42)
                            : const Color(0xFFDDD9F3),
                        thumbColor: isWaiting
                            ? (isDark
                                ? const Color(0xFF3D3D55)
                                : const Color(0xFFABA8C8))
                            : primary,
                        tickMarkShape: SliderTickMarkShape.noTickMark,
                        trackHeight: _isHovering ? 4.0 : 3.0,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius:
                              _isHovering && !isWaiting ? 6.0 : 0.0,
                          elevation: 2,
                        ),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12.0),
                        overlayColor: primary.withValues(alpha: 0.15),
                      ),
                      child: Slider(
                        value: _isScrubbing
                            ? _sliderValue.clamp(0.0, 1.0)
                            : _displaySliderValue,
                        min: 0,
                        max: 1,
                        divisions: _duration.inSeconds > 0
                            ? _duration.inSeconds
                            : null,
                        // Disable interaction while initially loading a new
                        // track, but ALLOW it during post-seek buffering so
                        // users can re-seek without waiting for re-buffering
                        // to complete first.
                        onChanged: _isLoading && _pendingSeekPosition == null
                            ? null
                            : (value) {
                                setState(() {
                                  _isScrubbing = true;
                                  _sliderValue = value;
                                });
                                _updateHoverPosition(
                                    value * maxWidth, maxWidth);
                              },
                        onChangeEnd:
                            _isLoading && _pendingSeekPosition == null
                                ? null
                                : (value) {
                                    final newPosition = _duration * value;
                                    // Record as pending immediately so the
                                    // thumb doesn't snap back.
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
                      duration: Duration(
                          milliseconds: _isScrubbing ? 0 : 50),
                      curve: Curves.easeOutCubic,
                      left: (_hoverX - 28).clamp(0.0, maxWidth - 56),
                      top: -34,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity:
                            (_isHovering || _isScrubbing) && !_isLoading
                                ? 1.0
                                : 0.0,
                        child: IgnorePointer(
                          child: Container(
                            width: 56,
                            padding:
                                const EdgeInsets.symmetric(vertical: 4),
                            decoration: BoxDecoration(
                              color: previewBgColor,
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                _formatDuration(_hoverDuration,
                                    showHours: showHours),
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
        Text(_formatDuration(_duration, showHours: showHours),
            style: timestampStyle),
      ],
    );
  }
}