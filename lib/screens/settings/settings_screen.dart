// lib/screens/settings/settings_screen.dart
// Logic: UNCHANGED. Visual refresh only — new section headers, spacing, icons.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
  String _downloadDirectory = 'Default App Folder';
  final SettingsService _settingsService = SettingsService();

  @override
  void initState() {
    super.initState();
    _loadDownloadDirectory();
    if (_isDesktop) {
      _loadTrayMode();
      _loadDiscordPreference();
    }
  }

  Future<void> _loadDownloadDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _downloadDirectory =
            prefs.getString('download_directory') ?? 'Default App Folder';
      });
    }
  }

  Future<void> _pickDownloadDirectory() async {
    final selectedDirectory = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Music Download Location',
    );
    if (selectedDirectory != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('download_directory', selectedDirectory);
      setState(() => _downloadDirectory = selectedDirectory);
    }
  }

  Future<void> _loadDiscordPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _discordEnabled = prefs.getBool('discord_enabled') ?? true);
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
    if (mounted) setState(() => _selectedMode = mode);
  }

  Future<void> _saveTrayMode(TrayMode? mode) async {
    if (mode == null || mode == _selectedMode) return;
    await _settingsService.setTrayMode(mode);
    setState(() => _selectedMode = mode);
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Restart Required'),
          content: const Text(
              'Tray mode changes need a restart to take effect.'),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
          color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Appearance ──────────────────────────────────────────
            _SectionHeader(label: 'Appearance'),
            _SettingsCard(
              children: [
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, child) {
                    return _SettingsTile(
                      icon: Icons.dark_mode_rounded,
                      title: 'Dark Mode',
                      trailing: Switch(
                        value: themeProvider.isDarkMode,
                        onChanged: themeProvider.toggleTheme,
                      ),
                    );
                  },
                ),
              ],
            ),

            // ── Downloads ───────────────────────────────────────────
            _SectionHeader(label: 'Downloads'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.folder_open_rounded,
                  title: 'Download Location',
                  subtitle: _downloadDirectory,
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: isDark
                        ? const Color(0xFF475569)
                        : const Color(0xFFABA8C8),
                  ),
                  onTap: _pickDownloadDirectory,
                ),
              ],
            ),

            // ── Hotkeys (desktop only) ──────────────────────────────
            if (_isDesktop) ...[
              _SectionHeader(label: 'Hotkeys'),
              _SettingsCard(
                children: [
                  HotkeySettingsTile(
                    actionId: 'play_pause',
                    actionName: 'Play / Pause',
                    callback: handler.playPause,
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'next',
                    actionName: 'Next Track',
                    callback: handler.next,
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'previous',
                    actionName: 'Previous Track',
                    callback: handler.previous,
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'volume_up',
                    actionName: 'Volume Up',
                    callback: () => handler.incrementVolume(),
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'volume_down',
                    actionName: 'Volume Down',
                    callback: () => handler.decrementVolume(),
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'speed_up',
                    actionName: 'Speed Up',
                    callback: () => handler.incrementSpeed(),
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'speed_down',
                    actionName: 'Speed Down',
                    callback: () => handler.decrementSpeed(),
                  ),
                ],
              ),
            ],

            // ── System Tray (desktop only) ──────────────────────────
            if (_isDesktop) ...[
              _SectionHeader(label: 'System Tray'),
              _SettingsCard(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 8),
                    child: TraySettings(
                      selectedMode: _selectedMode,
                      onChanged: _saveTrayMode,
                    ),
                  ),
                ],
              ),
            ],

            // ── Discord Rich Presence (desktop only) ────────────────
            if (_isDesktop) ...[
              _SectionHeader(label: 'Integrations'),
              _SettingsCard(
                children: [
                  _SettingsTile(
                    icon: Icons.discord,
                    title: 'Discord Rich Presence',
                    subtitle: 'Show what you\'re listening to on Discord',
                    trailing: Switch(
                      value: _discordEnabled,
                      onChanged: _toggleDiscord,
                    ),
                  ),
                ],
              ),
            ],

            // ── Permissions (Android only) ──────────────────────────
            if (Platform.isAndroid) ...[
              _SectionHeader(label: 'Permissions'),
              _SettingsCard(
                children: [
                  _SettingsTile(
                    icon: Icons.folder_open_rounded,
                    title: 'Audio / Storage Access',
                    subtitle: 'Required to import music files',
                    trailing: const Icon(Icons.open_in_new_rounded, size: 16),
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
                        await StoragePermissionService.requestWithRationale(
                            context);
                      }
                    },
                  ),
                ],
              ),
            ],

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ── Shared settings UI components ─────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A2A) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF2D2D42) : const Color(0xFFDDD9F3),
          width: 1,
        ),
      ),
      child: Column(
        children: children,
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: isDark
              ? primary.withValues(alpha: 0.12)
              : primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, size: 18, color: primary),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A),
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF64748B),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: trailing,
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(left: 68),
      child: Divider(
        height: 1,
        thickness: 1,
        color:
            isDark ? const Color(0xFF1F1F30) : const Color(0xFFF0EFF5),
      ),
    );
  }
}