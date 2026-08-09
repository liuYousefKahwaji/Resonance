import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@visibleForTesting
int normalizeLyricsFramesPerSecond(int? value) => value == 30 ? 30 : 120;

Duration lyricsFrameInterval(int framesPerSecond) =>
    Duration(microseconds: (Duration.microsecondsPerSecond / normalizeLyricsFramesPerSecond(framesPerSecond)).round());

class LyricsDisplayPreferences {
  LyricsDisplayPreferences._();

  static final LyricsDisplayPreferences instance = LyricsDisplayPreferences._();
  static const String preferenceKey = 'lyrics_animation_fps';

  final ValueNotifier<int> framesPerSecond = ValueNotifier<int>(120);
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    final preferences = await SharedPreferences.getInstance();
    framesPerSecond.value = normalizeLyricsFramesPerSecond(preferences.getInt(preferenceKey));
    _initialized = true;
  }

  Future<void> setFramesPerSecond(int value) async {
    final normalized = normalizeLyricsFramesPerSecond(value);
    framesPerSecond.value = normalized;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(preferenceKey, normalized);
  }
}
