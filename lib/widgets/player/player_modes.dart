// lib/widgets/player/player_modes.dart
// Logic: UNCHANGED. Visual refinement only.

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';

class PlayerModes extends StatefulWidget {
  const PlayerModes({super.key});

  @override
  State<PlayerModes> createState() => _PlayerModesState();
}

class _PlayerModesState extends State<PlayerModes> {
  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactiveColor = isDark ? const Color(0xFF475569) : const Color(0xFFABA8C8);

    final loopMode = handler.getLoopMode();
    final shuffleOn = handler.getShuffleMode();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Loop mode
        IconButton(
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: loopMode == LoopMode.one
                ? Icon(Icons.repeat_one_rounded,
                    key: const ValueKey('one'), color: primary, size: 20)
                : Icon(Icons.repeat_rounded,
                    key: ValueKey(loopMode),
                    color: loopMode == LoopMode.all ? primary : inactiveColor,
                    size: 20),
          ),
          onPressed: () => setState(() => handler.toggleLoopMode()),
          tooltip: loopMode == LoopMode.off
              ? 'Loop off'
              : loopMode == LoopMode.one
                  ? 'Loop one'
                  : 'Loop all',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        // Shuffle
        IconButton(
          icon: Icon(
            Icons.shuffle_rounded,
            size: 20,
            color: shuffleOn ? primary : inactiveColor,
          ),
          onPressed: () => setState(() => handler.toggleShuffle()),
          tooltip: shuffleOn ? 'Shuffle on' : 'Shuffle off',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
    );
  }
}