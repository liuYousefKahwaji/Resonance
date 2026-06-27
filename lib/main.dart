import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/screens/settings/settings_screen.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:resonance/widgets/library/import_track_button.dart';
import 'package:resonance/widgets/library/track_list.dart';
import 'package:resonance/widgets/player/album_cover.dart';
import 'package:resonance/widgets/player/player_controls.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/widgets/youtube/android_youtube.dart';
import 'package:resonance/widgets/youtube/windows_youtube.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:metadata_god/metadata_god.dart';

// Desktop-only imports — guarded at runtime with Platform checks
import 'package:resonance/platform/desktop/hotkey_service.dart'
    if (dart.library.html) 'package:resonance/platform/desktop/hotkey_service_stub.dart';
import 'package:resonance/platform/desktop/tray_settings.dart';
import 'package:resonance/platform/desktop/tray_service.dart';
import 'package:resonance/services/media_keys_service.dart';
import 'package:resonance/widgets/library/drop_overlay.dart';
import 'package:resonance/widgets/library/drop_zone.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:desktop_drop/desktop_drop.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MetadataGod.initialize();

  if (_isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }

  final session = await AudioSession.instance;
  await session.configure(AudioSessionConfiguration.music());

  final handler = await AudioService.init(
    builder: () => PlayerHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.resonance.audio',
      androidNotificationChannelName: 'Resonance Playback',
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidStopForegroundOnPause: false,
    ),
  );

  if (_isDesktop) {
    await HotkeyService.init({
      'play_pause': handler.playPause,
      'next': handler.next,
      'previous': handler.previous,
      'volume_up': handler.incrementVolume,
      'volume_down': handler.decrementVolume,
      'speed_up': handler.incrementSpeed,
      'speed_down': handler.decrementSpeed,
    });
  }

  if (_isDesktop) {
    final settingsService = SettingsService();
    final trayMode = await settingsService.getTrayMode();
    if (trayMode != TrayMode.noTray) {
      await TrayService.init();
    }
  }

  final prefs = await SharedPreferences.getInstance();
  final discordEnabled = prefs.getBool('discord_enabled') ?? true;
  if (_isDesktop && discordEnabled) {
    DiscordPresenceService().initialize();
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<PlayerHandler>.value(value: handler),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: MainApp(handler: handler),
    ),
  );

  if (Platform.isWindows) {
    unawaited(
      MediaKeysService.register(
        onNext: () => handler.next(),
        onPrevious: () => handler.previous(),
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      ),
    );
  }
}

class MainApp extends StatefulWidget {
  final PlayerHandler handler;
  const MainApp({super.key, required this.handler});

  @override
  State<MainApp> createState() => _MainAppState();
}

// ── Desktop window/tray listener ──────────────────────────────────────────────
class _DesktopWindowHandler with WindowListener, TrayListener {
  final VoidCallback onShow;
  final VoidCallback onExit;
  final SettingsService settingsService;

  _DesktopWindowHandler({
    required this.onShow,
    required this.onExit,
    required this.settingsService,
  }) {
    windowManager.addListener(this);
    trayManager.addListener(this);
  }

  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
  }

  @override
  void onWindowClose() async {
    final mode = await settingsService.getTrayMode();
    switch (mode) {
      case TrayMode.closeToTray:
        await windowManager.hide();
        break;
      case TrayMode.minimizeToTray:
      case TrayMode.noTray:
        onExit();
        break;
    }
  }

  @override
  void onWindowMinimize() async {
    final mode = await settingsService.getTrayMode();
    if (mode == TrayMode.minimizeToTray) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
  }

  @override
  void onTrayIconMouseDown() => onShow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') {
      onShow();
    } else if (menuItem.key == 'exit') {
      onExit();
    }
  }
}

class _MainAppState extends State<MainApp> {
  List<String> playlist = [];
  bool isLoading = true;
  bool _isDragging = false;

  final SettingsService _settingsService = SettingsService();
  _DesktopWindowHandler? _desktopHandler;

  @override
  void initState() {
    super.initState();
    _loadPlaylistFromDisk();
    if (_isDesktop) {
      _initDesktop();
    }
  }

  Future<void> _initDesktop() async {
    final mode = await _settingsService.getTrayMode();
    if (!mounted) return;
    _desktopHandler = _DesktopWindowHandler(
      onShow: _showWindow,
      onExit: _exitApp,
      settingsService: _settingsService,
    );
    if (mode == TrayMode.noTray) {
      trayManager.removeListener(_desktopHandler!);
    }
  }

