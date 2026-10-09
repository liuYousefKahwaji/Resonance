import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/widgets/settings/language_selector.dart';
import 'package:flutter/services.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/loudness_normalization.dart';
import 'package:resonance/core/audio/playback_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/platform/android/storage_permission_service.dart';
import 'package:resonance/platform/desktop/hotkey_settings_tile.dart';
import 'package:resonance/platform/desktop/tray_settings.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:restart_app/restart_app.dart';
import 'package:resonance/platform/desktop/windows_restart.dart';
import 'package:resonance/widgets/android_update_status.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/screens/settings/app_version_label.dart';
import 'package:resonance/screens/settings/i_dont_know_page.dart';
import 'package:resonance/screens/settings/download_history_screen.dart';
import 'package:resonance/screens/settings/companion_screen.dart';
import 'package:resonance/screens/settings/equalizer_screen.dart';
import 'package:resonance/services/companion/companion_client_service.dart';
import 'package:resonance/services/companion/companion_server_service.dart';
import 'package:resonance/services/scroll_effects_preferences.dart';
import 'package:resonance/services/lyrics_display_preferences.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';
import 'package:resonance/screens/settings/youtube_access_screen.dart';
import 'package:resonance/screens/onboarding/onboarding_screen.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/widgets/youtube/youtube_failure_dialog.dart';
import 'package:resonance/widgets/app_update_prompt.dart';
import 'package:resonance/services/app_update_service.dart';
import 'package:resonance/screens/settings/backup_screen.dart';
import 'package:resonance/screens/settings/listening_statistics_screen.dart';

String _youtubeAccessSubtitle(BuildContext context, YoutubeAccessService service) {
  final status = service.status;
  if (status.state != YoutubeAccessState.ready) return context.trRendered(service.settingsSubtitle);
  final session = status.method == YoutubeAccessMethod.windowsBrowser
      ? context.tr('Using {0} browser session', [YoutubeAccessService.browserDisplayName(status.browserId)])
      : context.tr('YouTube cookies imported');
  final tested = status.lastTestedAt;
  if (tested == null) return session;
  final elapsed = DateTime.now().difference(tested);
  final relative = elapsed.inMinutes < 1
      ? context.tr('just now')
      : elapsed.inHours < 1
      ? context.tr('{0} min ago', [elapsed.inMinutes])
      : elapsed.inDays < 1
      ? context.tr('{0} hr ago', [elapsed.inHours])
      : context.tr('{0} days ago', [elapsed.inDays]);
  return '$session · ${context.tr('tested {0}', [relative])}';
}

bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.onExit});

  final VoidCallback onExit;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final VersionTapTracker _versionTaps = VersionTapTracker();
  TrayMode _selectedMode = TrayMode.closeToTray;
  bool _discordEnabled = true;
  bool _introEnabled = true;
  bool _androidAutoUpdates = false;
  bool _checkingUpdate = false;
  String _downloadDirectory = 'Default App Folder';
  int _seekStepSeconds = 5;
  bool _crossfadeEnabled = false;
  double _crossfadeDurationSeconds = 3.0;
  bool _resumeLongTracks = true;
  PlaybackSettingsScope _playbackSettingsScope = PlaybackSettingsScope.global;
  bool _coverLookupRunning = false;
  String _coverLookupStatus = '';
  final SettingsService _settingsService = SettingsService();

  Future<void> _pickCustomThemeColor(ThemeProvider provider) async {
    final result = await showDialog<Color>(
      context: context,
      builder: (_) => _CustomColorPicker(initialColor: provider.customColor),
    );
    if (result != null) {
      await provider.setCustomColor(result);
      await provider.setThemeStyle(ResonanceThemeStyle.custom);
    }
  }

  void _handleVersionTap() {
    if (_versionTaps.registerTap()) {
      Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => IDontKnowPage(onExit: widget.onExit)));
    }
  }

  @override
  void initState() {
    super.initState();
    AppUpdateService.available.addListener(_updateAvailabilityChanged);
    _loadDownloadDirectory();
    _loadSeekStep();
    _loadPlaybackPreferences();
    _loadIntroPreference();
    _loadAndroidAutoUpdates();
    unawaited(ScrollEffectsPreferences.instance.initialize());
    if (_isDesktop) {
      _loadTrayMode();
      _loadDiscordPreference();
    }
  }

  void _updateAvailabilityChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppUpdateService.available.removeListener(_updateAvailabilityChanged);
    super.dispose();
  }

  Future<void> _loadIntroPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _introEnabled = prefs.getBool('intro_enabled') ?? true);
  }

  Future<void> _loadAndroidAutoUpdates() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _androidAutoUpdates = prefs.getBool('android_auto_updates') ?? false);
  }

  Future<void> _setAndroidAutoUpdates(bool enabled) async {
    setState(() => _androidAutoUpdates = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('android_auto_updates', enabled);
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final update = AppUpdateService.available.value ?? await AppUpdateService().check(force: true);
      if (!mounted) return;
      if (update == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr("Resonance is up to date."))));
      } else {
        await showAppUpdatePrompt(context, update);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr("Could not check for updates: {0}", [error]))));
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
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

  Future<void> _loadPlaybackPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final scopeName = prefs.getString('playback_settings_scope');
    if (!mounted) return;
    setState(() {
      _crossfadeEnabled = prefs.getBool('crossfade_enabled') ?? false;
      _crossfadeDurationSeconds = (prefs.getDouble('crossfade_duration_seconds') ?? 3.0).clamp(0.0, 8.0);
      _resumeLongTracks = prefs.getBool('resume_long_tracks') ?? true;
      _playbackSettingsScope = PlaybackSettingsScope.values.firstWhere(
        (scope) => scope.name == scopeName,
        orElse: () => PlaybackSettingsScope.global,
      );
    });
  }

  Future<void> _toggleCrossfade(bool enabled, PlayerHandler handler) async {
    setState(() => _crossfadeEnabled = enabled);
    await handler.setCrossfadeEnabled(enabled);
  }

  Future<void> _setCrossfadeDuration(double seconds, PlayerHandler handler) async {
    setState(() => _crossfadeDurationSeconds = seconds.clamp(0.0, 8.0));
    await handler.setCrossfadeDuration(seconds);
  }

  Future<void> _toggleResumeLongTracks(bool enabled, PlayerHandler handler) async {
    setState(() => _resumeLongTracks = enabled);
    await handler.setResumeLongTracksEnabled(enabled);
  }

  Future<void> _setPlaybackSettingsScope(PlaybackSettingsScope? scope, PlayerHandler handler) async {
    if (scope == null || scope == _playbackSettingsScope) return;
    setState(() => _playbackSettingsScope = scope);
    await handler.setPlaybackSettingsScope(scope);
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
    await DiscordPresenceService().setEnabled(value);
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
          title: Text(context.tr("Restart Required")),
          content: Text(context.tr("Tray mode changes need a restart to take effect.")),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr("Later"))),
            ElevatedButton(
              onPressed: () async {
                try {
                  await context.read<PlayerHandler>().saveState();
                  if (Platform.isWindows) {
                    await restartWindowsApp();
                  } else {
                    await Restart.restartApp();
                  }
                } catch (error) {
                  if (mounted) {
                    ScaffoldMessenger.of(
                      this.context,
                    ).showSnackBar(SnackBar(content: Text(context.tr("Could not restart: {0}", [error]))));
                  }
                }
              },
              child: Text(context.tr("Restart Now")),
            ),
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
        title: Text(context.tr("Fill missing covers?")),
        content: Text(
          context.tr(
            "This searches YouTube for each local track in the current playlist and embeds the first result thumbnail only when the track has no cover.",
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr("Cancel"))),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr("Start"))),
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
    final handler = Provider.of<PlayerHandler>(context, listen: false);

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

          await handler.withTrackFileReleased(
            track,
            () => MetadataGod.writeMetadata(
              file: track,
              metadata: _metadataWithPicture(
                metadata,
                Picture(mimeType: _mimeTypeForImage(thumbnailUrl, bytes), data: bytes),
              ),
            ),
            updatedTitle: metadata.title?.trim().isNotEmpty == true
                ? metadata.title!.trim()
                : p.basenameWithoutExtension(track),
            updatedArtist: metadata.artist?.trim().isNotEmpty == true ? metadata.artist!.trim() : 'Unknown Artist',
          );
          updated++;
        } on YoutubeFailure catch (failure) {
          if (failure.isAccessFailure) rethrow;
          failed++;
        } catch (_) {
          failed++;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr("Cover lookup complete: {0} updated, {1} skipped, {2} failed.", [updated, skipped, failed]),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        await showYoutubeFailure(context, e, actionLabel: context.tr("Cover lookup failed"));
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
      try {
        final raw = await channel.invokeMethod<String>('getFirstThumbnail', {'query': query});
        final data = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
        return data['thumbnail'] as String?;
      } catch (error) {
        final failure = YoutubeFailureClassifier.classify(
          error,
          authenticated: YoutubeAccessService.active?.isConfigured ?? false,
        );
        YoutubeAccessService.active?.observeFailure(failure);
        throw failure;
      }
    }

    if (Platform.isWindows) {
      final result = await WindowsYtdlpRunner.instance.run([
        '--dump-single-json',
        '--skip-download',
        '--no-warnings',
        'ytsearch1:$query',
      ], requireOutput: true);
      final data = jsonDecode(result.stdout) as Map<String, dynamic>;
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
        title: Text(context.tr("Settings")),
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
            _SectionHeader(label: context.tr("Appearance")),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.language_rounded,
                  title: context.tr('Language'),
                  trailing: const LanguageSelector(),
                ),
                _Divider(),
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, child) => _SettingsTile(
                    icon: Icons.explore_rounded,
                    title: context.tr("Listening focus"),
                    subtitle: themeProvider.listeningFocus == ListeningFocus.local
                        ? context.tr("Open your local library first")
                        : context.tr("Open music discovery first; keep your library one tap away"),
                    trailing: DropdownButtonHideUnderline(
                      child: DropdownButton<ListeningFocus>(
                        key: const Key('listening-focus-setting'),
                        value: themeProvider.listeningFocus,
                        onChanged: (focus) {
                          if (focus != null) themeProvider.setListeningFocus(focus);
                        },
                        items: [
                          DropdownMenuItem(value: ListeningFocus.local, child: Text(context.tr("Local"))),
                          DropdownMenuItem(value: ListeningFocus.stream, child: Text(context.tr("Stream"))),
                        ],
                      ),
                    ),
                  ),
                ),
                _Divider(),
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, child) {
                    return _SettingsTile(
                      icon: Icons.dark_mode_rounded,
                      title: context.tr("Dark Mode"),
                      trailing: Switch(value: themeProvider.isDarkMode, onChanged: themeProvider.toggleTheme),
                    );
                  },
                ),
                if (Platform.isWindows) ...[
                  _Divider(),
                  Consumer<ThemeProvider>(
                    builder: (context, themeProvider, child) => _SettingsTile(
                      icon: Icons.desktop_windows_rounded,
                      title: context.tr("Windows-native controls"),
                      subtitle: context.tr(
                        "Use a Windows 11 title bar, command surfaces, menus, fields, focus, and controls",
                      ),
                      trailing: Switch(
                        value: themeProvider.windowsNativeControls,
                        onChanged: themeProvider.setWindowsNativeControls,
                      ),
                    ),
                  ),
                ],
                _Divider(),
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, child) {
                    return _SettingsTile(
                      icon: Icons.palette_rounded,
                      title: context.tr("Theme"),
                      subtitle: context.tr("Changes accent and supporting colors without restarting"),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<ResonanceThemeStyle>(
                          value: themeProvider.themeStyle,
                          onChanged: (style) {
                            if (style == null) return;
                            themeProvider.setThemeStyle(style);
                            if (style == ResonanceThemeStyle.custom) _pickCustomThemeColor(themeProvider);
                          },
                          items: [
                            for (final style in ResonanceThemeStyle.values)
                              DropdownMenuItem(value: style, child: Text(context.tr(style.label))),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, child) {
                    if (themeProvider.themeStyle != ResonanceThemeStyle.custom) return const SizedBox.shrink();
                    return Column(
                      children: [
                        _Divider(),
                        _SettingsTile(
                          icon: Icons.colorize_rounded,
                          title: context.tr("Custom color"),
                          subtitle: context.tr("Choose the accent, surfaces, and borders"),
                          trailing: CircleAvatar(backgroundColor: themeProvider.customColor, radius: 15),
                          onTap: () => _pickCustomThemeColor(themeProvider),
                        ),
                      ],
                    );
                  },
                ),
                _Divider(),
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, child) {
                    return _SettingsTile(
                      icon: Icons.layers_rounded,
                      title: context.tr("Full Theme Styling"),
                      subtitle: themeProvider.fullThemePalette
                          ? context.tr("Accent, backgrounds, surfaces, and borders")
                          : context.tr("Accent colors only — classic Resonance styling"),
                      trailing: Switch(
                        value: themeProvider.fullThemePalette,
                        onChanged: themeProvider.setFullThemePalette,
                      ),
                    );
                  },
                ),
                _Divider(),
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, child) => _SettingsTile(
                    icon: Icons.rounded_corner_rounded,
                    title: context.tr("Rounder corners"),
                    subtitle: context.tr("Use softer corners throughout Resonance"),
                    trailing: Switch(value: themeProvider.rounderCorners, onChanged: themeProvider.setRounderCorners),
                  ),
                ),
                _Divider(),
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, child) {
                    return _SettingsTile(
                      icon: Icons.color_lens_rounded,
                      title: context.tr("Artwork-based Player Colors"),
                      subtitle: context.tr("Blend safe colors from the current cover into player accents and glow"),
                      trailing: Switch(
                        value: themeProvider.artworkPlayerColors,
                        onChanged: themeProvider.setArtworkPlayerColors,
                      ),
                    );
                  },
                ),
                _Divider(),
                _SettingsTile(
                  icon: Icons.auto_awesome_rounded,
                  title: context.tr("Startup Intro"),
                  subtitle: context.tr("Show the Resonance pulse when the app opens"),
                  trailing: Switch(value: _introEnabled, onChanged: _toggleIntro),
                ),
                if (Platform.isAndroid) ...[
                  _Divider(),
                  ValueListenableBuilder<bool>(
                    valueListenable: ScrollEffectsPreferences.instance.motionBlurEnabled,
                    builder: (context, enabled, _) => _SettingsTile(
                      icon: Icons.blur_on_rounded,
                      title: context.tr("Track List Motion Blur"),
                      subtitle: context.tr("Optional scroll effect; off by default for smoother performance"),
                      trailing: Switch(
                        value: enabled,
                        onChanged: (value) => unawaited(ScrollEffectsPreferences.instance.setMotionBlurEnabled(value)),
                      ),
                    ),
                  ),
                ],
                _Divider(),
                ValueListenableBuilder<int>(
                  valueListenable: LyricsDisplayPreferences.instance.framesPerSecond,
                  builder: (context, framesPerSecond, _) => _SettingsTile(
                    icon: Icons.speed_rounded,
                    title: context.tr("Lyrics Animation"),
                    subtitle: framesPerSecond == 120
                        ? context.tr("Smoothest highlight motion; uses more power")
                        : context.tr("Battery-friendly highlight motion"),
                    trailing: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: const Key('lyrics-animation-fps-setting'),
                        value: framesPerSecond,
                        onChanged: (value) {
                          if (value != null) {
                            unawaited(LyricsDisplayPreferences.instance.setFramesPerSecond(value));
                          }
                        },
                        items: [
                          DropdownMenuItem(value: 30, child: Text(context.tr("30 FPS"))),
                          DropdownMenuItem(value: 120, child: Text(context.tr("120 FPS"))),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),

            // ── Playback ────────────────────────────────────────────
            _SectionHeader(label: context.tr("Playback")),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.forward_5_rounded,
                  title: context.tr("Seek Step"),
                  subtitle: context.tr("Used by seek buttons and seek hotkeys"),
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
                  stackTrailingOnNarrow: true,
                ),
                if (Platform.isWindows) ...[
                  _Divider(),
                  ValueListenableBuilder<List<PlaybackOutputDevice>>(
                    valueListenable: handler.availableOutputDevicesNotifier,
                    builder: (context, devices, _) => ValueListenableBuilder<PlaybackOutputDevice>(
                      valueListenable: handler.selectedOutputDeviceNotifier,
                      builder: (context, selected, _) {
                        final selectedValue = devices.any((device) => device.name == selected.name)
                            ? selected
                            : const PlaybackOutputDevice.systemDefault();
                        final hasPhysicalOutput = devices.any((device) => !device.isSystemDefault);
                        return _SettingsTile(
                          icon: Icons.speaker_rounded,
                          title: context.tr("Output device"),
                          subtitle: hasPhysicalOutput
                              ? context.tr("Choose where Resonance sends audio")
                              : context.tr("No physical output detected — connect speakers or headphones"),
                          trailing: SizedBox(
                            width: 220,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Expanded(
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<PlaybackOutputDevice>(
                                      isExpanded: true,
                                      value: selectedValue,
                                      onChanged: (device) {
                                        if (device != null) unawaited(handler.setOutputDevice(device.name));
                                      },
                                      items: [
                                        for (final device in devices)
                                          DropdownMenuItem<PlaybackOutputDevice>(
                                            value: device,
                                            child: Text(device.label, overflow: TextOverflow.ellipsis),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: context.tr("Refresh output devices"),
                                  onPressed: () => unawaited(handler.refreshOutputDevices()),
                                  icon: const Icon(Icons.refresh_rounded, size: 19),
                                ),
                              ],
                            ),
                          ),
                          stackTrailingOnNarrow: true,
                        );
                      },
                    ),
                  ),
                ] else if (Platform.isAndroid) ...[
                  _Divider(),
                  _SettingsTile(
                    icon: Icons.speaker_rounded,
                    title: context.tr("Output device"),
                    subtitle: context.tr(
                      "Android controls media routing. Use the system media output switcher to change devices.",
                    ),
                    trailing: Text(context.tr("System")),
                  ),
                ],
                _Divider(),
                _SettingsTile(
                  icon: Icons.multitrack_audio_rounded,
                  title: context.tr("Crossfade"),
                  subtitle: context.tr("Blend automatic track changes; manual seeking is unaffected"),
                  trailing: Switch(
                    value: _crossfadeEnabled,
                    onChanged: (enabled) => _toggleCrossfade(enabled, handler),
                  ),
                ),
                if (_crossfadeEnabled) ...[
                  _Divider(),
                  _SettingsTile(
                    icon: Icons.timelapse_rounded,
                    title: context.tr("Crossfade Duration"),
                    trailing: SizedBox(
                      width: 180,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Expanded(
                            child: Slider(
                              value: _crossfadeDurationSeconds,
                              min: 0,
                              max: 8,
                              divisions: 8,
                              label: '${_crossfadeDurationSeconds.round()}s',
                              onChanged: (value) => _setCrossfadeDuration(value, handler),
                            ),
                          ),
                          SizedBox(
                            width: 34,
                            child: Text(
                              '${_crossfadeDurationSeconds.round()}s',
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    stackTrailingOnNarrow: true,
                  ),
                ],
                _Divider(),
                _SettingsTile(
                  icon: Icons.restore_rounded,
                  title: context.tr("Resume Long Tracks"),
                  subtitle: context.tr("Remember progress for tracks at least 10 minutes long"),
                  trailing: Switch(
                    value: _resumeLongTracks,
                    onChanged: (enabled) => _toggleResumeLongTracks(enabled, handler),
                  ),
                ),
                _Divider(),
                ValueListenableBuilder<EqualizerSettings>(
                  valueListenable: handler.equalizerNotifier,
                  builder: (context, equalizer, _) => _SettingsTile(
                    icon: Icons.equalizer_rounded,
                    title: context.tr("Equalizer"),
                    subtitle: equalizer.enabled
                        ? context.tr("{0} · five adjustable bands", [context.tr(equalizer.preset.label)])
                        : context.tr("Off · five adjustable bands and presets"),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(builder: (_) => EqualizerScreen(handler: handler)),
                    ),
                  ),
                ),
                _Divider(),
                ValueListenableBuilder<bool>(
                  valueListenable: handler.volumeNormalizationEnabledNotifier,
                  builder: (context, enabled, _) => ValueListenableBuilder<LoudnessScanProgress>(
                    valueListenable: handler.loudnessScanProgressNotifier,
                    builder: (context, progress, _) => _SettingsTile(
                      icon: Icons.waves_rounded,
                      title: context.tr("Volume Normalization"),
                      subtitle: progress.scanning
                          ? context.tr("Analyzing in background · {0}/{1}", [progress.completed, progress.total])
                          : context.tr("Balance track loudness without delaying playback"),
                      trailing: Switch(value: enabled, onChanged: handler.setVolumeNormalizationEnabled),
                    ),
                  ),
                ),
                _Divider(),
                _SettingsTile(
                  icon: Icons.tune_rounded,
                  title: context.tr("Playback Settings Scope"),
                  subtitle: _playbackSettingsScope == PlaybackSettingsScope.global
                      ? context.tr("Use the same speed, pitch, and equalizer for every track")
                      : context.tr("Remember speed, pitch, and equalizer separately for each track"),
                  trailing: DropdownButtonHideUnderline(
                    child: DropdownButton<PlaybackSettingsScope>(
                      value: _playbackSettingsScope,
                      onChanged: (scope) => _setPlaybackSettingsScope(scope, handler),
                      items: [
                        DropdownMenuItem(value: PlaybackSettingsScope.global, child: Text(context.tr("All tracks"))),
                        DropdownMenuItem(value: PlaybackSettingsScope.perTrack, child: Text(context.tr("Per track"))),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            if (Platform.isAndroid || Platform.isWindows) ...[
              _SectionHeader(label: context.tr("PC Companion")),
              AnimatedBuilder(
                animation: Platform.isWindows ? CompanionServerService.instance : CompanionClientService.instance,
                builder: (context, _) {
                  final subtitle = Platform.isWindows
                      ? CompanionServerService.instance.running
                            ? '${CompanionServerService.instance.address}:${CompanionServerService.instance.port} · ${CompanionServerService.instance.connectedClientCount} connected'
                            : CompanionServerService.instance.error ??
                                  'Pair Android to control this PC over your local network'
                      : CompanionClientService.instance.connected
                      ? 'Connected to ${CompanionClientService.instance.pcName}'
                      : CompanionClientService.instance.hasSavedPairing
                      ? 'Reconnect to ${CompanionClientService.instance.pcName}'
                      : 'Scan a Resonance pairing code from Windows';
                  return _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Platform.isWindows ? Icons.computer_rounded : Icons.phone_android_rounded,
                        title: Platform.isWindows
                            ? context.tr("PC Companion Server")
                            : context.tr("PC Companion Remote"),
                        subtitle: context.trRendered(subtitle),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute<void>(builder: (_) => const CompanionScreen()),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],

            if (Platform.isAndroid || Platform.isWindows) ...[
              _SectionHeader(label: context.tr("YouTube Access")),
              AnimatedBuilder(
                animation: context.read<YoutubeAccessService>(),
                builder: (context, _) {
                  final access = context.read<YoutubeAccessService>();
                  return _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: access.isReady ? Icons.verified_user_rounded : Icons.shield_outlined,
                        title: context.tr("YouTube access"),
                        subtitle: _youtubeAccessSubtitle(context, access),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute<void>(builder: (_) => const YoutubeAccessScreen()),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],

            // ── Downloads ───────────────────────────────────────────
            _SectionHeader(label: context.tr("Downloads")),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.folder_open_rounded,
                  title: context.tr("Download Location"),
                  subtitle: _downloadDirectory == 'Default App Folder'
                      ? context.tr('Default App Folder')
                      : _downloadDirectory,
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: isDark ? const Color(0xFF475569) : const Color(0xFFABA8C8),
                  ),
                  onTap: _pickDownloadDirectory,
                ),
                _Divider(),
                _SettingsTile(
                  icon: Icons.history_rounded,
                  title: context.tr("Download History"),
                  subtitle: context.tr("Search downloaded tracks, failures, sources, and saved locations"),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: isDark ? const Color(0xFF475569) : const Color(0xFFABA8C8),
                  ),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(builder: (_) => const DownloadHistoryScreen()),
                  ),
                ),
                if (Platform.isAndroid || Platform.isWindows) ...[
                  _Divider(),
                  _SettingsTile(
                    icon: Icons.image_search_rounded,
                    title: context.tr("Fill Missing Covers"),
                    subtitle: _coverLookupRunning
                        ? context.trRendered(_coverLookupStatus)
                        : context.tr("Search YouTube for cover art for tracks missing embedded images"),
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
              _SectionHeader(label: context.tr("Hotkeys")),
              _SettingsCard(
                children: [
                  HotkeySettingsTile(
                    actionId: 'play_pause',
                    actionName: context.tr("Play / Pause"),
                    callback: handler.playPause,
                  ),
                  _Divider(),
                  HotkeySettingsTile(actionId: 'next', actionName: context.tr("Next Track"), callback: handler.next),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'previous',
                    actionName: context.tr("Previous Track"),
                    callback: handler.previous,
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'seek_backward',
                    actionName: context.tr("Seek Backward"),
                    callback: () async => handler.seekBySeconds(-(await handler.getSeekStepSeconds())),
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'seek_forward',
                    actionName: context.tr("Seek Forward"),
                    callback: () async => handler.seekBySeconds(await handler.getSeekStepSeconds()),
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'volume_up',
                    actionName: context.tr("Volume Up"),
                    callback: () => handler.incrementVolume(),
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'volume_down',
                    actionName: context.tr("Volume Down"),
                    callback: () => handler.decrementVolume(),
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'speed_up',
                    actionName: context.tr("Speed Up"),
                    callback: () => handler.incrementSpeed(),
                  ),
                  _Divider(),
                  HotkeySettingsTile(
                    actionId: 'speed_down',
                    actionName: context.tr("Speed Down"),
                    callback: () => handler.decrementSpeed(),
                  ),
                ],
              ),
            ],

            // ── System Tray (desktop only) ──────────────────────────
            if (_isDesktop) ...[
              _SectionHeader(label: context.tr("System Tray")),
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
              _SectionHeader(label: context.tr("Integrations")),
              _SettingsCard(
                children: [
                  _SettingsTile(
                    icon: Icons.discord,
                    title: context.tr("Discord Rich Presence"),
                    subtitle: context.tr("Show what you're listening to on Discord"),
                    trailing: Switch(value: _discordEnabled, onChanged: _toggleDiscord),
                  ),
                ],
              ),
            ],

            // ── Permissions (Android only) ──────────────────────────
            if (Platform.isAndroid) ...[
              _SectionHeader(label: context.tr("Permissions")),
              _SettingsCard(
                children: [
                  _SettingsTile(
                    icon: Icons.folder_open_rounded,
                    title: context.tr("Audio / Storage Access"),
                    subtitle: context.tr("Required to import music files"),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 16),
                    onTap: () async {
                      final granted = await StoragePermissionService.hasPermission();
                      if (granted) {
                        if (mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text(context.tr("Audio permission already granted ✓"))));
                        }
                      } else {
                        await StoragePermissionService.requestWithRationale(context);
                      }
                    },
                  ),
                ],
              ),
            ],

            // ── About ───────────────────────────────────────────────
            _SectionHeader(label: context.tr("About")),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.insights_outlined,
                  title: context.tr('Resonance Wrapped'),
                  subtitle: context.tr('Listening statistics and your recap'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(builder: (_) => const ListeningStatisticsScreen()),
                  ),
                ),
                _Divider(),
                _SettingsTile(
                  icon: Icons.backup_outlined,
                  title: context.tr('Backup and restore'),
                  subtitle: context.tr('Export settings or your complete library'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => const BackupScreen()));
                    if (!mounted) return;
                    await _loadPlaybackPreferences();
                    await _loadIntroPreference();
                    await _loadSeekStep();
                    if (_isDesktop) {
                      await _loadTrayMode();
                      await _loadDiscordPreference();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.auto_stories_rounded,
                  title: context.tr("Getting started tour"),
                  subtitle: context.tr("Review the controls and setup choices"),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (routeContext) => OnboardingScreen(onFinished: () => Navigator.pop(routeContext)),
                    ),
                  ),
                ),
                _Divider(),
                _SettingsTile(
                  icon: Icons.music_note_rounded,
                  title: context.tr("Resonance"),
                  subtitle: context.tr("A local music player with YouTube support"),
                ),
                _Divider(),
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  title: context.tr("Version"),
                  trailing: const AppVersionLabel(),
                  onTap: _handleVersionTap,
                ),
                _Divider(),
                _SettingsTile(
                  icon: Icons.system_update_rounded,
                  title: context.tr(
                    AppUpdateService.available.value == null ? 'Check for updates' : 'Update available',
                  ),
                  subtitle: AppUpdateService.available.value == null
                      ? context.tr('Compare with the latest GitHub release')
                      : context.tr('Version {0} is available', [AppUpdateService.available.value!.version]),
                  trailing: _checkingUpdate
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right_rounded),
                  onTap: _checkingUpdate ? null : _checkForUpdates,
                ),
                if (Platform.isAndroid) ...[
                  const AndroidUpdateStatus(),
                  _Divider(),
                  _SettingsTile(
                    icon: Icons.downloading_rounded,
                    title: context.tr("Background updates"),
                    subtitle: context.tr(
                      "Prepare updates discovered while Resonance is open. Android may ask you to approve installation.",
                    ),
                    trailing: Switch(value: _androidAutoUpdates, onChanged: _setAndroidAutoUpdates),
                  ),
                ],
              ],
            ),

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
      padding: const EdgeInsetsDirectional.fromSTEB(4, 20, 4, 8),
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

