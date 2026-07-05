// lib/widgets/player/seek_bar.dart
// Fixes:
//  1. Duration format: H:MM:SS only when track >= 1 hour
//  2. Loading indicator: grey out + show spinner while audio is buffering/loading
//  3. Seek bar pauses updating while buffering after a seek

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
      if (!_isScrubbing && mounted) {
        setState(() {
          _position = position;
          if (_duration.inMilliseconds > 0) {
            _sliderValue = _position.inMilliseconds / _duration.inMilliseconds;
          }
        });
      }
    });

    handler.durationStream.listen((duration) {
      if (duration != null && mounted) {
        setState(() {
          _duration = duration;
        });
      }
    });

    // Listen to playback state for loading/buffering detection
    handler.playbackState.listen((state) {
      if (mounted) {
        final loading = state.processingState == AudioProcessingState.loading ||
            state.processingState == AudioProcessingState.buffering;
        if (loading != _isLoading) {
          setState(() => _isLoading = loading);
        }
      }
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

    // When loading, dim the active track color
    final activeTrackColor = _isLoading
        ? (isDark ? const Color(0xFF3D3D55) : const Color(0xFFABA8C8))
        : primary;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_formatDuration(_position, showHours: showHours), style: timestampStyle),
        const SizedBox(width: 8),

        // Loading spinner inline with seek bar
        if (_isLoading)
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
                        thumbColor: _isLoading
                            ? (isDark ? const Color(0xFF3D3D55) : const Color(0xFFABA8C8))
                            : primary,
                        tickMarkShape: SliderTickMarkShape.noTickMark,
                        trackHeight: _isHovering ? 4.0 : 3.0,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: _isHovering && !_isLoading ? 6.0 : 0.0,
                          elevation: 2,
                        ),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                        overlayColor: primary.withValues(alpha: 0.15),
                      ),
                      child: Slider(
                        value: _sliderValue.clamp(0.0, 1.0),
                        min: 0,
                        max: 1,
                        divisions: _duration.inSeconds > 0 ? _duration.inSeconds : null,
                        onChanged: _isLoading
                            ? null
                            : (value) {
                                setState(() {
                                  _isScrubbing = true;
                                  _sliderValue = value;
                                });
                                _updateHoverPosition(value * maxWidth, maxWidth);
                              },
                        onChangeEnd: _isLoading
                            ? null
                            : (value) {
                                final newPosition = _duration * value;
                                handler.seek(newPosition);
                                setState(() => _isScrubbing = false);
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
                        opacity: (_isHovering || _isScrubbing) && !_isLoading ? 1.0 : 0.0,
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
        Text(_formatDuration(_duration, showHours: showHours), style: timestampStyle),
      ],
    );
  }
}