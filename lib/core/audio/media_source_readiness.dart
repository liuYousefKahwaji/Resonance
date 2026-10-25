import 'dart:async';
import 'package:media_kit/media_kit.dart' as mk;

/// media_kit.open finishes when the load command is accepted, before mpv has
/// necessarily loaded remote metadata. Seeking before then can silently fail.
/// Polling is bounded and abandons a superseded source without holding up Next.
Future<bool> waitForMediaSourceReady(mk.Player player, bool Function() current) async {
  if (player.platform is! mk.NativePlayer) return current();
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  while (current()) {
    final state = player.state;
    if (state.duration > Duration.zero || (state.width ?? 0) > 0 || state.audioParams.sampleRate != null) {
      return true;
    }
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('Media source did not become ready');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return false;
}
