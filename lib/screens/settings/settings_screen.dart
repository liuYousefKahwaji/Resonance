// lib/screens/settings/settings_screen.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/platform/android/storage_permission_service.dart';
import 'package:resonance/platform/desktop/hotkey_settings_tile.dart';
import 'package:resonance/platform/desktop/tray_settings.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:restart_app/restart_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/providers/theme_provider.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  TrayMode _selectedMode = TrayMode.closeToTray;
  bool _discordEnabled = true;
  final SettingsService _settingsService = SettingsService();

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      _loadTrayMode();
      _loadDiscordPreference();
    }
  }

  Future<void> _loadDiscordPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _discordEnabled = prefs.getBool('discord_enabled') ?? true;
      });
    }
  }

  Future<void> _toggleDiscord(bool value) async {
    setState(() => _discordEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('discord_enabled', value);
    if (value) {
      DiscordPresenceService().initialize();
    } else {
      await DiscordPresenceService().clearPresence();
      await DiscordPresenceService().dispose();
    }
  }

  Future<void> _loadTrayMode() async {
    final mode = await _settingsService.getTrayMode();
    if (mounted) {
      setState(() {
        _selectedMode = mode;
      });
    }
  }

  Future<void> _saveTrayMode(TrayMode? mode) async {
    if (mode == null || mode == _selectedMode) return;
    await _settingsService.setTrayMode(mode);
    setState(() {
      _selectedMode = mode;
    });
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Restart Required'),
          content: const Text('Tray mode changes need a restart to take effect.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Later'),
            ),
            ElevatedButton(
              onPressed: () => Restart.restartApp(),
              child: const Text('Restart Now'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Appearance ──────────────────────────────────────────────
            const Padding(
              padding: EdgeInsets.only(left: 8.0, top: 8.0, bottom: 8.0),
              child: Text(
                'Appearance:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Consumer<ThemeProvider>(
                builder: (context, themeProvider, child) {
                  return SwitchListTile(
                    title: const Text('Dark Mode'),
                    value: themeProvider.isDarkMode,
                    onChanged: (value) => themeProvider.toggleTheme(value),
                    secondary: const Icon(Icons.dark_mode, size: 28),
                  );
                },
              ),
            ),

            // ── Hotkeys (desktop only) ──────────────────────────────────
            if (_isDesktop) ...[
              const Padding(
                padding: EdgeInsets.only(left: 8.0, top: 8.0, bottom: 8.0),
                child: Text(
                  'Hotkeys:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 18.0),
                child: ListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    HotkeySettingsTile(
                      actionId: 'play_pause',
                      actionName: 'Play / Pause',
                      callback: handler.playPause,
                    ),
                    HotkeySettingsTile(
                      actionId: 'next',
                      actionName: 'Next Track',
                      callback: handler.next,
                    ),
                    HotkeySettingsTile(
                      actionId: 'previous',
                      actionName: 'Previous Track',
                      callback: handler.previous,
                    ),
                    HotkeySettingsTile(
                      actionId: 'volume_up',
                      actionName: 'Volume Up',
                      callback: () => handler.incrementVolume(),
                    ),
                    HotkeySettingsTile(
                      actionId: 'volume_down',
                      actionName: 'Volume Down',
                      callback: () => handler.decrementVolume(),
                    ),
                    HotkeySettingsTile(
                      actionId: 'speed_up',
                      actionName: 'Speed Up',
                      callback: () => handler.incrementSpeed(),
                    ),
                    HotkeySettingsTile(
                      actionId: 'speed_down',
                      actionName: 'Speed Down',
                      callback: () => handler.decrementSpeed(),
                    ),
                  ],
                ),
              ),
            ],

            // ── System Tray (desktop only) ──────────────────────────────
            if (_isDesktop) ...[
              const Padding(
                padding: EdgeInsets.only(left: 8.0, top: 16.0, bottom: 8.0),
                child: Text(
                  'System Tray:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
                ),
              ),
              TraySettings(selectedMode: _selectedMode, onChanged: _saveTrayMode),
            ],

            // ── Discord Rich Presence (desktop only) ────────────────────
            if (_isDesktop) ...[
              const Padding(
                padding: EdgeInsets.only(left: 8.0, top: 16.0, bottom: 8.0),
                child: Text(
                  'Discord Rich Presence:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: SwitchListTile(
                  title: const Text('Enable Discord Rich Presence'),
                  value: _discordEnabled,
                  onChanged: _toggleDiscord,
                  secondary: const Icon(Icons.discord, size: 28),
                ),
              ),
            ],

            // ── Permissions (Android only) ──────────────────────────────
            if (Platform.isAndroid) ...[
              const Padding(
                padding: EdgeInsets.only(left: 8.0, top: 8.0, bottom: 8.0),
                child: Text(
                  'Permissions:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: const Text('Audio / Storage Access'),
                  subtitle: const Text(
                    'Required to import music files from your device',
                  ),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () async {
                    final granted =
                        await StoragePermissionService.hasPermission();
                    if (granted) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Audio permission already granted ✓'),
                          ),
                        );
                      }
                    } else {
                      // Re-trigger permission request or open settings
                      await StoragePermissionService.requestWithRationale(
                        context,
                      );
                    }
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
