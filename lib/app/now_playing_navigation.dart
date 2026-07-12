import 'dart:async';

import 'package:flutter/material.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';

enum NowPlayingDestination { playlist, standalonePlayer }

NowPlayingDestination nowPlayingDestination({required bool isStandalone}) =>
    isStandalone ? NowPlayingDestination.standalonePlayer : NowPlayingDestination.playlist;

Future<void> navigateFromNowPlaying({
  required NavigatorState navigator,
  required bool isStandalone,
  required String trackPath,
  required FutureOr<void> Function(String trackPath) revealTrack,
  Route<void> Function()? standaloneRouteBuilder,
}) async {
  switch (nowPlayingDestination(isStandalone: isStandalone)) {
    case NowPlayingDestination.standalonePlayer:
      await navigator.push<void>(
        standaloneRouteBuilder?.call() ?? MaterialPageRoute<void>(builder: (_) => const StandalonePlayerScreen()),
      );
    case NowPlayingDestination.playlist:
      await revealTrack(trackPath);
  }
}