  @override
  void dispose() {
    _desktopHandler?.dispose();
    if (_isDesktop && Platform.isWindows) {
      unawaited(MediaKeysService.unregister());
    }
    super.dispose();
  }

  Future<void> _loadPlaylistFromDisk() async {
    final fileData = await FileService().readTextFromFile();
    if (mounted) {
      setState(() {
        playlist = fileData
            .split('\n')
            .where((line) => line.isNotEmpty)
            .skip(1)
            .toList();
        isLoading = false;
      });
    }
  }

  void _handleReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    setState(() {
      final item = playlist.removeAt(oldIndex);
      playlist.insert(newIndex, item);
    });
    await FileService().reorderPlaylist(playlist);
  }

  void _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _exitApp() async {
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    await handler.pause();
    await handler.dispose();

    if (Platform.isWindows) {
      await MediaKeysService.unregister();
    }

    if (_isDesktop) {
      unawaited(trayManager.destroy());
      unawaited(windowManager.destroy());
    }

    Future.delayed(const Duration(milliseconds: 200), () => exit(0));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          themeMode: themeProvider.themeMode,
          theme: _buildLightTheme(),
          darkTheme: _buildDarkTheme(),
          home: Builder(
            builder: (nestedContext) {
              return Scaffold(
                backgroundColor: Theme.of(nestedContext).scaffoldBackgroundColor,
                appBar: _buildAppBar(nestedContext),
                body: _buildBody(nestedContext),
              );
            },
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppBar(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF7C3AED),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7C3AED).withValues(alpha: 0.6),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Resonance',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A),
            ),
          ),
        ],
      ),
      centerTitle: true,
      actions: [
        IconButton(
          onPressed: () => Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => const SettingsScreen(),
              transitionsBuilder: (_, anim, __, child) =>
                  FadeTransition(opacity: anim, child: child),
              transitionDuration: const Duration(milliseconds: 200),
            ),
          ),
          icon: Icon(
            Icons.tune_rounded,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
          ),
          tooltip: 'Settings',
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext nestedContext) {
    final trackListWidget = isLoading
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: const Color(0xFF7C3AED),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Loading library...',
                  style: TextStyle(
                    color: const Color(0xFF64748B),
                    fontSize: 13,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          )
        : TrackList(
            tracks: playlist,
            onTrackDeleted: (index, trackPath) async {
              setState(() => playlist.removeAt(index));
              await FileService().removeFromPlaylist(trackPath);
            },
            onReorder: _handleReorder,
          );

    return Column(
      children: [
        // ── Toolbar row ──
        _buildToolbar(nestedContext),

        // ── Track list ──
        Expanded(
          child: _isDesktop
              ? DropTarget(
                  onDragEntered: (_) => setState(() => _isDragging = true),
                  onDragExited: (_) => setState(() => _isDragging = false),
                  onDragDone: (_) => setState(() => _isDragging = false),
                  child: Stack(
                    children: [
                      DropZone(
                        onFileAdded: (newPath) {
                          setState(() => playlist.add(newPath));
                        },
                        child: trackListWidget,
                      ),
                      DropOverlay(isDragging: _isDragging),
                    ],
                  ),
                )
              : trackListWidget,
        ),

        // ── Player panel ──
        AlbumCover(),
        PlayerControls(),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trackCount = playlist.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
      child: Row(
        children: [
          Text(
            trackCount == 0
                ? 'No tracks'
                : '$trackCount ${trackCount == 1 ? 'track' : 'tracks'}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          // Import button — renders its own IconButton; theme handles styling
          ImportTrackButton(
            onFileAdded: (String newPath) {
              setState(() => playlist.add(newPath));
            },
          ),
          // Download from YouTube
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Download from YouTube',
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => _isDesktop
                    ? WindowsYoutube(
                        onFileAdded: (String newPath) {
                          setState(() => playlist.add(newPath));
                        },
                      )
                    : AndroidYoutube(
                        onFileAdded: (String newPath) {
                          setState(() => playlist.add(newPath));
                        },
                      ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ── Theme builders ─────────────────────────────────────────────────────────────

ThemeData _buildDarkTheme() {
  const primary = Color(0xFF7C3AED);
  const primaryGlow = Color(0xFFA855F7);
  const bgBase = Color(0xFF0D0D14);
  const bgSurface = Color(0xFF1A1A2A);
  const bgElevated = Color(0xFF242436);
  const textPrimary = Color(0xFFE2E8F0);
  const textMuted = Color(0xFF64748B);
  const border = Color(0xFF2D2D42);

  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bgBase,
    cardColor: bgSurface,
    colorScheme: const ColorScheme.dark(
      primary: primary,
      secondary: primaryGlow,
      surface: bgSurface,
      onSurface: textPrimary,
      onSurfaceVariant: textMuted,
      outline: border,
      surfaceContainerHigh: bgElevated,
      surfaceContainerHighest: Color(0xFF2D2D42),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: bgBase,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: bgSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: border, width: 1),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      textColor: textPrimary,
      iconColor: textMuted,
    ),
    iconTheme: const IconThemeData(color: textMuted),
    dialogTheme: DialogThemeData(
      backgroundColor: bgSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: border, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bgElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: primary, width: 1.5),
      ),
      labelStyle: const TextStyle(color: textMuted),
      hintStyle: const TextStyle(color: Color(0xFF475569)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primaryGlow,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: primary,
      inactiveTrackColor: const Color(0xFF2D2D42),
      thumbColor: primary,
      overlayColor: primary.withValues(alpha: 0.15),
      trackHeight: 3,
    ),
    dividerColor: border,
    dividerTheme: const DividerThemeData(color: border, thickness: 1),
    textTheme: const TextTheme(
      titleLarge: TextStyle(color: textPrimary, fontWeight: FontWeight.w700, fontSize: 18),
      titleMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.w600, fontSize: 15),
      bodyMedium: TextStyle(color: textPrimary, fontSize: 14),
      bodySmall: TextStyle(color: textMuted, fontSize: 12),
      labelSmall: TextStyle(color: textMuted, fontSize: 11, letterSpacing: 0.5),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: bgElevated,
      contentTextStyle: const TextStyle(color: textPrimary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? Colors.white : textMuted),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? primary : const Color(0xFF2D2D42)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? primary : textMuted),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primary.withValues(alpha: 0.2) : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primaryGlow : textMuted),
        side: WidgetStateProperty.all(const BorderSide(color: border)),
      ),
    ),
  );
}

