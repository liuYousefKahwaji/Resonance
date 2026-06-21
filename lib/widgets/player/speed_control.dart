// widgets/player/speed_control.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:audio_service/audio_service.dart';

class SpeedControl extends StatelessWidget {
  const SpeedControl({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, snapshot) {
        final currentSpeed = snapshot.data?.speed ?? 1.0;
        
        return IconButton(
          icon: const Icon(Icons.speed),
          tooltip: 'Playback Speed',
          onPressed: () {
            showDialog(
              context: context,
              builder: (context) {
                double speed = currentSpeed;
                return AlertDialog(
                  title: const Text('Playback Speed'),
                  content: StatefulBuilder(
                    builder: (context, setState) {
                      return SizedBox(
                        height: 100,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('${speed.toStringAsFixed(1)}x', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                tickMarkShape: SliderTickMarkShape.noTickMark,
                              ),
                              child: Slider(
                                value: speed,
                                min: 0.5,
                                max: 2.0,
                                divisions: 15,
                                label: speed.toStringAsFixed(1),
                                onChanged: (newSpeed) {
                                  setState(() {
                                    speed = newSpeed;
                                  });
                                  handler.setSpeed(newSpeed);
                                },
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                );
              },
            );
          },
        );
      }
    );
  }
}
