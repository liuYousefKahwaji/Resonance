import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Explicit opt-in for mutating the user's YouTube Music listening history.
class YoutubeHistoryPreferences extends ChangeNotifier {
  YoutubeHistoryPreferences._(this._preferences);

  static const preferenceKey = 'youtube_music_history_sync_enabled';

  final SharedPreferences _preferences;
  bool _enabled = false;

  bool get enabled => _enabled;

  static Future<YoutubeHistoryPreferences> load({SharedPreferences? preferences}) async {
    final instance = YoutubeHistoryPreferences._(preferences ?? await SharedPreferences.getInstance());
    instance._enabled = instance._preferences.getBool(preferenceKey) ?? false;
    return instance;
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await _preferences.setBool(preferenceKey, value);
  }
}
