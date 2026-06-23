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

// ── Desktop window/tray listener — only instantiated on desktop ───────────────
// Keeping WindowListener and TrayListener in a separate class means Android
// never touches window_manager or tray_manager at all, even at the mixin level.
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
    // Load tray mode first so we only attach tray listener when needed
    final mode = await _settingsService.getTrayMode();
    if (!mounted) return;
    _desktopHandler = _DesktopWindowHandler(
      onShow: _showWindow,
      onExit: _exitApp,
      settingsService: _settingsService,
    );
    // If noTray mode, don't listen to tray events
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
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF5F5F5),
            cardColor: Colors.white,
            iconTheme: const IconThemeData(color: Colors.black),
            colorScheme: const ColorScheme.light(
              primary: Colors.deepPurple,
              secondary: Colors.deepPurpleAccent,
            ),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF1E1E1E),
            cardColor: const Color(0xFF2C2C2C),
            iconTheme: const IconThemeData(color: Colors.white),
            colorScheme: const ColorScheme.dark(
              primary: Colors.deepPurple,
              secondary: Colors.deepPurpleAccent,
              surface: Color(0xFF2C2C2C),
            ),
          ),
          home: Builder(
            builder: (nestedContext) {
              return Scaffold(
                appBar: AppBar(
                  backgroundColor: Theme.of(nestedContext).scaffoldBackgroundColor,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  surfaceTintColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  title: const Text('Resonance'),
                  centerTitle: true,
                  actions: [
                    IconButton(
                      onPressed: () => Navigator.push(
                          nestedContext,
                          MaterialPageRoute(
                              builder: (context) => SettingsScreen())),
                      icon: const Icon(Icons.settings),
                    ),
                  ],
                ),
                body: _buildBody(nestedContext),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext nestedContext) {
    final trackListWidget = isLoading
        ? const Center(child: CircularProgressIndicator())
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
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ImportTrackButton(
              onFileAdded: (String newPath) {
                setState(() => playlist.add(newPath));
              },
            ),
            IconButton(
              icon: const Icon(Icons.download_outlined),
              onPressed: () {
                showDialog(
                  context: nestedContext,
                  builder: (context) => _isDesktop
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
        AlbumCover(),
        PlayerControls(),
      ],
    );
  }
}