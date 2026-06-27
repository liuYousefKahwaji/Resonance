// lib/widgets/player/volume_bar.dart
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
      _hoverPercentage = (localX / maxWidth).clamp(0.0, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    final previewBgColor = isDark ? const Color(0xFF242436) : primary;
    final previewTextColor = isDark ? primary : Colors.white;

    return ValueListenableBuilder<double>(
      valueListenable: handler.volumeNotifier,
      builder: (context, currentVolume, child) {
        final IconData icon;
        if (currentVolume == 0) {
          icon = Icons.volume_off_rounded;
        } else if (currentVolume < 0.33) {
          icon = Icons.volume_down_rounded;
        } else {
          icon = Icons.volume_up_rounded;
        }

        return Row(
          children: [
            IconButton(
              icon: Icon(
                icon,
                size: 18,
                color: isDark
                    ? const Color(0xFF64748B)
                    : const Color(0xFF94A3B8),
              ),
              tooltip: currentVolume == 0 ? 'Unmute' : 'Mute',
              onPressed: handler.toggleMute,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxWidth = constraints.maxWidth;
                  if (maxWidth <= 0) return const SizedBox.shrink();

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
                            activeTrackColor: primary,
                            inactiveTrackColor: isDark
                                ? const Color(0xFF2D2D42)
                                : const Color(0xFFDDD9F3),
                            thumbColor: primary,
                            tickMarkShape: SliderTickMarkShape.noTickMark,
                            trackHeight: _isHovering ? 4.0 : 3.0,
                            thumbShape: RoundSliderThumbShape(
                              enabledThumbRadius: _isHovering ? 6.0 : 0.0,
                              elevation: 2,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12.0),
                            overlayColor: primary.withValues(alpha: 0.15),
                          ),
                          child: Slider(
                            value: currentVolume.clamp(0.0, 1.0),
                            min: 0,
                            max: 1,
                            divisions: 100,
                            onChanged: (value) {
                              setState(() => _isScrubbing = true);
                              handler.changeVolume(value.clamp(0.0, 1.0));
                              _updateHoverPosition(
                                  value * maxWidth, maxWidth);
                            },
                            onChangeEnd: (_) =>
                                setState(() => _isScrubbing = false),
                          ),
                        ),

                        // ── Floating percentage preview ──
                        // SAFE CLAMP: ensure maxLeft >= 0
                        AnimatedPositioned(
                          duration: Duration(
                              milliseconds: _isScrubbing ? 0 : 50),
                          curve: Curves.easeOutCubic,
                          left: _isHovering || _isScrubbing
                              ? (_hoverX - 25).clamp(
                                  0.0,
                                  (maxWidth - 50).clamp(0.0, double.infinity),
                                )
                              : 0,
                          top: -34,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 150),
                            opacity:
                                (_isHovering || _isScrubbing) ? 1.0 : 0.0,
                            child: IgnorePointer(
                              child: Container(
                                width: 50,
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
                                    '${(_hoverPercentage * 100).toInt()}%',
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
          ],
        );
      },
    );
  }
}