// lib/widgets/player/player_controls.dart
//
// Redesigned player controls panel — frosted dark/light surface with
// rounded top corners, elevated above the track list.
// Logic: UNCHANGED. Only visual presentation changed.

import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/widgets/player/playback_settings.dart';
import 'package:resonance/widgets/player/player_modes.dart';
import 'package:resonance/widgets/player/seek_bar.dart';
import 'package:resonance/widgets/player/speed_control.dart';
import 'package:resonance/widgets/player/volume_bar.dart';

class PlayerControls extends StatelessWidget {
  const PlayerControls({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = Platform.isAndroid;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Panel surface colors
    final panelColor = isDark ? const Color(0xFF15151F) : Colors.white;
    final panelBorder = isDark ? const Color(0xFF2D2D42) : const Color(0xFFDDD9F3);

    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      initialData: handler.playbackState.value,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data?.playing ?? false;

        return Container(
          decoration: BoxDecoration(
            color: panelColor,
            border: Border(top: BorderSide(color: panelBorder, width: 1)),
          ),
          child: screenWidth < 500
              ? _MobileControls(handler: handler, isPlaying: isPlaying, isMobile: isMobile)
              : _DesktopControls(handler: handler, isPlaying: isPlaying, isMobile: isMobile, screenWidth: screenWidth),
        );
      },
    );
  }
}

class _MobileControls extends StatelessWidget {
  final PlayerHandler handler;
  final bool isPlaying;
  final bool isMobile;

  const _MobileControls({
    required this.handler,
    required this.isPlaying,
    required this.isMobile,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Row 1: Seek bar ──────────────────────────────────────
            const SeekBar(),

            const SizedBox(height: 6),

            // ── Row 2: Transport controls (centred) ──────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SkipButton(
                  icon: Icons.skip_previous_rounded,
                  onTap: handler.previous,
                  size: 26,
                ),
                const SizedBox(width: 16),
                _PlayPauseButton(
                  isPlaying: isPlaying,
                  onTap: handler.playPause,
                  size: 48,
                ),
                const SizedBox(width: 16),
                _SkipButton(
                  icon: Icons.skip_next_rounded,
                  onTap: handler.next,
                  size: 26,
                ),
              ],
            ),

            const SizedBox(height: 4),

            // ── Row 3: Modes + settings  |  Volume bar ───────────────
            Row(
              children: [
                // Left cluster — loop, shuffle, speed/pitch
                const PlayerModes(),
                isMobile
                    ? const PlaybackSettings()
                    : const SpeedControl(),

                const SizedBox(width: 8),

                // Volume bar takes all remaining space
                const Expanded(child: VolumeBar()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopControls extends StatelessWidget {
  final PlayerHandler handler;
  final bool isPlaying;
  final bool isMobile;
  final double screenWidth;

  const _DesktopControls({
    required this.handler,
    required this.isPlaying,
    required this.isMobile,
    required this.screenWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SeekBar(),
          const SizedBox(height: 8),
          SizedBox(
            height: 52,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // LEFT — modes + speed
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const PlayerModes(),
                      const SizedBox(width: 4),
                      isMobile ? const PlaybackSettings() : const SpeedControl(),
                    ],
                  ),
                ),

                // CENTER — prev / play-pause / next
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SkipButton(icon: Icons.skip_previous_rounded, onTap: handler.previous, size: 24),
                    const SizedBox(width: 12),
                    _PlayPauseButton(isPlaying: isPlaying, onTap: handler.playPause, size: 48),
                    const SizedBox(width: 12),
                    _SkipButton(icon: Icons.skip_next_rounded, onTap: handler.next, size: 24),
                  ],
                ),

                // RIGHT — volume bar
                Positioned(right: 0, top: 0, bottom: 0, width: screenWidth * 0.22, child: const VolumeBar()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Reusable button widgets ────────────────────────────────────────────────────

class _PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onTap;
  final double size;

  const _PlayPauseButton({required this.isPlaying, required this.onTap, required this.size});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary,
          boxShadow: isPlaying
              ? [
                  BoxShadow(
                    color: primary.withValues(alpha: isDark ? 0.45 : 0.3),
                    blurRadius: 16,
                    spreadRadius: 0,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: size * 0.5),
      ),
    );
  }
}

class _SkipButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _SkipButton({required this.icon, required this.onTap, required this.size});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: size, color: iconColor),
      splashRadius: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    );
  }
}