import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
import 'package:media_kit/media_kit.dart';
import 'package:just_audio/just_audio.dart' as ja;

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

//TODO: android; overflow and red flicker
//TODO: seek buttons (dont update)
//TODO: Taskbar buttons (dont work)
//TODO: album cover (downloads dont come with album cover)

bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    MediaKit.ensureInitialized();
  }
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
      'seek_backward': () async => handler.seekBySeconds(-(await handler.getSeekStepSeconds())),
      'seek_forward': () async => handler.seekBySeconds(await handler.getSeekStepSeconds()),
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
        onPlayPause: () => handler.playPause(),
      ).timeout(const Duration(seconds: 5), onTimeout: () => false),
    );
    unawaited(MediaKeysService.setupTaskbarButtons());
    handler.playbackState.listen((state) {
      unawaited(MediaKeysService.updateTaskbarPlaying(state.playing));
    });
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
  final TrayMode trayMode;

  _DesktopWindowHandler({required this.onShow, required this.onExit, required this.trayMode}) {
    windowManager.addListener(this);
    trayManager.addListener(this);
  }

  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
  }

  @override
  void onWindowClose() {
    switch (trayMode) {
      case TrayMode.closeToTray:
        unawaited(windowManager.hide());
        break;
      case TrayMode.minimizeToTray:
      case TrayMode.noTray:
        onExit();
        break;
    }
  }

  @override
  void onWindowMinimize() {
    if (trayMode == TrayMode.minimizeToTray) {
      unawaited(windowManager.hide());
    } else {
      unawaited(windowManager.minimize());
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
  List<int> playlistNumbers = [FileService.defaultPlaylistNumber];
  Map<int, String> playlistNames = {FileService.defaultPlaylistNumber: 'Playlist 1'};
  int activePlaylistNumber = FileService.defaultPlaylistNumber;
  bool isLoading = true;
  bool _isDragging = false;
  // Start behind an opaque launch gate. Preferences decide whether the gate
  // animates or is removed; the library is never painted for a stray frame.
  bool _showIntro = true;
  ja.AudioPlayer? _introPlayer;
  final ScrollController _playlistScrollController = ScrollController();
  int _trackPulse = 0;
  String? _pulsingTrackPath;
  bool _exitInProgress = false;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  final SettingsService _settingsService = SettingsService();
  _DesktopWindowHandler? _desktopHandler;

  @override
  void initState() {
    super.initState();
    _initIntro();
    _loadPlaylistFromDisk();
    if (_isDesktop) {
      _initDesktop();
    }
  }

  Future<void> _initIntro() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('intro_enabled') ?? true;
    if (!mounted) return;
    if (!enabled) {
      setState(() => _showIntro = false);
      return;
    }
    _introPlayer = ja.AudioPlayer();
    try {
      await _introPlayer!.setAsset('assets/audio/intro.mp3');
      unawaited(_introPlayer!.play());
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 3100), () {
      if (mounted) setState(() => _showIntro = false);
    });
  }

  Future<void> _initDesktop() async {
    final mode = await _settingsService.getTrayMode();
    if (!mounted) return;
    _desktopHandler = _DesktopWindowHandler(onShow: _showWindow, onExit: _exitApp, trayMode: mode);
    if (mode == TrayMode.noTray) {
      trayManager.removeListener(_desktopHandler!);
    }
  }

  @override
  void dispose() {
    unawaited(_introPlayer?.dispose());
    _playlistScrollController.dispose();
    _desktopHandler?.dispose();
    if (_isDesktop && Platform.isWindows) {
      unawaited(MediaKeysService.unregister());
    }
    super.dispose();
  }

  Future<void> _loadPlaylistFromDisk() async {
    final service = FileService();
    final numbers = await service.listPlaylistNumbers();
    final active = await service.getActivePlaylistNumber();
    final fileData = await service.readTextFromFile();
    final names = await service.getPlaylistNames();
    if (mounted) {
      setState(() {
        playlistNumbers = numbers;
        activePlaylistNumber = active;
        playlistNames = names;
        playlist = fileData.split('\n').where((line) => line.isNotEmpty).skip(1).toList();
        isLoading = false;
      });
    }
  }

  Future<void> _switchPlaylist(int number) async {
    setState(() => isLoading = true);
    await FileService().setActivePlaylistNumber(number);
    await _loadPlaylistFromDisk();
  }

  Future<void> _createPlaylist() async {
    final name = await _askForPlaylistName('New playlist', 'Playlist ${playlistNumbers.last + 1}');
    if (name == null) return;
    setState(() => isLoading = true);
    final number = await FileService().createNextPlaylist();
    await FileService().renamePlaylist(number, name);
    await _loadPlaylistFromDisk();
  }

  Future<String?> _askForPlaylistName(String title, String initialValue) async {
    final navigatorContext = _navigatorKey.currentState?.overlay?.context;
    if (navigatorContext == null) return null;
    final safeInitialValue = initialValue.length <= FileService.maxPlaylistNameLength
        ? initialValue
        : initialValue.substring(0, FileService.maxPlaylistNameLength);
    final controller = TextEditingController(text: safeInitialValue);
    final result = await showDialog<String>(
      context: navigatorContext,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: FileService.maxPlaylistNameLength,
          decoration: const InputDecoration(labelText: 'Playlist name'),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(dialogContext, value.trim());
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _renameActivePlaylist() async {
    await _renamePlaylist(activePlaylistNumber);
  }

  Future<void> _renamePlaylist(int number) async {
    final currentName = playlistNames[number] ?? 'Playlist $number';
    final name = await _askForPlaylistName('Rename playlist', currentName);
    if (name == null || name == currentName) return;
    await FileService().renamePlaylist(number, name);
    await _loadPlaylistFromDisk();
  }

  Future<void> _deleteActivePlaylist() async {
    await _deletePlaylist(activePlaylistNumber);
  }

  Future<void> _deletePlaylist(int number) async {
    if (playlistNumbers.length <= 1) return;
    final navigatorContext = _navigatorKey.currentState?.overlay?.context;
    if (navigatorContext == null) return;
    final name = playlistNames[number] ?? 'Playlist $number';
    final confirmed = await showDialog<bool>(
      context: navigatorContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text('Delete "$name"? Your audio files will not be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => isLoading = true);
    await FileService().deletePlaylist(number);
    await _loadPlaylistFromDisk();
  }

  Future<void> _showPlaylistActions(int number) async {
    final navigatorContext = _navigatorKey.currentState?.overlay?.context;
    if (navigatorContext == null) return;
    final name = playlistNames[number] ?? 'Playlist $number';
    final action = await showModalBottomSheet<_PlaylistActionType>(
      context: navigatorContext,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Playlist actions'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(sheetContext, _PlaylistActionType.rename),
            ),
            ListTile(
              enabled: playlistNumbers.length > 1,
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Delete'),
              onTap: playlistNumbers.length > 1 ? () => Navigator.pop(sheetContext, _PlaylistActionType.delete) : null,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    switch (action) {
      case _PlaylistActionType.rename:
        await _renamePlaylist(number);
        return;
      case _PlaylistActionType.delete:
        await _deletePlaylist(number);
        return;
      case null:
      case _PlaylistActionType.select:
      case _PlaylistActionType.create:
        return;
    }
  }

  Future<void> _revealCurrentTrack(String trackPath) async {
    if (trackPath.isEmpty) return;
    final service = FileService();
    final containingPlaylist = await service.findPlaylistContaining(trackPath);
    if (!mounted) return;
    if (containingPlaylist == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This track is not in any playlist.')));
      return;
    }
    if (containingPlaylist != activePlaylistNumber) {
      await _switchPlaylist(containingPlaylist);
    }
    final index = playlist.indexOf(trackPath);
    if (index < 0 || !mounted) return;
    setState(() {
      _pulsingTrackPath = trackPath;
      _trackPulse++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_playlistScrollController.hasClients) return;
      final position = _playlistScrollController.position;
      final target = (index * 72.0).clamp(position.minScrollExtent, position.maxScrollExtent);
      _playlistScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeInOutCubic,
      );
    });
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

  void _exitApp() {
    if (_exitInProgress) return;
    _exitInProgress = true;
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    unawaited(handler.saveState().timeout(const Duration(milliseconds: 500)).catchError((_) {}));
    unawaited(handler.pause().timeout(const Duration(milliseconds: 500)).catchError((_) {}));
    unawaited(handler.dispose().timeout(const Duration(seconds: 1)).catchError((_) {}));

    if (Platform.isWindows) {
      unawaited(MediaKeysService.unregister().timeout(const Duration(milliseconds: 500)).catchError((_) {}));
    }

    if (_isDesktop) {
      unawaited(trayManager.destroy());
      unawaited(windowManager.destroy());
    }

    // Native audio/Discord workers can keep the Windows runner alive after
    // the window is gone. Give fire-and-forget preference writes one event
    // turn, then terminate deterministically.
    Future.delayed(const Duration(milliseconds: 80), () => exit(0));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          navigatorKey: _navigatorKey,
          debugShowCheckedModeBanner: false,
          themeMode: themeProvider.themeMode,
          theme: _buildLightTheme(),
          darkTheme: _buildDarkTheme(),
          home: Builder(
            builder: (nestedContext) {
              return _showIntro
                  ? const _IntroOverlay()
                  : Scaffold(
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
                BoxShadow(color: const Color(0xFF7C3AED).withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 1),
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
              transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
              transitionDuration: const Duration(milliseconds: 200),
            ),
          ),
          icon: Icon(Icons.tune_rounded, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
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
                  child: CircularProgressIndicator(strokeWidth: 2, color: const Color(0xFF7C3AED)),
                ),
                const SizedBox(height: 16),
                Text(
                  'Loading library...',
                  style: TextStyle(color: const Color(0xFF64748B), fontSize: 13, letterSpacing: 0.3),
                ),
              ],
            ),
          )
        : TrackList(
            tracks: playlist,
            controller: _playlistScrollController,
            pulsingTrackPath: _pulsingTrackPath,
            pulse: _trackPulse,
            onTrackDeleted: (index, trackPath) async {
              setState(() => playlist.removeAt(index));
              await FileService().removeFromPlaylist(trackPath);
            },
            onReorder: _handleReorder,
          );
    final animatedTrackList = AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final offset = Tween<Offset>(begin: const Offset(0.025, 0), end: Offset.zero).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
      child: KeyedSubtree(key: ValueKey('$activePlaylistNumber-$isLoading'), child: trackListWidget),
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
                        child: animatedTrackList,
                      ),
                      DropOverlay(isDragging: _isDragging),
                    ],
                  ),
                )
              : animatedTrackList,
        ),

        // ── Player panel ──
        AlbumCover(onTap: _revealCurrentTrack),
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
            '${playlistNames[activePlaylistNumber] ?? 'Playlist $activePlaylistNumber'} - ${trackCount == 0 ? 'No tracks' : '$trackCount ${trackCount == 1 ? 'track' : 'tracks'}'}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          PopupMenuButton<_PlaylistMenuAction>(
            tooltip: 'Switch playlist',
            icon: const Icon(Icons.queue_music_rounded),
            onSelected: (action) {
              switch (action.type) {
                case _PlaylistActionType.select:
                  _switchPlaylist(action.playlistNumber!);
                  return;
                case _PlaylistActionType.create:
                  _createPlaylist();
                  return;
                case _PlaylistActionType.rename:
                  _renameActivePlaylist();
                  return;
                case _PlaylistActionType.delete:
                  _deleteActivePlaylist();
                  return;
              }
            },
            itemBuilder: (context) => [
              for (final number in playlistNumbers)
                PopupMenuItem<_PlaylistMenuAction>(
                  value: _PlaylistMenuAction.select(number),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPress: () {
                      Navigator.pop(context);
                      Future.microtask(() => _showPlaylistActions(number));
                    },
                    child: Row(
                      children: [
                        Icon(
                          number == activePlaylistNumber
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(playlistNames[number] ?? 'Playlist $number', overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem<_PlaylistMenuAction>(
                value: _PlaylistMenuAction(_PlaylistActionType.create),
                child: Row(children: [Icon(Icons.add_rounded, size: 18), SizedBox(width: 8), Text('New playlist')]),
              ),
              const PopupMenuItem<_PlaylistMenuAction>(
                value: _PlaylistMenuAction(_PlaylistActionType.rename),
                child: Row(children: [Icon(Icons.edit_rounded, size: 18), SizedBox(width: 8), Text('Rename current')]),
              ),
              PopupMenuItem<_PlaylistMenuAction>(
                value: const _PlaylistMenuAction(_PlaylistActionType.delete),
                enabled: playlistNumbers.length > 1,
                child: const Row(
                  children: [Icon(Icons.delete_outline_rounded, size: 18), SizedBox(width: 8), Text('Delete current')],
                ),
              ),
            ],
          ),
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

enum _PlaylistActionType { select, create, rename, delete }

class _PlaylistMenuAction {
  final _PlaylistActionType type;
  final int? playlistNumber;
  const _PlaylistMenuAction(this.type) : playlistNumber = null;
  const _PlaylistMenuAction.select(this.playlistNumber) : type = _PlaylistActionType.select;
}

class _IntroOverlay extends StatefulWidget {
  const _IntroOverlay();

  @override
  State<_IntroOverlay> createState() => _IntroOverlayState();
}

class _IntroOverlayState extends State<_IntroOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 3030))..forward();
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.72, end: 1.0).chain(CurveTween(curve: Curves.easeOutBack)), weight: 34),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 48),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.08).chain(CurveTween(curve: Curves.easeIn)), weight: 18),
    ]).animate(_controller);
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 12),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 72),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 16),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Opacity(
            opacity: _opacity.value,
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.05),
                  radius: 0.9,
                  colors: [Color(0xFF17131F), Color(0xFF08080C), Color(0xFF030305)],
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(child: CustomPaint(painter: _ResonancePainter(_controller.value, primary))),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.scale(
                          scale: _scale.value,
                          child: Container(
                            width: 92,
                            height: 92,
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              color: const Color(0xFF111118),
                              border: Border.all(color: primary.withValues(alpha: 0.38)),
                              boxShadow: [BoxShadow(color: primary.withValues(alpha: 0.22), blurRadius: 42)],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: Image.asset('assets/icon/icon.png', fit: BoxFit.cover),
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        Text(
                          'R E S O N A N C E',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 3.2,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ResonancePainter extends CustomPainter {
  final double progress;
  final Color color;
  const _ResonancePainter(this.progress, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = math.sqrt(size.width * size.width + size.height * size.height) * 0.55;
    for (final onset in const [0.08, 0.31, 0.52]) {
      final raw = ((progress - onset) / 0.46).clamp(0.0, 1.0);
      if (raw <= 0 || raw >= 1) continue;
      final wave = Curves.easeOutCubic.transform(raw);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 + (1 - raw) * 1.8
        ..color = color.withValues(alpha: (1 - raw) * 0.24)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
      canvas.drawCircle(center, 54 + maxRadius * wave, paint);
    }

    final breathe = 0.5 + 0.5 * math.sin(progress * math.pi * 6);
    canvas.drawCircle(
      center,
      118 + breathe * 8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.07 + breathe * 0.04),
    );
  }

  @override
  bool shouldRepaint(covariant _ResonancePainter oldDelegate) => oldDelegate.progress != progress;
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
    appBarTheme: const AppBarTheme(backgroundColor: bgBase, elevation: 0, surfaceTintColor: Colors.transparent),
    cardTheme: CardThemeData(
      color: bgSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: border, width: 1),
      ),
    ),
    listTileTheme: const ListTileThemeData(textColor: textPrimary, iconColor: textMuted),
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
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: primaryGlow)),
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
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? Colors.white : textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? primary : const Color(0xFF2D2D42),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? primary : textMuted,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? primary.withValues(alpha: 0.2) : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? primaryGlow : textMuted,
        ),
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
    appBarTheme: const AppBarTheme(backgroundColor: bgBase, elevation: 0, surfaceTintColor: Colors.transparent),
    cardTheme: CardThemeData(
      color: bgSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: border, width: 1),
      ),
    ),
    listTileTheme: const ListTileThemeData(textColor: textPrimary, iconColor: textMuted),
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
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: primaryGlow)),
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
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? Colors.white : textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? primary : border),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? primary : textMuted,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? primary.withValues(alpha: 0.1) : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? primary : textMuted,
        ),
        side: WidgetStateProperty.all(const BorderSide(color: border)),
      ),
    ),
  );
}
