import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
// hotkey_manager uses this same platform conversion before registering a key.
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:uni_platform/src/extensions/keyboard_key.dart';

enum DiscordKeybindAction { toggleMute, toggleDeafen }

extension DiscordKeybindActionLabel on DiscordKeybindAction {
  String get label => switch (this) {
    DiscordKeybindAction.toggleMute => 'Toggle Mute',
    DiscordKeybindAction.toggleDeafen => 'Toggle Deafen',
  };
}

typedef DiscordShortcutSender = Future<bool> Function(HotKey hotKey);

class DiscordKeybindService {
  static const String storageKey = 'companion_discord_keybinds_v1';
  static const MethodChannel _channel = MethodChannel('resonance/media_keys');

  final SharedPreferences? _preferences;
  final DiscordShortcutSender? _sender;

  const DiscordKeybindService({SharedPreferences? preferences, DiscordShortcutSender? sender})
    : _preferences = preferences,
      _sender = sender;

  static HotKey defaultFor(DiscordKeybindAction action) => HotKey(
    key: action == DiscordKeybindAction.toggleMute ? LogicalKeyboardKey.keyM : LogicalKeyboardKey.keyD,
    modifiers: const [HotKeyModifier.control, HotKeyModifier.shift],
  );

  Future<HotKey> get(DiscordKeybindAction action) async {
    final saved = await _load();
    final value = saved[action.name];
    if (value is Map) {
      try {
        return HotKey.fromJson(Map<String, dynamic>.from(value));
      } catch (_) {}
    }
    return defaultFor(action);
  }

  Future<void> set(DiscordKeybindAction action, HotKey hotKey) async {
    final saved = await _load();
    saved[action.name] = hotKey.toJson();
    await _save(saved);
  }

  Future<void> resetDefaults() async {
    await _save({for (final action in DiscordKeybindAction.values) action.name: defaultFor(action).toJson()});
  }

  Future<bool> trigger(DiscordKeybindAction action) async {
    final hotKey = await get(action);
    final sender = _sender;
    if (sender != null) return sender(hotKey);
    final physicalKey = hotKey.physicalKey;
    final keyCode = physicalKey.keyCode;
    if (keyCode == null) return false;
    try {
      return await _channel.invokeMethod<bool>('sendShortcut', {
            'keyCode': keyCode,
            // Native code prefers this layout-independent USB usage and
            // retains keyCode as a compatibility fallback.
            'hidUsage': physicalKey.usbHidUsage,
            'modifiers': (hotKey.modifiers ?? const <HotKeyModifier>[]).map((modifier) => modifier.name).toList(),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _load() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, dynamic> value) async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(value));
  }
}