class _CustomColorPicker extends StatefulWidget {
  final Color initialColor;

  const _CustomColorPicker({required this.initialColor});

  @override
  State<_CustomColorPicker> createState() => _CustomColorPickerState();
}

class _CustomColorPickerState extends State<_CustomColorPicker> {
  late HSVColor _selected = HSVColor.fromColor(widget.initialColor);

  static const _presets = <(String, Color)>[
    ('Teal', Color(0xFF00BFA5)),
    ('Purple', Color(0xFF8B5CF6)),
    ('Blue', Color(0xFF3B82F6)),
    ('Green', Color(0xFF22C55E)),
    ('Gold', Color(0xFFF2C14E)),
    ('Orange', Color(0xFFF97316)),
    ('Rose', Color(0xFFF43F5E)),
    ('Pink', Color(0xFFEC4899)),
    ('Cyan', Color(0xFF06B6D4)),
    ('Indigo', Color(0xFF6366F1)),
    ('Red', Color(0xFFEF4444)),
    ('Slate', Color(0xFF64748B)),
  ];

  void _pickFromArea(Offset position, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    setState(() {
      _selected = _selected
          .withSaturation((position.dx / size.width).clamp(0.0, 1.0))
          .withValue((1 - position.dy / size.height).clamp(0.0, 1.0));
    });
  }

