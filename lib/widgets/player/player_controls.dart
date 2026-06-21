import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
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

    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      initialData: handler.playbackState.value,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data?.playing ?? false;

        // =======================
        // MOBILE
        // =======================
        if (screenWidth < 500) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous, size: 28),
                      onPressed: handler.previous,
                    ),

                    const SizedBox(width: 12),

                    Container(
                      decoration: BoxDecoration(
                        color:
                            Theme.of(context).colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: Icon(
                          isPlaying ? Icons.pause : Icons.play_arrow,
                          size: 38,
                        ),
                        color: Theme.of(context)
                            .colorScheme
                            .onPrimaryContainer,
                        onPressed: handler.playPause,
                      ),
                    ),

                    const SizedBox(width: 12),

                    IconButton(
                      icon: const Icon(Icons.skip_next, size: 28),
                      onPressed: handler.next,
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                const SeekBar(),

                const SizedBox(height: 10),

                Row(
                  children: const [
                    PlayerModes(),
                    SizedBox(width: 4),
                    SpeedControl(),
                    SizedBox(width: 8),

                    Expanded(
                      child: VolumeBar(),
                    ),
                  ],
                ),
              ],
            ),
          );
        }

        // =======================
        // DESKTOP
        // =======================

        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 8,
          ),
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
                    // LEFT
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          PlayerModes(),
                          SizedBox(width: 4),
                          SpeedControl(),
                        ],
                      ),
                    ),

                    // CENTER
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.skip_previous),
                          onPressed: handler.previous,
                        ),

                        const SizedBox(width: 8),

                        IconButton(
                          icon: Icon(
                            isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            size: 32,
                          ),
                          onPressed: handler.playPause,
                        ),

                        const SizedBox(width: 8),

                        IconButton(
                          icon: const Icon(Icons.skip_next),
                          onPressed: handler.next,
                        ),
                      ],
                    ),

                    // RIGHT
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: screenWidth * 0.22,
                      child: const VolumeBar(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}