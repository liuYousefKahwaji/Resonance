import 'package:resonance/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_preferences.dart';
import 'package:resonance/screens/settings/equalizer_screen.dart';

class PlaybackSettings extends StatelessWidget {
  const PlaybackSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    return IconButton(
      icon: const Icon(Icons.settings_overscan), // or Icons.speed
      tooltip: context.tr("Playback Settings"),
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
  bool changingScope = false;

  @override
  void initState() {
    super.initState();
    speed = widget.handler.speedNotifier.value;
    pitch = widget.handler.pitchNotifier.value;
  }

  Future<void> _setScope(PlaybackSettingsScope scope) async {
    if (changingScope || scope == widget.handler.playbackSettingsScopeNotifier.value) return;
    setState(() => changingScope = true);
    try {
      await widget.handler.setPlaybackSettingsScope(scope);
      if (!mounted) return;
      setState(() {
        speed = widget.handler.speedNotifier.value;
        pitch = widget.handler.pitchNotifier.value;
      });
    } finally {
      if (mounted) setState(() => changingScope = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr("Playback Settings")),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<PlaybackSettingsScope>(
                valueListenable: widget.handler.playbackSettingsScopeNotifier,
                builder: (context, scope, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      context.tr("Apply settings to"),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<PlaybackSettingsScope>(
                      key: const Key('playback-scope-selector'),
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment<PlaybackSettingsScope>(
                          value: PlaybackSettingsScope.global,
                          label: Text(context.tr("All tracks")),
                          icon: Icon(Icons.library_music_rounded),
                        ),
                        ButtonSegment<PlaybackSettingsScope>(
                          value: PlaybackSettingsScope.perTrack,
                          label: Text(context.tr("Per track")),
                          icon: Icon(Icons.music_note_rounded),
                        ),
                      ],
                      selected: {scope},
                      onSelectionChanged: changingScope ? null : (selection) => _setScope(selection.first),
                    ),
                    const SizedBox(height: 7),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Text(
                        scope == PlaybackSettingsScope.global
                            ? context.tr("Use the same speed, pitch, and equalizer for every track.")
                            : context.tr("Remember these settings separately for each track."),
                        key: ValueKey(scope),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              // Speed control
              Row(
                children: [
                  Text(context.tr("Speed"), style: TextStyle(fontWeight: FontWeight.bold)),
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
                  Text(context.tr("Pitch"), style: TextStyle(fontWeight: FontWeight.bold)),
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
              StreamBuilder<MediaItem?>(
                stream: widget.handler.mediaItem,
                initialData: widget.handler.mediaItem.value,
                builder: (context, trackSnapshot) => AnimatedBuilder(
                  animation: Listenable.merge([
                    widget.handler.volumeNotifier,
                    widget.handler.trackVolumePercentNotifier,
                  ]),
                  builder: (context, _) {
                    final track = trackSnapshot.data;
                    final percent = widget.handler.trackVolumePercentNotifier.value;
                    final boosted = widget.handler.volumeNotifier.value > 1;
                    final label = '${percent > 0 ? '+' : ''}${percent.round()}%';
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.tr("This track’s volume"),
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
                            IconButton(
                              tooltip: context.tr("Reset track volume"),
                              onPressed: track == null || percent == 0
                                  ? null
                                  : () => widget.handler.setTrackVolumePercent(0),
                              icon: const Icon(Icons.restart_alt_rounded, size: 18),
                            ),
                          ],
                        ),
                        Text(
                          track?.title ?? context.tr("Play a track to adjust its volume."),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Slider(
                          key: const Key('track-volume-slider'),
                          value: percent,
                          min: -100,
                          max: 100,
                          divisions: 200,
                          label: label,
                          onChanged: track == null ? null : (value) => widget.handler.setTrackVolumePercent(value),
                        ),
                        Text(
                          boosted
                              ? context.tr(
                                  "Main volume boost is active. Positive track boosts are paused; reductions still apply.",
                                )
                              : context.tr(
                                  "Saved for this song only. −100% mutes it; +100% matches the maximum volume boost.",
                                ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 20),
                      ],
                    );
                  },
                ),
              ),
              ValueListenableBuilder<EqualizerSettings>(
                valueListenable: widget.handler.equalizerNotifier,
                builder: (context, equalizer, _) => Semantics(
                  button: true,
                  label: context.tr("Open equalizer, current preset {0}", [context.tr(equalizer.preset.label)]),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.equalizer_rounded),
                    title: Text(context.tr("Equalizer"), style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      equalizer.enabled ? context.tr(equalizer.preset.label) : context.tr("Off"),
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
      ),
      actions: [
        TextButton(
          onPressed: () async {
            setState(() {
              speed = 1.0;
              pitch = 1.0;
            });
            await widget.handler.resetPlaybackAdjustments();
            await widget.handler.setTrackVolumePercent(0);
          },
          child: Text(context.tr("Reset")),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr("Close"))),
      ],
    );
  }
}
