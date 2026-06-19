import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';

class VolumeBar extends StatelessWidget {
  const VolumeBar({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);

    return ValueListenableBuilder<double>(
      valueListenable: handler.volumeNotifier,
      builder: (context, currentVolume, child) {
        IconData icon;

        if (currentVolume == 0) {
          icon = Icons.volume_off;
        } else if (currentVolume < 0.33) {
          icon = Icons.volume_down;
        } else if (currentVolume < 0.66) {
          icon = Icons.volume_up;
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
              child: SliderTheme(
                data: const SliderThemeData(
                  trackHeight: 2,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: RoundSliderOverlayShape(overlayRadius: 24),
                ),
                child: Slider(
                  value: currentVolume.clamp(0.0, 1.0),
                  onChanged: (value) => handler.changeVolume(value.clamp(0.0, 1.0)),
                  min: 0,
                  max: 1,
                  divisions: 100,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
