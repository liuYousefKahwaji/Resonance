// lib/widgets/player/volume_bar.dart
// Volume Booster: slider now goes 0–200%.
// Values above 100% show a "BOOST" badge to make it clear to the user.
// just_audio receives min(rawVolume, 1.0); the extra slider range is a
// visual affordance so users don't leave volume at 50% thinking it's full.

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
      // Hover percentage maps to 0–200%
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
      builder: (context, rawVolume, child) {
        // rawVolume is in [0.0, 2.0]
        final sliderFraction = rawVolume / 2.0; // maps to [0,1] for Slider
        final isBoost = rawVolume > 1.005; // show boost badge above ~100%

        final IconData icon;
        if (rawVolume == 0) {
          icon = Icons.volume_off_rounded;
        } else if (rawVolume < 0.33) {
          icon = Icons.volume_down_rounded;
        } else {
          icon = Icons.volume_up_rounded;
        }

        // Track color: active theme accent up to 100%, amber/orange in boost range
        final boostColor = isDark
            ? const Color(0xFFD97706) // amber-600
            : const Color(0xFFB45309);
        final activeTrackColor = isBoost ? boostColor : primary;

        return Row(
          children: [
            IconButton(
              icon: Icon(
                icon,
                size: 18,
                color: isBoost
                    ? boostColor
                    : isDark
                    ? const Color(0xFF64748B)
                    : const Color(0xFF94A3B8),
              ),
              tooltip: rawVolume == 0 ? 'Unmute' : 'Mute',
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
                    onHover: (event) => _updateHoverPosition(event.localPosition.dx, maxWidth),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            showValueIndicator: ShowValueIndicator.never,
                            activeTrackColor: activeTrackColor,
                            inactiveTrackColor: Theme.of(context).colorScheme.outline,
                            thumbColor: activeTrackColor,
                            tickMarkShape: SliderTickMarkShape.noTickMark,
                            trackHeight: _isHovering ? 4.0 : 3.0,
                            thumbShape: RoundSliderThumbShape(
                              enabledThumbRadius: _isHovering ? 6.0 : 0.0,
                              elevation: 2,
                            ),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                            overlayColor: activeTrackColor.withValues(alpha: 0.15),
                          ),
                          child: Slider(
                            value: sliderFraction.clamp(0.0, 1.0),
                            min: 0,
                            max: 1,
                            divisions: 40, // each step = 5% of 200% = 10%
                            onChanged: (value) {
                              setState(() => _isScrubbing = true);
                              // value [0,1] → raw [0,2]
                              handler.changeVolume((value * 2.0).clamp(0.0, 2.0));
                              _updateHoverPosition(value * maxWidth, maxWidth);
                            },
                            onChangeEnd: (_) => setState(() => _isScrubbing = false),
                          ),
                        ),

                        // ── BOOST badge ─────────────────────────────
                        if (isBoost)
                          Positioned(
                            right: 0,
                            top: -18,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: boostColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: boostColor.withValues(alpha: 0.4), width: 1),
                              ),
                              child: Text(
                                'BOOST',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                  color: boostColor,
                                ),
                              ),
                            ),
                          ),

                        // ── Floating percentage preview ────────────
                        AnimatedPositioned(
                          duration: Duration(milliseconds: _isScrubbing ? 0 : 50),
                          curve: Curves.easeOutCubic,
                          left: _isHovering || _isScrubbing
                              ? (_hoverX - 28).clamp(0.0, (maxWidth - 56).clamp(0.0, double.infinity))
                              : 0,
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
                                      color: Colors.black.withValues(alpha: 0.2),
                                      blurRadius: 8,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Text(
                                    // Display 0–200%
                                    '${(_hoverPercentage * 200).toInt()}%',
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
