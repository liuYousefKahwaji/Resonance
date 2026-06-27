// widgets/player/seek_bar.dart
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
  }

  void _updateHoverPosition(double localX, double maxWidth) {
    if (maxWidth <= 0 || _duration.inMilliseconds <= 0) return;
    
    final ratio = (localX / maxWidth).clamp(0.0, 1.0);
    setState(() {
      _hoverX = localX;
      _hoverDuration = _duration * ratio;
    });
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    final theme = Theme.of(context);
    
    // Determine context brightness
    final isDarkMode = theme.brightness == Brightness.dark;

    // Tailored Color Design for your palette
    final Color previewBgColor = isDarkMode 
        ? Colors.grey[850]!          // Subtle deep dark gray card for Dark Mode
        : theme.colorScheme.primary; // Rich Purple card for Light Mode

    final Color previewTextColor = isDarkMode 
        ? theme.colorScheme.primary  // Vibrant Purple text sitting on Gray card
        : Colors.white;              // Crisp White text sitting on Purple card

    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_formatDuration(_position), style: labelStyle),
        const SizedBox(width: 8),
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
                    // Native Slider Theme UI
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        showValueIndicator: ShowValueIndicator.never,
                        activeTrackColor: theme.colorScheme.primary,
                        inactiveTrackColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                        thumbColor: theme.colorScheme.primary,
                        tickMarkShape: SliderTickMarkShape.noTickMark,
                        trackHeight: _isHovering ? 5.0 : 3.0,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: _isHovering ? 7.0 : 0.0,
                          elevation: 2,
                        ),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                      ),
                      child: Slider(
                        value: _sliderValue.clamp(0.0, 1.0),
                        min: 0,
                        max: 1,
                        divisions: _duration.inSeconds > 0 ? _duration.inSeconds : null,
                        onChanged: (value) {
                          setState(() {
                            _isScrubbing = true;
                            _sliderValue = value;
                          });
                          _updateHoverPosition(value * maxWidth, maxWidth);
                        },
                        onChangeEnd: (value) {
                          final newPosition = _duration * value;
                          handler.seek(newPosition);
                          setState(() {
                            _isScrubbing = false;
                          });
                        },
                      ),
                    ),

                    // Modern Floating Preview Timestamp Card
                    AnimatedPositioned(
                      duration: Duration(milliseconds: _isScrubbing ? 0 : 50),
                      curve: Curves.easeOutCubic,
                      left: (_hoverX - 28).clamp(0.0, maxWidth - 56), 
                      top: -34, 
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity: (_isHovering || _isScrubbing) ? 1.0 : 0.0,
                        child: IgnorePointer(
                          child: Container(
                            width: 56,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            decoration: BoxDecoration(
                              color: previewBgColor,
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.15),
                                  blurRadius: 6,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                _formatDuration(_hoverDuration),
                                style: TextStyle(
                                  color: previewTextColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
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
        Text(_formatDuration(_duration), style: labelStyle),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}