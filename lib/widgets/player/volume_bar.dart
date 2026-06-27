// widgets/player/volume_bar.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';

class VolumeBar extends StatefulWidget {
  const VolumeBar({super.key});

  @override
  State<VolumeBar> createState() => _VolumeBarState();
}

class _VolumeBarState extends State<VolumeBar> {
  bool _isHovering = false;
  bool _isScrubbing = false;
  double _hoverX = 0.0;
  double _hoverPercentage = 0.0;

  void _updateHoverPosition(double localX, double maxWidth) {
    if (maxWidth <= 0) return;
    setState(() {
      _hoverX = localX;
      // Converts pixel location into a 0.0 -> 1.0 ratio
      _hoverPercentage = (localX / maxWidth).clamp(0.0, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    final theme = Theme.of(context);
    final isDarkMode = theme.brightness == Brightness.dark;

    // Matching color styles from your palette
    final Color previewBgColor = isDarkMode 
        ? Colors.grey[850]!          
        : theme.colorScheme.primary; 

    final Color previewTextColor = isDarkMode 
        ? theme.colorScheme.primary  
        : Colors.white;

    return ValueListenableBuilder<double>(
      valueListenable: handler.volumeNotifier,
      builder: (context, currentVolume, child) {
        // Dynamic volume icon mapping
        IconData icon;
        if (currentVolume == 0) {
          icon = Icons.volume_off;
        } else if (currentVolume < 0.33) {
          icon = Icons.volume_down;
        } else if (currentVolume < 0.66) {
          icon = Icons.volume_up; // Material 3 defaults to volume_up/down or custom mid icons if preferred
        } else {
          icon = Icons.volume_up;
        }

        return Row(
          children: [
            IconButton(
              icon: Icon(icon),
              tooltip: currentVolume == 0 ? "Unmute" : "Mute",
              onPressed: handler.toggleMute,
            ),
            
            Expanded(
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
                        // Interactive Slider Styling
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
                            value: currentVolume.clamp(0.0, 1.0),
                            min: 0,
                            max: 1,
                            divisions: 100,
                            onChanged: (value) {
                              setState(() {
                                _isScrubbing = true;
                              });
                              handler.changeVolume(value.clamp(0.0, 1.0));
                              _updateHoverPosition(value * maxWidth, maxWidth);
                            },
                            onChangeEnd: (_) {
                              setState(() {
                                _isScrubbing = false;
                              });
                            },
                          ),
                        ),

                        // Floating Percentage Card (Matches SeekBar design exactly)
                        AnimatedPositioned(
                          duration: Duration(milliseconds: _isScrubbing ? 0 : 50),
                          curve: Curves.easeOutCubic,
                          left: (_hoverX - 25).clamp(0.0, maxWidth - 50), 
                          top: -34, 
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 150),
                            opacity: (_isHovering || _isScrubbing) ? 1.0 : 0.0,
                            child: IgnorePointer(
                              child: Container(
                                width: 50,
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
                                    "${(_hoverPercentage * 100).toInt()}%",
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
          ],
        );
      },
    );
  }
}