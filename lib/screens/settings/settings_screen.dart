// lib/screens/settings/settings_screen.dart
// Logic: UNCHANGED. Visual refresh only — new section headers, spacing, icons.

import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/platform/android/storage_permission_service.dart';
import 'package:resonance/platform/desktop/hotkey_settings_tile.dart';
import 'package:resonance/platform/desktop/tray_settings.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:restart_app/restart_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/providers/theme_provider.dart';

bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  TrayMode _selectedMode = TrayMode.closeToTray;
  bool _discordEnabled = true;
  bool _introEnabled = true;
  String _downloadDirectory = 'Default App Folder';
  int _seekStepSeconds = 5;
  bool _coverLookupRunning = false;
  String _coverLookupStatus = '';
  final SettingsService _settingsService = SettingsService();

  @override
  void initState() {
    super.initState();
    _loadDownloadDirectory();
    _loadSeekStep();
    _loadIntroPreference();
    if (_isDesktop) {
      _loadTrayMode();
      _loadDiscordPreference();
    }
  }

  Future<void> _loadIntroPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _introEnabled = prefs.getBool('intro_enabled') ?? true);
  }

  Future<void> _toggleIntro(bool value) async {
    setState(() => _introEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('intro_enabled', value);
  }

  Future<void> _loadSeekStep() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _seekStepSeconds = (prefs.getInt('seek_step_seconds') ?? 5).clamp(1, 15));
    }
  }

  Future<void> _saveSeekStep(int value, PlayerHandler handler) async {
    final clamped = value.clamp(1, 15);
    setState(() => _seekStepSeconds = clamped);
    await handler.setSeekStepSeconds(clamped);
  }

  Future<void> _loadDownloadDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _downloadDirectory = prefs.getString('download_directory') ?? 'Default App Folder';
      });
    }
  }

  Future<void> _pickDownloadDirectory() async {
    final selectedDirectory = await FilePicker.getDirectoryPath(dialogTitle: 'Select Music Download Location');
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
          content: const Text('Tray mode changes need a restart to take effect.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
            ElevatedButton(onPressed: () => Restart.restartApp(), child: const Text('Restart Now')),
          ],
        ),
      );
    }
  }

  Future<void> _fillMissingCovers() async {
    if (_coverLookupRunning) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fill missing covers?'),
        content: const Text(
          'This searches YouTube for each local track in the current playlist and embeds the first result thumbnail only when the track has no cover.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Start')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _coverLookupRunning = true;
      _coverLookupStatus = 'Reading current playlist...';
    });

    var updated = 0;
    var skipped = 0;
    var failed = 0;

    try {
      final content = await FileService().readTextFromFile();
      final tracks = content
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .where((line) => !line.startsWith('http://') && !line.startsWith('https://'))
          .toList();

      for (var i = 0; i < tracks.length; i++) {
        final track = tracks[i];
        if (!mounted) return;
        setState(() => _coverLookupStatus = 'Checking ${i + 1}/${tracks.length}: ${p.basename(track)}');

        try {
          final file = File(track);
          if (!await file.exists()) {
            failed++;
            continue;
          }

          final metadata = await MetadataGod.readMetadata(file: track);
          final existingPicture = metadata.picture;
          if (existingPicture != null && existingPicture.data.isNotEmpty) {
            skipped++;
            continue;
          }

          final query = (metadata.title?.trim().isNotEmpty ?? false)
              ? metadata.title!.trim()
              : p.basenameWithoutExtension(track);
          if (query.isEmpty) {
            failed++;
            continue;
          }

          setState(() => _coverLookupStatus = 'Searching YouTube: $query');
          final thumbnailUrl = await _lookupFirstThumbnail(query);
          if (thumbnailUrl == null || thumbnailUrl.isEmpty) {
            failed++;
            continue;
          }

          final bytes = await _downloadBytes(thumbnailUrl);
          if (bytes.isEmpty) {
            failed++;
            continue;
          }

          await MetadataGod.writeMetadata(
            file: track,
            metadata: _metadataWithPicture(
              metadata,
              Picture(mimeType: _mimeTypeForImage(thumbnailUrl, bytes), data: bytes),
            ),
          );
          updated++;
        } catch (_) {
          failed++;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cover lookup complete: $updated updated, $skipped skipped, $failed failed.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cover lookup failed: $e'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _coverLookupRunning = false;
          _coverLookupStatus = '';
        });
      }
    }
  }

  Future<String?> _lookupFirstThumbnail(String query) async {
    if (Platform.isAndroid) {
      const channel = MethodChannel('resonance/android_youtube');
      final raw = await channel.invokeMethod<String>('getFirstThumbnail', {'query': query});
      final data = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      return data['thumbnail'] as String?;
    }

    if (Platform.isWindows) {
      final binDir = p.join(p.dirname(Platform.resolvedExecutable), 'bin');
      final ytDlpPath = p.join(binDir, 'yt-dlp.exe');
      final denoPath = p.join(binDir, 'deno.exe');
      final process = await Process.start(ytDlpPath, [
        '--js-runtimes',
        'deno:$denoPath',
        '--dump-single-json',
        '--skip-download',
        '--no-warnings',
        'ytsearch1:$query',
      ]);
      process.stderr.drain();
      final output = await process.stdout.transform(utf8.decoder).join();
      final exitCode = await process.exitCode;
      if (exitCode != 0 || output.trim().isEmpty) return null;
      final data = jsonDecode(output) as Map<String, dynamic>;
      final entries = data['entries'];
      final first = entries is List && entries.isNotEmpty && entries.first is Map
          ? Map<String, dynamic>.from(entries.first as Map)
          : data;
      final thumbnails = first['thumbnails'];
      if (thumbnails is List && thumbnails.isNotEmpty && thumbnails.last is Map) {
        return (thumbnails.last as Map)['url'] as String?;
      }
      return first['thumbnail'] as String?;
    }

    throw UnsupportedError('Cover lookup is only available on Android and Windows.');
  }

  Future<Uint8List> _downloadBytes(String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) return Uint8List(0);
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }
      return Uint8List.fromList(chunks);
    } finally {
      client.close(force: true);
    }
  }

  Metadata _metadataWithPicture(Metadata metadata, Picture picture) {
    return Metadata(
      title: metadata.title,
      durationMs: metadata.durationMs,
      artist: metadata.artist,
      album: metadata.album,
      albumArtist: metadata.albumArtist,
      trackNumber: metadata.trackNumber,
      trackTotal: metadata.trackTotal,
      discNumber: metadata.discNumber,
      discTotal: metadata.discTotal,
      year: metadata.year,
      genre: metadata.genre,
      picture: picture,
      fileSize: metadata.fileSize,
    );
  }

  String _mimeTypeForImage(String path, List<int> bytes) {
    final extension = p.extension(Uri.tryParse(path)?.path ?? path).toLowerCase();
    if (extension == '.png' || (bytes.length > 4 && bytes[0] == 0x89 && bytes[1] == 0x50)) {
      return 'image/png';
    }
    if (extension == '.webp' ||
        (bytes.length > 12 &&
            bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46 &&
            bytes[8] == 0x57 &&
            bytes[9] == 0x45)) {
      return 'image/webp';
    }
    return 'image/jpeg';
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
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
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
                      trailing: Switch(value: themeProvider.isDarkMode, onChanged: themeProvider.toggleTheme),
                    );
                  },
                ),
                _Divider(),
                _SettingsTile(
                  icon: Icons.auto_awesome_rounded,
                  title: 'Startup Intro',
                  subtitle: 'Show the Resonance pulse when the app opens',
                  trailing: Switch(value: _introEnabled, onChanged: _toggleIntro),
                ),
              ],
            ),

            // ── Playback ────────────────────────────────────────────
            _SectionHeader(label: 'Playback'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.forward_5_rounded,
                  title: 'Seek Step',
                  subtitle: 'Used by seek buttons and seek hotkeys',
                  trailing: SizedBox(
                    width: 180,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Expanded(
                          child: Slider(
                            value: _seekStepSeconds.toDouble(),
                            min: 1,
                            max: 15,
                            divisions: 14,
                            label: '${_seekStepSeconds}s',
                            onChanged: (value) => _saveSeekStep(value.round(), handler),
                          ),
                        ),
                        SizedBox(
                          width: 34,
                          child: Text(
                            '${_seekStepSeconds}s',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                    color: isDark ? const Color(0xFF475569) : const Color(0xFFABA8C8),
                  ),
                  onTap: _pickDownloadDirectory,
                ),
                if (Platform.isAndroid || Platform.isWindows) ...[
                  _Divider(),
                  _SettingsTile(
                    icon: Icons.image_search_rounded,
                    title: 'Fill Missing Covers',
                    subtitle: _coverLookupRunning
                        ? _coverLookupStatus
                        : 'Search YouTube for cover art for tracks missing embedded images',
                    trailing: _coverLookupRunning
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.play_arrow_rounded, size: 18),
                    onTap: _coverLookupRunning ? null : _fillMissingCovers,
                  ),
                ],
              ],
            ),

            // ── Hotkeys (desktop only) ──────────────────────────────
            if (_isDesktop) ...[
              _SectionHeader(label: 'Hotkeys'),
              _SettingsCard(
                children: [
                  HotkeySettingsTile(actionId: 'play_pause', actionName: 'Play / Pause', callback: handler.playPause),
                  _Divider(),
                  HotkeySettingsTile(actionId: 'next', actionName: 'Next Track', callback: handler.next),
                  _Divider(),
                  HotkeySettingsTile(actionId: 'previous', actionName: 'Previous Track', callback: handler.previous),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'seek_backward',
                    actionName: 'Seek Backward',
                    callback: () async => handler.seekBySeconds(-(await handler.getSeekStepSeconds())),
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'seek_forward',
                    actionName: 'Seek Forward',
                    callback: () async => handler.seekBySeconds(await handler.getSeekStepSeconds()),
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
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: TraySettings(selectedMode: _selectedMode, onChanged: _saveTrayMode),
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
                    trailing: Switch(value: _discordEnabled, onChanged: _toggleDiscord),
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
                      final granted = await StoragePermissionService.hasPermission();
                      if (granted) {
                        if (mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(const SnackBar(content: Text('Audio permission already granted ✓')));
                        }
                      } else {
                        await StoragePermissionService.requestWithRationale(context);
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
        border: Border.all(color: isDark ? const Color(0xFF2D2D42) : const Color(0xFFDDD9F3), width: 1),
      ),
      child: Column(children: children),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({required this.icon, required this.title, this.subtitle, this.trailing, this.onTap});

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
          color: isDark ? primary.withValues(alpha: 0.12) : primary.withValues(alpha: 0.08),
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
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
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
      child: Divider(height: 1, thickness: 1, color: isDark ? const Color(0xFF1F1F30) : const Color(0xFFF0EFF5)),
    );
  }
}