  void _pickHue(double x, double width) {
    if (width <= 0) return;
    setState(() => _selected = _selected.withHue((x / width * 359.9).clamp(0.0, 359.9)));
  }

  @override
  Widget build(BuildContext context) {
    final color = _selected.toColor();
    final outline = Theme.of(context).colorScheme.outline;
    final lightness = HSLColor.fromColor(color).lightness.clamp(0.08, 0.92);
    return AlertDialog(
      title: Text(context.tr("Choose your color")),
      content: SizedBox(
        width: 350,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.68),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  height: 52,
                  alignment: AlignmentDirectional.centerStart,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.22),
                    borderRadius: resonanceBorderRadius(context, 15),
                    border: Border.all(color: color),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(backgroundColor: color, radius: 12),
                      const SizedBox(width: 12),
                      Text(context.tr("Resonance"), style: TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(context.tr("Quick colors"), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 20,
                  runSpacing: 8,
                  children: [
                    for (final (name, preset) in _presets)
                      Tooltip(
                        message: name,
                        child: Semantics(
                          label: context.tr("{0} color", [context.tr(name)]),
                          button: true,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => setState(() => _selected = HSVColor.fromColor(preset)),
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: preset,
                                border: Border.all(
                                  color: preset == color ? Theme.of(context).colorScheme.onSurface : outline,
                                  width: preset == color ? 3 : 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(context.tr("Fine tune"), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(constraints.maxWidth, 116);
                    return GestureDetector(
                      key: const Key('custom-color-area'),
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => _pickFromArea(details.localPosition, size),
                      onPanStart: (details) => _pickFromArea(details.localPosition, size),
                      onPanUpdate: (details) => _pickFromArea(details.localPosition, size),
                      child: Container(
                        height: size.height,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: resonanceBorderRadius(context, 12),
                          border: Border.all(color: outline),
                        ),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [Colors.white, HSVColor.fromAHSV(1, _selected.hue, 1, 1).toColor()],
                                  ),
                                ),
                              ),
                            ),
                            const Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black],
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: (_selected.saturation * size.width - 9).clamp(0.0, size.width - 18),
                              top: ((1 - _selected.value) * size.height - 9).clamp(0.0, size.height - 18),
                              child: Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    return GestureDetector(
                      key: const Key('custom-color-hue'),
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => _pickHue(details.localPosition.dx, width),
                      onPanStart: (details) => _pickHue(details.localPosition.dx, width),
                      onPanUpdate: (details) => _pickHue(details.localPosition.dx, width),
                      child: SizedBox(
                        height: 28,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              height: 16,
                              decoration: BoxDecoration(
                                borderRadius: resonanceBorderRadius(context, 99),
                                gradient: const LinearGradient(
                                  colors: [
                                    Colors.red,
                                    Colors.yellow,
                                    Colors.green,
                                    Colors.cyan,
                                    Colors.blue,
                                    Colors.purple,
                                    Colors.red,
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              left: (_selected.hue / 360 * width - 10).clamp(0.0, width - 20),
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: HSVColor.fromAHSV(1, _selected.hue, 1, 1).toColor(),
                                  border: Border.all(color: Colors.white, width: 2),
                                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                Text(context.tr("Shade"), style: Theme.of(context).textTheme.titleSmall),
                Row(
                  children: [
                    Text(context.tr("Darker")),
                    Expanded(
                      child: Slider(
                        key: const Key('custom-color-shade'),
                        value: lightness,
                        min: 0.08,
                        max: 0.92,
                        onChanged: (value) => setState(() {
                          _selected = HSVColor.fromColor(HSLColor.fromColor(color).withLightness(value).toColor());
                        }),
                      ),
                    ),
                    Text(context.tr("Lighter")),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr("Cancel"))),
        FilledButton(onPressed: () => Navigator.pop(context, color), child: Text(context.tr("Use color"))),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: resonanceBorderRadius(context, 14),
        border: Border.all(color: Theme.of(context).colorScheme.outline, width: 1),
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
  final bool stackTrailingOnNarrow;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.stackTrailingOnNarrow = false,
  });

  @override
  Widget build(BuildContext context) {
    if (trailing != null && stackTrailingOnNarrow) {
      return LayoutBuilder(
        builder: (context, constraints) {
          if (!settingsTileShouldStackTrailing(constraints.maxWidth, stackTrailingOnNarrow)) {
            return _buildTile(context, trailing);
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTile(context, null),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(68, 0, 16, 10),
                child: Align(alignment: AlignmentDirectional.centerStart, child: trailing),
              ),
            ],
          );
        },
      );
    }
    return _buildTile(context, trailing);
  }

  Widget _buildTile(BuildContext context, Widget? tileTrailing) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: isDark ? primary.withValues(alpha: 0.12) : primary.withValues(alpha: 0.08),
          borderRadius: resonanceBorderRadius(context, 9),
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
      trailing: tileTrailing,
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: resonanceBorderRadius(context, 14)),
    );
  }
}

@visibleForTesting
bool settingsTileShouldStackTrailing(double availableWidth, bool enabled) => enabled && availableWidth < 440;

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 68),
      child: Divider(height: 1, thickness: 1, color: isDark ? const Color(0xFF1F1F30) : const Color(0xFFF0EFF5)),
    );
  }
}
