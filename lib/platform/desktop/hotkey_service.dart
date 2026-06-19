import 'dart:convert';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HotkeyService {
  static const String _prefsKey = 'saved_hotkeys';
  static final Map<String, HotKey> _activeHotKeys = {};
  
  // Call this on app startup to load and register all saved hotkeys
  static Future<void> init(Map<String, Function> callbacks) async {
    await hotKeyManager.unregisterAll();
    await _loadAndRegisterAll(callbacks);
  }

  static Future<void> _loadAndRegisterAll(Map<String, Function> callbacks) async {
    final prefs = await SharedPreferences.getInstance();
    final String? hotkeysJson = prefs.getString(_prefsKey);
    if (hotkeysJson == null) return;

    final Map<String, dynamic> savedHotkeys = jsonDecode(hotkeysJson);
    for (final entry in savedHotkeys.entries) {
      final actionId = entry.key;
      final hotKeyMap = Map<String, dynamic>.from(entry.value);
      final hotKey = HotKey.fromJson(hotKeyMap);
      
      _activeHotKeys[actionId] = hotKey;
      
      if (callbacks.containsKey(actionId)) {
        await hotKeyManager.register(
          hotKey,
          keyDownHandler: (_) => callbacks[actionId]!(),
        );
      }
    }
  }

  static Future<void> register(String actionId, HotKey hotKey, Function callback) async {
    if (_activeHotKeys.containsKey(actionId)) {
      await hotKeyManager.unregister(_activeHotKeys[actionId]!);
    }
    await hotKeyManager.register(
      hotKey,
      keyDownHandler: (_) => callback(),
    );
    _activeHotKeys[actionId] = hotKey;
    await _saveToPrefs(actionId, hotKey);
  }

  static Future<void> unregister(String actionId) async {
    if (_activeHotKeys.containsKey(actionId)) {
      await hotKeyManager.unregister(_activeHotKeys[actionId]!);
      _activeHotKeys.remove(actionId);
      await _removeFromPrefs(actionId);
    }
  }

  static Future<void> _saveToPrefs(String actionId, HotKey hotKey) async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> allHotkeys = {};
    final String? existing = prefs.getString(_prefsKey);
    if (existing != null) {
      allHotkeys.addAll(jsonDecode(existing) as Map<String, dynamic>);
    }
    allHotkeys[actionId] = hotKey.toJson();
    await prefs.setString(_prefsKey, jsonEncode(allHotkeys));
  }

  static Future<void> _removeFromPrefs(String actionId) async {
    final prefs = await SharedPreferences.getInstance();
    final String? existing = prefs.getString(_prefsKey);
    if (existing == null) return;
    final Map<String, dynamic> allHotkeys = jsonDecode(existing);
    allHotkeys.remove(actionId);
    await prefs.setString(_prefsKey, jsonEncode(allHotkeys));
  }

  // Get a saved hotkey definition for an action, without registering it.
  static Future<HotKey?> getSavedHotkey(String actionId) async {
    final prefs = await SharedPreferences.getInstance();
    final String? existing = prefs.getString(_prefsKey);
    if (existing == null) return null;
    final Map<String, dynamic> allHotkeys = jsonDecode(existing);
    if (!allHotkeys.containsKey(actionId)) return null;
    return HotKey.fromJson(Map<String, dynamic>.from(allHotkeys[actionId]));
  }

}

