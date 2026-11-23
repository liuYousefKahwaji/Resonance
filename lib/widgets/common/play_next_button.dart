import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/playback_queue_snapshot.dart';

class PlayNextButton extends StatelessWidget {
  const PlayNextButton({super.key, required this.entry, required this.surface, this.color, this.extent = 42});

  final PlaybackQueueEntry entry;
  final PlaybackQueueSurface surface;
  final Color? color;
  final double extent;

  @override
  Widget build(BuildContext context) {
    final handler = context.read<PlayerHandler?>();
    if (handler == null) return const SizedBox.shrink();
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180);
    return ValueListenableBuilder(
      valueListenable: handler.activeQueueSurface,
      builder: (context, active, _) => AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SizeTransition(axis: Axis.horizontal, sizeFactor: animation, child: child),
        ),
        child: active == surface
            ? SizedBox.square(
                key: const ValueKey('play-next-visible'),
                dimension: extent,
                child: IconButton(
                  tooltip: context.tr('Play next'),
                  padding: EdgeInsets.zero,
                  color: color,
                  icon: const Icon(Icons.playlist_play_rounded, size: 22),
                  onPressed: () {
                    if (!handler.playNext(entry, surface: surface)) return;
                    ScaffoldMessenger.maybeOf(
                      context,
                    )?.showSnackBar(SnackBar(content: Text(context.tr('Playing next: {0}', [entry.title]))));
                  },
                ),
              )
            : const SizedBox.shrink(key: ValueKey('play-next-hidden')),
      ),
    );
  }
}
