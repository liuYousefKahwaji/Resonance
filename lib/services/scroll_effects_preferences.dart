import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScrollEffectsPreferences {
  ScrollEffectsPreferences._();

  static final ScrollEffectsPreferences instance = ScrollEffectsPreferences._();
  static const _motionBlurKey = 'track_list_motion_blur';

  final ValueNotifier<bool> motionBlurEnabled = ValueNotifier<bool>(false);
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    motionBlurEnabled.value = prefs.getBool(_motionBlurKey) ?? false;
  }

  Future<void> setMotionBlurEnabled(bool enabled) async {
    motionBlurEnabled.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_motionBlurKey, enabled);
  }
}
