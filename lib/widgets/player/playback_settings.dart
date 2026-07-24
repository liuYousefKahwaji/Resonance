import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/equalizer_settings.dart';
import 'package:resonance/screens/settings/equalizer_screen.dart';

class PlaybackSettings extends StatelessWidget {
  const PlaybackSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    return IconButton(
      icon: const Icon(Icons.settings_overscan), // or Icons.speed
      tooltip: 'Playback Settings',
      onPressed: () {
        showDialog(
          context: context,
          builder: (context) {
            return _PlaybackSettingsDialog(handler: handler);
          },
        );
      },
    );
  }
}

class _PlaybackSettingsDialog extends StatefulWidget {
  final PlayerHandler handler;
  const _PlaybackSettingsDialog({required this.handler});

  @override
  State<_PlaybackSettingsDialog> createState() => _PlaybackSettingsDialogState();
}

class _PlaybackSettingsDialogState extends State<_PlaybackSettingsDialog> {
  late double speed;
  late double pitch;

  @override
  void initState() {
    super.initState();
    speed = widget.handler.speedNotifier.value;
    pitch = widget.handler.pitchNotifier.value;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Playback Settings'),
      content: SizedBox(
        width: 300,
        height: 240,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Speed control
            Row(
              children: [
                const Text('Speed', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 16),
                Expanded(
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
                      widget.handler.setSpeed(newSpeed);
                    },
                  ),
                ),
                Text('${speed.toStringAsFixed(1)}x', style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 20),
            // Pitch control
            Row(
              children: [
                const Text('Pitch', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 16),
                Expanded(
                  child: Slider(
                    value: pitch,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: pitch.toStringAsFixed(1),
                    onChanged: (newPitch) {
                      setState(() {
                        pitch = newPitch;
                      });
                      widget.handler.setPitch(newPitch);
                    },
                  ),
                ),
                Text('${pitch.toStringAsFixed(1)}x', style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 20),
            ValueListenableBuilder<EqualizerSettings>(
              valueListenable: widget.handler.equalizerNotifier,
              builder: (context, equalizer, _) => Semantics(
                button: true,
                label: 'Open equalizer, current preset ${equalizer.preset.label}',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.equalizer_rounded),
                  title: const Text('Equalizer', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    equalizer.enabled ? equalizer.preset.label : 'Off',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(builder: (_) => EqualizerScreen(handler: widget.handler)),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            setState(() {
              speed = 1.0;
              pitch = 1.0;
            });
            await widget.handler.resetPlaybackAdjustments();
          },
          child: const Text('Reset'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