ThemeData _buildLightTheme() {
  const primary = Color(0xFF6D28D9);
  const primaryGlow = Color(0xFF7C3AED);
  const bgBase = Color(0xFFF0EFF5);
  const bgSurface = Color(0xFFFFFFFF);
  const bgElevated = Color(0xFFF7F6FC);
  const textPrimary = Color(0xFF0F172A);
  const textMuted = Color(0xFF64748B);
  const border = Color(0xFFDDD9F3);

  return ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: bgBase,
    cardColor: bgSurface,
    colorScheme: const ColorScheme.light(
      primary: primary,
      secondary: primaryGlow,
      surface: bgSurface,
      onSurface: textPrimary,
      onSurfaceVariant: textMuted,
      outline: border,
      surfaceContainerHigh: bgElevated,
      surfaceContainerHighest: Color(0xFFEEECF8),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: bgBase,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: bgSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: border, width: 1),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      textColor: textPrimary,
      iconColor: textMuted,
    ),
    iconTheme: const IconThemeData(color: textMuted),
    dialogTheme: DialogThemeData(
      backgroundColor: bgSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: border, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bgElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: primary, width: 1.5),
      ),
      labelStyle: const TextStyle(color: textMuted),
      hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primaryGlow,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: primary,
      inactiveTrackColor: border,
      thumbColor: primary,
      overlayColor: primary.withValues(alpha: 0.12),
      trackHeight: 3,
    ),
    dividerColor: border,
    dividerTheme: const DividerThemeData(color: border, thickness: 1),
    textTheme: const TextTheme(
      titleLarge: TextStyle(color: textPrimary, fontWeight: FontWeight.w700, fontSize: 18),
      titleMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.w600, fontSize: 15),
      bodyMedium: TextStyle(color: textPrimary, fontSize: 14),
      bodySmall: TextStyle(color: textMuted, fontSize: 12),
      labelSmall: TextStyle(color: textMuted, fontSize: 11, letterSpacing: 0.5),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: bgElevated,
      contentTextStyle: const TextStyle(color: textPrimary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? Colors.white : textMuted),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? primary : border),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? primary : textMuted),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primary.withValues(alpha: 0.1) : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primary : textMuted),
        side: WidgetStateProperty.all(const BorderSide(color: border)),
      ),
    ),
  );
}