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
import 'package:shared_preferences/shared_preferences.dart';

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

//TODO: one window limit
//TODO: Iconize
//TODO: fade-in and out in settings
//TODO: android discord rich presence (separate future TODO — needs different package)
//TODO: Add youtube support with playlists
//TODO: themes
//TODO: taskbar
//TODO: Revamp the UI

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Window manager is desktop-only
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
    ),
  );

  // Hotkeys are desktop-only (hotkey_manager doesn't support Android)
  if (_isDesktop) {
    await HotkeyService.init({
      'play_pause': handler.playPause,
      'next': handler.next,
      'previous': handler.previous,
      'volume_up': handler.incrementVolume,
      'volume_down': handler.decrementVolume,
    });
  }

  // System tray is desktop-only
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
    DiscordPresenceService().initialize(); // no await
  }

  runApp(
    Provider<PlayerHandler>.value(
      value: handler,
      child: MainApp(handler: handler),
    ),
  );

  // ---------------------------------------------------------------
  // Hardware Media Next/Previous keys (Windows-only native plugin).
  // See original comment for full context. Guard is already here.
  // ---------------------------------------------------------------
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

class _MainAppState extends State<MainApp> with WindowListener, TrayListener {
  List<String> playlist = [];
  bool isLoading = true;
  bool _isDragging = false;
  TrayMode _currentTrayMode = TrayMode.closeToTray;
  final SettingsService _settingsService = SettingsService();

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      _loadTrayModeAndSetup();
    }
    _loadPlaylistFromDisk();
  }

  Future<void> _loadTrayModeAndSetup() async {
    final mode = await _settingsService.getTrayMode();
    if (mounted) {
      setState(() {
        _currentTrayMode = mode;
      });
      // Register window listener (desktop-only)
      windowManager.addListener(this);
      // Register tray listener only if mode != noTray
      if (_currentTrayMode != TrayMode.noTray) {
        trayManager.addListener(this);
      }
    }
  }

  @override
  void dispose() {
    if (_isDesktop) {
      windowManager.removeListener(this);
      if (_currentTrayMode != TrayMode.noTray) {
        trayManager.removeListener(this);
      }
      // MediaKeysService is Windows-only; unregister only on Windows
      if (Platform.isWindows) {
        unawaited(MediaKeysService.unregister());
      }
    }
    super.dispose();
  }

  Future<void> _loadPlaylistFromDisk() async {
    String fileData = await FileService().readTextFromFile();
    if (mounted) {
      setState(() {
        playlist = fileData.split("\n").where((line) => line.isNotEmpty).skip(1).toList();
        isLoading = false;
      });
    }
  }

  // ---------- Reorder callback ----------
  void _handleReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    setState(() {
      final item = playlist.removeAt(oldIndex);
      playlist.insert(newIndex, item);
    });
    // Persist to disk so PlayerHandler.next()/previous() see the new order
    await FileService().reorderPlaylist(playlist);
  }

  // ---------- WindowListener (desktop-only, safe to have as mixin stubs on Android) ----------
  @override
  void onWindowClose() async {
    final mode = await _settingsService.getTrayMode();
    switch (mode) {
      case TrayMode.closeToTray:
        await windowManager.hide();
        break;
      case TrayMode.minimizeToTray:
      case TrayMode.noTray:
        _exitApp();
        break;
    }
  }

  @override
  void onWindowMinimize() async {
    final mode = await _settingsService.getTrayMode();
    if (mode == TrayMode.minimizeToTray) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
  }

  // ---------- TrayListener (desktop-only) ----------
  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') {
      _showWindow();
    } else if (menuItem.key == 'exit') {
      _exitApp();
    }
  }

  // ---------- Helpers ----------
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

    Future.delayed(const Duration(milliseconds: 200), () {
      exit(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (nestedContext) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Resonance'),
              centerTitle: true,
              actions: [
                IconButton(
                  onPressed: () =>
                      Navigator.push(nestedContext, MaterialPageRoute(builder: (context) => SettingsScreen())),
                  icon: const Icon(Icons.settings),
                ),
              ],
            ),
            body: _buildBody(),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    final trackListWidget = isLoading
        ? const Center(child: CircularProgressIndicator())
        : TrackList(
            tracks: playlist,
            onTrackDeleted: (index, trackPath) async {
              setState(() {
                playlist.removeAt(index);
              });
              await FileService().removeFromPlaylist(trackPath);
            },
            onReorder: _handleReorder,
          );

    return Column(
      children: [
        ImportTrackButton(
          onFileAdded: (String newPath) {
            setState(() {
              playlist.add(newPath);
            });
          },
        ),
        const Divider(),
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
                          setState(() {
                            playlist.add(newPath);
                          });
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