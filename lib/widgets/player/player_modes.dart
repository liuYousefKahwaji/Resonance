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
    return Row(
      children: [
        //Loop Modes
        IconButton(
          icon: (handler.getLoopMode() == LoopMode.one) ? Icon(Icons.repeat_one, color: Theme.of(context).colorScheme.primary,) : (handler.currentLoopMode == LoopMode.all) ? Icon(Icons.repeat, color: Theme.of(context).colorScheme.primary,) : Icon(Icons.repeat,),
          onPressed: () {
            setState(() {
              handler.toggleLoopMode();
            });
          },
        ),
        //Shuffle
        IconButton(
          icon: Icon(Icons.shuffle, color: handler.getShuffleMode() ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface,),
          onPressed: () {
            setState(() {
              handler.toggleShuffle();
            });
          },
        ),
      ],
    );
  }
}