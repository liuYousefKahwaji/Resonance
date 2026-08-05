import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/platform/android/android_entrypoint_service.dart';
import 'package:resonance/screens/settings/settings_screen.dart';
import 'package:resonance/screens/external_playlist/external_playlist_import_screen.dart';
import 'package:resonance/screens/playlist_transfer/playlist_export_screen.dart';
import 'package:resonance/screens/playlist_transfer/playlist_import_screen.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/playlist_transfer_export_service.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:resonance/services/android_shared_content_service.dart';
import 'package:resonance/services/android_playback_widget_service.dart';
import 'package:resonance/widgets/library/import_track_button.dart';
import 'package:resonance/widgets/library/track_list.dart';
import 'package:resonance/widgets/player/album_cover.dart';
import 'package:resonance/widgets/player/player_controls.dart';
import 'package:resonance/widgets/player/upcoming_queue.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/app/now_playing_navigation.dart';
import 'package:resonance/screens/youtube/youtube_search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:media_kit/media_kit.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path/path.dart' as p;
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/music_recognition/music_recognition_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/track_selection_service.dart';
import 'package:resonance/services/companion/companion_client_service.dart';
import 'package:resonance/services/companion/companion_server_service.dart';
import 'package:resonance/services/scroll_effects_preferences.dart';
import 'package:resonance/widgets/music_recognition/music_recognition_dialog.dart';

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
const _windowsShutdownChannel = MethodChannel('resonance/windows_shutdown');

void _shutdownLog(String event) {
  debugPrint('[Resonance shutdown ${DateTime.now().toIso8601String()}] $event');
}

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
  final themeProvider = ThemeProvider();
  if (Platform.isAndroid) {
    unawaited(AndroidPlaybackWidgetService.instance.attach(handler, themeProvider));
  }
  await ScrollEffectsPreferences.instance.initialize();
  if (Platform.isWindows) {
    unawaited(CompanionServerService.instance.initialize(handler));
  } else if (Platform.isAndroid) {
    unawaited(CompanionClientService.instance.initialize());
  }

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
    if (Platform.isWindows) {
      try {
        await _windowsShutdownChannel.invokeMethod<void>('configure', {
          'closeToTray': trayMode == TrayMode.closeToTray,
        });
      } catch (error) {
        _shutdownLog('native close-mode configuration failed: $error');
      }
    }
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
        ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
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
    handler.playbackVisualNotifier.addListener(() {
      unawaited(MediaKeysService.updateTaskbarPlaying(handler.playbackVisualNotifier.value.playing));
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
  final VoidCallback onSuspend;
  final VoidCallback onResume;
  final TrayMode trayMode;

  _DesktopWindowHandler({
    required this.onShow,
    required this.onExit,
    required this.onSuspend,
    required this.onResume,
    required this.trayMode,
  }) {
    windowManager.addListener(this);
    trayManager.addListener(this);
  }

  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
  }

  @override
  void onWindowClose() {
    _shutdownLog('onWindowClose fired (trayMode: ${trayMode.name})');
    switch (trayMode) {
      case TrayMode.closeToTray:
        onSuspend();
        unawaited(windowManager.hide());
        _shutdownLog('close-to-tray window hide requested');
        break;
      case TrayMode.minimizeToTray:
      case TrayMode.noTray:
        onExit();
        break;
    }
  }

  @override
  void onWindowMinimize() {
    onSuspend();
    if (trayMode == TrayMode.minimizeToTray) {
      unawaited(windowManager.hide());
    } else {
      unawaited(windowManager.minimize());
    }
  }

  @override
  void onWindowRestore() => onResume();

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
  int _artworkRevision = 0;
  int? _pulsingTrackIndex;
  final Map<({int playlistNumber, int index}), GlobalKey> _trackItemKeys = {};
  bool _exitInProgress = false;
  bool _uiVisible = true;
  bool _queueDrawerOpen = false;
  final Set<int> _selectedTrackIndices = <int>{};
  bool? _windowsChromeEnabled;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  bool _handlingAndroidAction = false;

  final SettingsService _settingsService = SettingsService();
  _DesktopWindowHandler? _desktopHandler;

  @override
  void initState() {
    super.initState();
    _initIntro();
    _loadPlaylistFromDisk();
    if (Platform.isAndroid) unawaited(AndroidEntrypointService.initialize(_handleAndroidAction));
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

  Future<void> _dismissIntro() async {
    await _introPlayer?.stop();
    if (mounted && _showIntro) setState(() => _showIntro = false);
  }

  Future<void> _initDesktop() async {
    final mode = await _settingsService.getTrayMode();
    if (!mounted) return;
    _desktopHandler = _DesktopWindowHandler(
      onShow: _showWindow,
      onExit: _exitApp,
      onSuspend: _suspendUi,
      onResume: _resumeUi,
      trayMode: mode,
    );
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
      _trackItemKeys.clear();
      setState(() {
        playlistNumbers = numbers;
        activePlaylistNumber = active;
        playlistNames = names;
        playlist = fileData.split('\n').where((line) => line.isNotEmpty).skip(1).toList();
        _selectedTrackIndices.clear();
        isLoading = false;
      });
      widget.handler.playbackModeRevision.value++;
    }
  }

  Future<void> _switchPlaylist(int number) async {
    setState(() => isLoading = true);
    await FileService().setActivePlaylistNumber(number);
    if (widget.handler.getShuffleMode()) await widget.handler.shuffleQueue();
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

  Future<void> _transferCurrentPlaylist(BuildContext navigatorContext) async {
    if (playlist.isEmpty) {
      ScaffoldMessenger.of(
        navigatorContext,
      ).showSnackBar(const SnackBar(content: Text('Add at least one track before transferring this playlist.')));
      return;
    }
    PlaylistSourceScan scan;
    _showTransferProgress(navigatorContext, 'Scanning playlist and checking saved sources…');
    try {
      scan = await const PlaylistTransferExportService().scanPlaylist(
        playlistNames[activePlaylistNumber] ?? 'Playlist $activePlaylistNumber',
        List<String>.from(playlist),
      );
    } catch (error) {
      if (mounted) Navigator.of(navigatorContext, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(
          navigatorContext,
        ).showSnackBar(SnackBar(content: Text('Could not prepare transfer: $error')));
      }
      return;
    }
    if (mounted) Navigator.of(navigatorContext, rootNavigator: true).pop();
    if (!mounted) return;

    if (scan.unresolved.isNotEmpty) {
      final completed = await Navigator.push<bool>(
        navigatorContext,
        MaterialPageRoute(builder: (_) => PlaylistSourceResolutionScreen(scan: scan)),
      );
      if (completed != true || !mounted) return;
    }

    final resolved = scan.resolvedVideoIds.length;
    final confirmed = await showDialog<bool>(
      context: navigatorContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Generate playlist QR codes?'),
        content: Text(
          'Playlist: ${scan.playlistName}\n\n'
          'Tracks in playlist: ${scan.playlistTracks.length}\n'
          'Sources resolved: $resolved\n'
          'Skipped: ${scan.skippedEntryCount}\n\n'
          '${scan.skippedEntryCount == 0 ? 'Every playlist entry will be transferred.' : 'Skipped tracks will not be transferred.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: resolved == 0 ? null : () => Navigator.pop(dialogContext, true),
            child: const Text('Generate QR Codes'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _showTransferProgress(navigatorContext, 'Compressing playlist and generating QR data…');
    try {
      final transfer = await compute(_encodeTransferManifest, scan.createManifest().toJson());
      if (mounted) Navigator.of(navigatorContext, rootNavigator: true).pop();
      if (!mounted) return;
      await Navigator.push(
        navigatorContext,
        MaterialPageRoute(builder: (_) => PlaylistQrDisplayScreen(transfer: transfer)),
      );
    } catch (error) {
      if (mounted) Navigator.of(navigatorContext, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(
          navigatorContext,
        ).showSnackBar(SnackBar(content: Text('Could not generate QR codes: $error')));
      }
    }
  }

  Future<void> _importTransferredPlaylist(BuildContext navigatorContext) async {
    final imported = await Navigator.push<bool>(
      navigatorContext,
      MaterialPageRoute(builder: (_) => const PlaylistImportScreen()),
    );
    if (imported == true && mounted) await _loadPlaylistFromDisk();
  }

  Future<void> _importExternalPlaylist(BuildContext navigatorContext) async {
    final imported = await Navigator.push<bool>(
      navigatorContext,
      MaterialPageRoute(builder: (_) => const ExternalPlaylistImportScreen()),
    );
    if (imported == true && mounted) await _loadPlaylistFromDisk();
  }

  void _showTransferProgress(BuildContext context, String message) {
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 18),
                Expanded(child: Text(message)),
              ],
            ),
          ),
        ),
      ),
    );
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
    final containingPlaylist = await service.findPlaylistContaining(
      trackPath,
      preferredPlaylistNumber: activePlaylistNumber,
    );
    if (!mounted) return;
    if (containingPlaylist == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This track is not in any playlist.')));
      return;
    }
    if (containingPlaylist != activePlaylistNumber) {
      await _switchPlaylist(containingPlaylist);
    }
    final index = service.findTrackIndex(playlist, trackPath);
    if (index < 0 || !mounted) return;
    await _scrollToTrackIndex(index);
    if (!mounted) return;
    setState(() {
      _pulsingTrackIndex = index;
      _trackPulse++;
    });
  }

  GlobalKey _trackItemKey(int playlistNumber, int index) => _trackItemKeys.putIfAbsent((
    playlistNumber: playlistNumber,
    index: index,
  ), () => GlobalKey(debugLabel: 'playlist-$playlistNumber-track-$index'));

  Future<void> _scrollToTrackIndex(int index) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_playlistScrollController.hasClients) return;
    final position = _playlistScrollController.position;
    final centeredTarget =
        TrackList.topPadding + index * TrackList.itemExtent - (position.viewportDimension - TrackList.itemExtent) / 2;
    await _playlistScrollController.animateTo(
      centeredTarget.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
    );
    await WidgetsBinding.instance.endOfFrame;
    final targetContext = _trackItemKey(activePlaylistNumber, index).currentContext;
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _handleReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    setState(() {
      final item = playlist.removeAt(oldIndex);
      playlist.insert(newIndex, item);
      _trackItemKeys.clear();
      _pulsingTrackIndex = null;
      _selectedTrackIndices.clear();
    });
    await FileService().reorderPlaylist(playlist);
    widget.handler.playbackModeRevision.value++;
  }

  void _toggleTrackSelection(int index) {
    if (index < 0 || index >= playlist.length) return;
    setState(() {
      if (!_selectedTrackIndices.add(index)) _selectedTrackIndices.remove(index);
    });
  }

  void _selectAllTracks() {
    setState(() {
      _selectedTrackIndices
        ..clear()
        ..addAll(List<int>.generate(playlist.length, (index) => index));
    });
  }

  void _clearTrackSelection() {
    if (_selectedTrackIndices.isEmpty) return;
    setState(_selectedTrackIndices.clear);
  }

  Future<int?> _pickSelectionTarget(String actionLabel) async {
    final targets = playlistNumbers.where((number) => number != activePlaylistNumber).toList(growable: false);
    final navigatorContext = _navigatorKey.currentState?.overlay?.context;
    if (navigatorContext == null) return null;
    if (targets.isEmpty) {
      ScaffoldMessenger.of(
        navigatorContext,
      ).showSnackBar(const SnackBar(content: Text('Create another playlist first.')));
      return null;
    }
    return showModalBottomSheet<int>(
      context: navigatorContext,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: Text('$actionLabel ${_selectedTrackIndices.length} selected tracks'),
              subtitle: const Text('Choose a destination playlist'),
            ),
            for (final number in targets)
              ListTile(
                leading: const Icon(Icons.playlist_play_rounded),
                title: Text(playlistNames[number] ?? 'Playlist $number'),
                onTap: () => Navigator.pop(sheetContext, number),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _copyOrMoveSelected({required bool move}) async {
    final target = await _pickSelectionTarget(move ? 'Move' : 'Copy');
    if (target == null || !mounted) return;
    final indices = validTrackSelectionIndices(playlist.length, _selectedTrackIndices);
    final tracks = selectedTracks(playlist, indices);
    if (tracks.isEmpty) return;
    final service = FileService();
    try {
      for (final track in tracks) {
        await service.writeTextToPlaylist(target, '$track\n', append: true);
      }
      if (move) {
        final remaining = tracksWithoutSelection(playlist, indices);
        await service.reorderPlaylist(remaining);
        for (final track in tracks) {
          widget.handler.removeTrackFromActivePlaybackOrder(track);
        }
        if (mounted) {
          setState(() {
            playlist = remaining;
            _selectedTrackIndices.clear();
            _trackItemKeys.clear();
          });
        }
      } else {
        _clearTrackSelection();
      }
      widget.handler.playbackModeRevision.value++;
      if (mounted) {
        final targetName = playlistNames[target] ?? 'Playlist $target';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${move ? 'Moved' : 'Copied'} ${tracks.length} tracks to “$targetName”.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not ${move ? 'move' : 'copy'} the selected tracks: $error')));
      }
    }
  }

  Future<void> _removeSelectedFromPlaylist() async {
    final navigatorContext = _navigatorKey.currentState?.overlay?.context;
    if (navigatorContext == null) return;
    final count = validTrackSelectionIndices(playlist.length, _selectedTrackIndices).length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: navigatorContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove selected tracks?'),
        content: Text(
          'Remove $count ${count == 1 ? 'track' : 'tracks'} from this playlist? The audio files will be kept.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final tracks = selectedTracks(playlist, _selectedTrackIndices);
    final remaining = tracksWithoutSelection(playlist, _selectedTrackIndices);
    await FileService().reorderPlaylist(remaining);
    for (final track in tracks) {
      widget.handler.removeTrackFromActivePlaybackOrder(track);
    }
    if (!mounted) return;
    setState(() {
      playlist = remaining;
      _selectedTrackIndices.clear();
      _trackItemKeys.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Removed $count tracks from this playlist.')));
  }

  List<String> _uniqueTrackPaths(Iterable<String> paths) {
    final service = FileService();
    final unique = <String>[];
    for (final path in paths) {
      if (!unique.any((candidate) => service.sameTrackPath(candidate, path))) unique.add(path);
    }
    return unique;
  }

  Future<void> _deleteSelectedTracks() async {
    final navigatorContext = _navigatorKey.currentState?.overlay?.context;
    if (navigatorContext == null) return;
    final tracks = _uniqueTrackPaths(selectedTracks(playlist, _selectedTrackIndices));
    if (tracks.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: navigatorContext,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.delete_forever_rounded, color: Theme.of(dialogContext).colorScheme.error),
        title: const Text('Delete selected tracks everywhere?'),
        content: Text(
          '${tracks.length} ${tracks.length == 1 ? 'track' : 'tracks'} will be removed from every Resonance playlist. '
          'Local audio files will be permanently deleted. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final service = FileService();
      for (final track in tracks) {
        await widget.handler.forgetTrack(track);
        if (!track.startsWith('http://') && !track.startsWith('https://')) {
          final file = File(track);
          if (await file.exists()) await file.delete();
        }
        await service.removeTrackFromAllPlaylists(track);
        await MetadataCacheService.remove(track);
        await const TrackSourceRepository().removeSourceForTrack(track);
      }
      await _loadPlaylistFromDisk();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted ${tracks.length} tracks everywhere.')));
      }
    } catch (error) {
      await _loadPlaylistFromDisk();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not delete every selected track: $error'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _deleteTrackEverywhere(String trackPath) async {
    if (trackPath.startsWith('http://') || trackPath.startsWith('https://')) return;
    final navigatorContext = _navigatorKey.currentState?.overlay?.context;
    if (navigatorContext == null) return;
    final cached = await MetadataCacheService.get(trackPath);
    if (!mounted) return;
    final displayName = cached?.title ?? p.basenameWithoutExtension(trackPath);
    final confirmed = await showDialog<bool>(
      context: navigatorContext,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.delete_forever_rounded, color: Theme.of(dialogContext).colorScheme.error),
        title: const Text('Delete track everywhere?'),
        content: Text(
          '“$displayName” will be deleted from this device and removed from every Resonance playlist, metadata cache, and saved source reference.\n\nThis cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await widget.handler.forgetTrack(trackPath);
      final file = File(trackPath);
      if (await file.exists()) await file.delete();
      await FileService().removeTrackFromAllPlaylists(trackPath);
      await MetadataCacheService.remove(trackPath);
      await const TrackSourceRepository().removeSourceForTrack(trackPath);
      await _loadPlaylistFromDisk();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted “$displayName” everywhere.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not delete the track: $error'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _showWindow() async {
    _resumeUi();
    await windowManager.show();
    await windowManager.focus();
  }

  void _suspendUi() {
    widget.handler.setUiVisible(false);
    if (mounted && _uiVisible) setState(() => _uiVisible = false);
  }

  void _resumeUi() {
    widget.handler.setUiVisible(true);
    if (mounted && !_uiVisible) setState(() => _uiVisible = true);
  }

  void _exitApp() {
    if (_exitInProgress) {
      _shutdownLog('_exitApp ignored because exit is already in progress');
      return;
    }
    _exitInProgress = true;
    _shutdownLog('_exitApp entered');
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    if (Platform.isWindows) {
      // Arms a native watchdog which is independent of the Dart isolate and
      // hides the HWND synchronously. It remains effective if a plugin blocks.
      unawaited(
        _windowsShutdownChannel
            .invokeMethod<void>('beginExit')
            .timeout(const Duration(milliseconds: 80))
            .catchError((error) => _shutdownLog('native beginExit call failed: $error')),
      );
    }
    if (_isDesktop) {
      unawaited(windowManager.hide().catchError((error) => _shutdownLog('window hide failed: $error')));
    }

    // Dart's fallback is deliberately below the native watchdog's 900 ms
    // deadline, but leaves a small, bounded window for essential preferences.
    Timer(const Duration(milliseconds: 700), () {
      _shutdownLog('Dart hard deadline reached; final process exit');
      exit(0);
    });
    unawaited(_completeExit(handler));
  }

  Future<void> _handleAndroidAction(Map<String, dynamic> action) async {
    while (_handlingAndroidAction && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (!mounted) throw StateError('Resonance navigation is no longer mounted.');
    _handlingAndroidAction = true;
    try {
      final actionKind = action['kind']?.toString();
      final requiresLibrary = actionKind == 'share' || actionKind == 'recognitionResult';
      BuildContext? navigatorContext;
      for (var attempt = 0; attempt < 50 && mounted; attempt++) {
        navigatorContext = _navigatorKey.currentState?.overlay?.context;
        if (navigatorContext != null &&
            (!requiresLibrary || !isLoading) &&
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      if (!mounted ||
          navigatorContext == null ||
          (requiresLibrary && isLoading) ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        throw StateError('Resonance navigation is not ready.');
      }
      if (_showIntro) {
        await _introPlayer?.stop();
        if (mounted) setState(() => _showIntro = false);
      }
      navigatorContext = _navigatorKey.currentState?.overlay?.context;
      if (!mounted || navigatorContext == null || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        throw StateError('Resonance navigation is no longer ready.');
      }

      switch (actionKind) {
        case 'share':
          await _openSharedContent(action['text']?.toString() ?? '');
        case 'startRecognition':
          final source = action['source'] == 'deviceOutput'
              ? MusicRecognitionSource.deviceOutput
              : MusicRecognitionSource.microphone;
          unawaited(_identifySong(navigatorContext, initialSource: source, tileTriggered: action['fromTile'] == true));
        case 'openRecognitionPicker':
          unawaited(_identifySong(navigatorContext));
        case 'recognitionResult':
          final resultId = action['id']?.toString();
          if (action['success'] == true && (action['title']?.toString().trim().isNotEmpty ?? false)) {
            final match = MusicRecognitionResult(
              title: action['title'].toString(),
              artist: action['artist']?.toString() ?? '',
              album: action['album']?.toString(),
              artworkUrl: action['artworkUrl']?.toString(),
              shazamUrl: action['shazamUrl']?.toString(),
            );
            unawaited(_openRecognitionSearch(navigatorContext, match, pendingResultId: resultId));
          } else {
            ScaffoldMessenger.of(navigatorContext).showSnackBar(
              SnackBar(content: Text(action['message']?.toString() ?? 'Music recognition did not return a result.')),
            );
            await AndroidEntrypointService.clearPendingRecognitionResult(resultId);
          }
      }
    } finally {
      _handlingAndroidAction = false;
    }
  }

  Future<void> _openSharedContent(String text) async {
    late final AndroidSharedContent shared;
    try {
      shared = await AndroidSharedContentService().resolve(text);
    } catch (error) {
      final context = _navigatorKey.currentState?.overlay?.context;
      if (!mounted || context == null || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        rethrow;
      }
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Could not read the shared content: $error')));
      return;
    }

    final navigatorContext = _navigatorKey.currentState?.overlay?.context;
    if (!mounted || navigatorContext == null || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw StateError('Resonance navigation is not ready.');
    }
    if (shared.kind == AndroidSharedContentKind.playlist) {
      final future = Navigator.push<bool>(
        navigatorContext,
        MaterialPageRoute(builder: (_) => ExternalPlaylistImportScreen(initialUrl: shared.value, autoFetch: true)),
      );
      unawaited(
        future.then((imported) async {
          if (imported == true && mounted) await _loadPlaylistFromDisk();
        }),
      );
      return;
    }
    final capturedNumber = activePlaylistNumber;
    final capturedName = playlistNames[capturedNumber] ?? 'Playlist $capturedNumber';
    final future = Navigator.push<String?>(
      navigatorContext,
      MaterialPageRoute(
        builder: (_) =>
            YoutubeSearchScreen(playlistNumber: capturedNumber, playlistName: capturedName, initialQuery: shared.value),
      ),
    );
    unawaited(
      future.then((addedTrack) async {
        if (!mounted) return;
        await _loadPlaylistFromDisk();
        if (addedTrack != null && mounted) await _revealCurrentTrack(addedTrack);
      }),
    );
  }

  Future<void> _completeExit(PlayerHandler handler) async {
    await Future.wait([
      _shutdownStep('essential state save', handler.saveState, const Duration(milliseconds: 220)),
      _shutdownStep('audio pause', handler.pause, const Duration(milliseconds: 120)),
    ]);

    if (Platform.isWindows) {
      await _shutdownStep('media-key unregister', MediaKeysService.unregister, const Duration(milliseconds: 100));
    }
    if (_isDesktop) {
      await _shutdownStep('tray destroy', trayManager.destroy, const Duration(milliseconds: 100));
      _shutdownLog('windowManager.destroy starting');
      await _shutdownStep('windowManager.destroy', windowManager.destroy, const Duration(milliseconds: 180));
      _shutdownLog('windowManager.destroy returned');
    }

    _shutdownLog('bounded cleanup finished; final process exit');
    exit(0);
  }

  Future<void> _shutdownStep(String label, Future<void> Function() action, Duration timeout) async {
    final started = DateTime.now();
    try {
      await action().timeout(timeout);
      _shutdownLog('$label finished in ${DateTime.now().difference(started).inMilliseconds} ms');
    } catch (error) {
      _shutdownLog('$label stopped at ${DateTime.now().difference(started).inMilliseconds} ms: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        final windowsNativeControls = Platform.isWindows && themeProvider.windowsNativeControls;
        _syncWindowsChrome(windowsNativeControls);
        return MaterialApp(
          navigatorKey: _navigatorKey,
          debugShowCheckedModeBanner: false,
          builder: (context, child) {
            if (!windowsNativeControls) return child ?? const SizedBox.shrink();
            final theme = Theme.of(context);
            return Column(
              children: [
                SizedBox(
                  height: kWindowCaptionHeight,
                  child: WindowCaption(
                    brightness: theme.brightness,
                    backgroundColor: theme.colorScheme.surface,
                    title: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.graphic_eq_rounded, size: 15, color: theme.colorScheme.primary),
                        const SizedBox(width: 7),
                        const Text('Resonance', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
                Expanded(child: child ?? const SizedBox.shrink()),
              ],
            );
          },
          themeMode: themeProvider.themeMode,
          theme: buildResonanceTheme(
            themeProvider.themeStyle,
            Brightness.light,
            fullPalette: themeProvider.fullThemePalette,
            windowsNativeControls: windowsNativeControls,
          ),
          darkTheme: buildResonanceTheme(
            themeProvider.themeStyle,
            Brightness.dark,
            fullPalette: themeProvider.fullThemePalette,
            windowsNativeControls: windowsNativeControls,
          ),
          themeAnimationDuration: const Duration(milliseconds: 360),
          themeAnimationCurve: Curves.easeInOutCubic,
          home: Builder(
            builder: (nestedContext) {
              return _showIntro
                  ? _IntroOverlay(onDismiss: () => unawaited(_dismissIntro()))
                  : TickerMode(
                      enabled: _uiVisible,
                      child: Scaffold(
                        backgroundColor: Theme.of(nestedContext).scaffoldBackgroundColor,
                        appBar: _buildAppBar(nestedContext),
                        body: _buildBody(nestedContext),
                      ),
                    );
            },
          ),
        );
      },
    );
  }

  void _syncWindowsChrome(bool enabled) {
    if (!Platform.isWindows || _windowsChromeEnabled == enabled) return;
    _windowsChromeEnabled = enabled;
    unawaited(
      windowManager
          .setTitleBarStyle(enabled ? TitleBarStyle.hidden : TitleBarStyle.normal, windowButtonVisibility: !enabled)
          .catchError((error) => _shutdownLog('Windows title bar update failed: $error')),
    );
  }

  Future<void> _openSettings(BuildContext context) async {
    await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const SettingsScreen(),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 160),
      ),
    );
    if (mounted) setState(() => _artworkRevision++);
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    if (Platform.isWindows && useWindowsNativeControls(context)) {
      final border = theme.colorScheme.outline;
      final surface = theme.colorScheme.surface;
      return PreferredSize(
        preferredSize: const Size.fromHeight(46),
        child: Material(
          color: surface,
          child: Container(
            height: 46,
            padding: const EdgeInsets.only(left: 14, right: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: border)),
            ),
            child: Row(
              children: [
                Text('Library', style: theme.appBarTheme.titleTextStyle),
                const Spacer(),
                IconButton(
                  key: const Key('windows-settings-command'),
                  onPressed: () => _openSettings(context),
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  tooltip: 'Settings',
                ),
              ],
            ),
          ),
        ),
      );
    }
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
              color: Theme.of(context).colorScheme.primary,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
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
          onPressed: () => _openSettings(context),
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
                  child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(nestedContext).colorScheme.primary),
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
            playlistNumber: activePlaylistNumber,
            controller: _playlistScrollController,
            pulsingTrackIndex: _pulsingTrackIndex,
            pulse: _trackPulse,
            artworkRevision: _artworkRevision,
            selectedIndices: _selectedTrackIndices,
            onSelectionToggle: _toggleTrackSelection,
            itemKeyForIndex: _trackItemKey,
            onTrackDeleted: (index, trackPath) async {
              setState(() => playlist.removeAt(index));
              await FileService().removeFromPlaylist(trackPath, playlistIndex: index);
              widget.handler.removeTrackFromActivePlaybackOrder(trackPath);
            },
            onTrackDeletedEverywhere: (trackPath) => unawaited(_deleteTrackEverywhere(trackPath)),
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

    final library = Column(
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
                          widget.handler.playbackModeRevision.value++;
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
        AlbumCover(
          onTap: _handleNowPlayingTap,
          onArtworkTap: _handleNowPlayingArtworkTap,
          onQueueRequested: _toggleUpcomingQueue,
          artworkRevision: _artworkRevision,
        ),
        PlayerControls(),
      ],
    );
    if (!Platform.isWindows || !_queueDrawerOpen) return library;
    return LayoutBuilder(
      builder: (context, constraints) {
        final drawerWidth = (constraints.maxWidth * 0.30).clamp(280.0, 360.0);
        return Row(
          children: [
            Expanded(child: library),
            SizedBox(
              width: drawerWidth,
              child: UpcomingQueuePanel(
                mediaItemStream: widget.handler.mediaItem,
                initialMediaItem: widget.handler.mediaItem.value,
                revision: widget.handler.playbackModeRevision,
                loadSnapshot: widget.handler.playbackQueueSnapshot,
                onPlay: widget.handler.playPlaybackQueueEntry,
                onClose: _toggleUpcomingQueue,
              ),
            ),
          ],
        );
      },
    );
  }

  void _toggleUpcomingQueue() {
    if (Platform.isWindows) {
      setState(() => _queueDrawerOpen = !_queueDrawerOpen);
      return;
    }
    if (!Platform.isAndroid) return;
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final height = MediaQuery.sizeOf(sheetContext).height;
        return SizedBox(
          height: (height * 0.62).clamp(360.0, 560.0),
          child: UpcomingQueuePanel(
            compact: true,
            mediaItemStream: widget.handler.mediaItem,
            initialMediaItem: widget.handler.mediaItem.value,
            revision: widget.handler.playbackModeRevision,
            loadSnapshot: widget.handler.playbackQueueSnapshot,
            onClose: () => Navigator.pop(sheetContext),
          ),
        );
      },
    );
  }

  Widget _buildToolbar(BuildContext context) {
    if (_selectedTrackIndices.isNotEmpty) return _buildSelectionToolbar(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final windowsNative = Platform.isWindows && useWindowsNativeControls(context);
    final trackCount = playlist.length;
    return Container(
      padding: windowsNative ? const EdgeInsets.fromLTRB(14, 5, 8, 5) : const EdgeInsets.fromLTRB(16, 4, 8, 8),
      decoration: windowsNative
          ? BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outline)),
            )
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 680;
          return Row(
            children: [
              Expanded(
                child: Text(
                  '${playlistNames[activePlaylistNumber] ?? 'Playlist $activePlaylistNumber'} - ${trackCount == 0 ? 'No tracks' : '$trackCount ${trackCount == 1 ? 'track' : 'tracks'}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              if (!compact) ..._wideTransferActions(context),
              _buildPlaylistMenu(),
              IconButton(
                key: const Key('music-recognition-button'),
                onPressed: () => _identifySong(context),
                icon: const Icon(Icons.graphic_eq_rounded),
                tooltip: 'Shazam / Identify a song',
              ),
              IconButton(
                onPressed: () => _openSearch(context),
                icon: const Icon(Icons.search_rounded),
                tooltip: 'Search YouTube',
              ),
              if (!compact) ..._wideLibraryActions(context),
              if (compact) _buildCompactActionsMenu(context),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSelectionToolbar(BuildContext context) {
    final windowsNative = Platform.isWindows && useWindowsNativeControls(context);
    final allSelected = _selectedTrackIndices.length == playlist.length;
    return Container(
      key: const Key('track-selection-toolbar'),
      padding: windowsNative ? const EdgeInsets.fromLTRB(8, 5, 8, 5) : const EdgeInsets.fromLTRB(8, 4, 8, 8),
      decoration: windowsNative
          ? BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outline)),
            )
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          return Row(
            children: [
              IconButton(
                onPressed: _clearTrackSelection,
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Cancel selection',
              ),
              Expanded(
                child: Text(
                  '${_selectedTrackIndices.length} selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: allSelected ? _clearTrackSelection : _selectAllTracks,
                icon: Icon(allSelected ? Icons.deselect_rounded : Icons.select_all_rounded),
                tooltip: allSelected ? 'Select none' : 'Select all',
              ),
              if (!compact) ...[
                IconButton(
                  onPressed: playlistNumbers.length > 1 ? () => _copyOrMoveSelected(move: false) : null,
                  icon: const Icon(Icons.copy_all_rounded),
                  tooltip: 'Copy to playlist',
                ),
                IconButton(
                  onPressed: playlistNumbers.length > 1 ? () => _copyOrMoveSelected(move: true) : null,
                  icon: const Icon(Icons.drive_file_move_rounded),
                  tooltip: 'Move to playlist',
                ),
                IconButton(
                  onPressed: _removeSelectedFromPlaylist,
                  icon: const Icon(Icons.playlist_remove_rounded),
                  tooltip: 'Remove from playlist',
                ),
                IconButton(
                  onPressed: _deleteSelectedTracks,
                  icon: Icon(Icons.delete_forever_rounded, color: Theme.of(context).colorScheme.error),
                  tooltip: 'Delete everywhere',
                ),
              ] else
                PopupMenuButton<_SelectionAction>(
                  tooltip: 'Selected track actions',
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: _handleSelectionAction,
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _SelectionAction.copy,
                      enabled: playlistNumbers.length > 1,
                      child: const _ToolbarMenuLabel(icon: Icons.copy_all_rounded, label: 'Copy to playlist'),
                    ),
                    PopupMenuItem(
                      value: _SelectionAction.move,
                      enabled: playlistNumbers.length > 1,
                      child: const _ToolbarMenuLabel(icon: Icons.drive_file_move_rounded, label: 'Move to playlist'),
                    ),
                    const PopupMenuItem(
                      value: _SelectionAction.remove,
                      child: _ToolbarMenuLabel(icon: Icons.playlist_remove_rounded, label: 'Remove from playlist'),
                    ),
                    PopupMenuItem(
                      value: _SelectionAction.delete,
                      child: _ToolbarMenuLabel(
                        icon: Icons.delete_forever_rounded,
                        label: 'Delete everywhere',
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  void _handleSelectionAction(_SelectionAction action) {
    switch (action) {
      case _SelectionAction.copy:
        unawaited(_copyOrMoveSelected(move: false));
      case _SelectionAction.move:
        unawaited(_copyOrMoveSelected(move: true));
      case _SelectionAction.remove:
        unawaited(_removeSelectedFromPlaylist());
      case _SelectionAction.delete:
        unawaited(_deleteSelectedTracks());
    }
  }

  List<Widget> _wideTransferActions(BuildContext context) => [
    IconButton(
      onPressed: () => setState(() => _artworkRevision++),
      icon: const Icon(Icons.refresh_rounded, size: 20),
      tooltip: 'Refresh track covers',
    ),
    IconButton(
      onPressed: () => _transferCurrentPlaylist(context),
      icon: const Icon(Icons.qr_code_2_rounded, size: 21),
      tooltip: 'Transfer current playlist',
    ),
    IconButton(
      onPressed: () => _importTransferredPlaylist(context),
      icon: const Icon(Icons.qr_code_scanner_rounded, size: 21),
      tooltip: 'Import playlist from another device',
    ),
    IconButton(
      onPressed: () => _importExternalPlaylist(context),
      icon: const Icon(Icons.playlist_add_rounded, size: 22),
      tooltip: 'Cross-website playlist import',
    ),
  ];

  List<Widget> _wideLibraryActions(BuildContext context) => [
    IconButton(
      onPressed: () => _importLocalTracks(context),
      icon: const Icon(Icons.add_rounded),
      tooltip: 'Import local tracks',
    ),
  ];

  Widget _buildCompactActionsMenu(BuildContext context) => PopupMenuButton<_ToolbarAction>(
    tooltip: 'More playlist actions',
    icon: const Icon(Icons.more_vert_rounded),
    onSelected: (action) => _handleToolbarAction(context, action),
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: _ToolbarAction.refresh,
        child: _ToolbarMenuLabel(icon: Icons.refresh_rounded, label: 'Refresh track covers'),
      ),
      PopupMenuItem(
        value: _ToolbarAction.transfer,
        child: _ToolbarMenuLabel(icon: Icons.qr_code_2_rounded, label: 'Transfer current playlist'),
      ),
      PopupMenuItem(
        value: _ToolbarAction.importTransfer,
        child: _ToolbarMenuLabel(icon: Icons.qr_code_scanner_rounded, label: 'Import playlist QR'),
      ),
      PopupMenuItem(
        value: _ToolbarAction.importExternal,
        child: _ToolbarMenuLabel(icon: Icons.playlist_add_rounded, label: 'Cross-website playlist import'),
      ),
      PopupMenuItem(
        value: _ToolbarAction.importLocal,
        child: _ToolbarMenuLabel(icon: Icons.add_rounded, label: 'Import local tracks'),
      ),
    ],
  );

  void _handleToolbarAction(BuildContext context, _ToolbarAction action) {
    switch (action) {
      case _ToolbarAction.refresh:
        setState(() => _artworkRevision++);
      case _ToolbarAction.transfer:
        unawaited(_transferCurrentPlaylist(context));
      case _ToolbarAction.importTransfer:
        unawaited(_importTransferredPlaylist(context));
      case _ToolbarAction.importExternal:
        unawaited(_importExternalPlaylist(context));
      case _ToolbarAction.importLocal:
        unawaited(_importLocalTracks(context));
    }
  }

  Future<void> _importLocalTracks(BuildContext context) async {
    await ImportTrackButton.selectFiles(context, (newPath) {
      if (mounted) {
        setState(() => playlist.add(newPath));
        widget.handler.playbackModeRevision.value++;
      }
    });
  }

  Future<void> _openSearch(BuildContext context) async {
    final capturedNumber = activePlaylistNumber;
    final capturedName = playlistNames[capturedNumber] ?? 'Playlist $capturedNumber';
    final addedTrack = await Navigator.push<String?>(
      context,
      MaterialPageRoute<String?>(
        builder: (_) => YoutubeSearchScreen(playlistNumber: capturedNumber, playlistName: capturedName),
      ),
    );
    if (!mounted) return;
    await _loadPlaylistFromDisk();
    if (addedTrack != null && mounted) await _revealCurrentTrack(addedTrack);
  }

  Future<void> _identifySong(
    BuildContext context, {
    MusicRecognitionSource? initialSource,
    bool tileTriggered = false,
  }) async {
    final match = await showMusicRecognitionDialog(context, initialSource: initialSource, tileTriggered: tileTriggered);
    if (!mounted || match == null) return;

    await _openRecognitionSearch(context, match);
  }

  Future<void> _openRecognitionSearch(
    BuildContext context,
    MusicRecognitionResult match, {
    String? pendingResultId,
  }) async {
    final capturedNumber = activePlaylistNumber;
    final capturedName = playlistNames[capturedNumber] ?? 'Playlist $capturedNumber';
    final route = Navigator.push<String?>(
      context,
      MaterialPageRoute<String?>(
        builder: (_) => YoutubeSearchScreen(
          playlistNumber: capturedNumber,
          playlistName: capturedName,
          initialQuery: match.youtubeQuery,
          recognitionLabel: [match.title, if (match.artist.isNotEmpty) match.artist].join(' — '),
        ),
      ),
    );
    if (pendingResultId != null) {
      await AndroidEntrypointService.clearPendingRecognitionResult(pendingResultId);
    }
    final addedTrack = await route;
    if (!mounted) return;
    await _loadPlaylistFromDisk();
    if (addedTrack != null && mounted) await _revealCurrentTrack(addedTrack);
  }

  Future<void> _handleNowPlayingTap(String trackPath) async {
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    await navigateFromNowPlaying(
      navigator: navigator,
      isStandalone: handler.isStandaloneMode,
      trackPath: trackPath,
      revealTrack: _revealCurrentTrack,
    );
  }

  Future<void> _handleNowPlayingArtworkTap(String trackPath) async {
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    if (handler.isStandaloneMode) {
      await navigator.push<void>(MaterialPageRoute<void>(builder: (_) => const StandalonePlayerScreen()));
      return;
    }

    final item = handler.mediaItem.value;
    if (item == null) return;

    final service = FileService();
    int? playlistNumber = activePlaylistNumber;
    var playlistIndex = service.findTrackIndex(playlist, trackPath);

    if (playlistIndex < 0) {
      playlistNumber = await service.findPlaylistContaining(trackPath, preferredPlaylistNumber: activePlaylistNumber);
      if (!mounted || !navigator.mounted) return;
      if (playlistNumber != null) {
        final content = await service.readTextFromPlaylist(playlistNumber);
        final tracks = content
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty && !line.startsWith('#'))
            .toList();
        playlistIndex = service.findTrackIndex(tracks, trackPath);
      }
    }

    if (!mounted || !navigator.mounted) return;
    if (playlistNumber != null && playlistIndex >= 0) {
      final ready = await handler.preparePlaylistTrackForStandalone(
        trackPath,
        item.title,
        item.artist ?? 'Unknown Artist',
        playlistNumber: playlistNumber,
        playlistIndex: playlistIndex,
      );
      if (!ready || !mounted || !navigator.mounted) return;
    } else {
      // A restored/non-playlist track still gets a temporary large-player
      // presentation; leaving it restores the regular library interaction.
      handler.setStandalonePresentation(true);
    }

    await navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const StandalonePlayerScreen(playlistTrack: true)),
    );
  }

  Widget _buildPlaylistMenu() => PopupMenuButton<_PlaylistMenuAction>(
    tooltip: 'Switch playlist',
    icon: const Icon(Icons.queue_music_rounded),
    onSelected: (action) {
      switch (action.type) {
        case _PlaylistActionType.select:
          unawaited(_switchPlaylist(action.playlistNumber!));
        case _PlaylistActionType.create:
          unawaited(_createPlaylist());
        case _PlaylistActionType.rename:
          unawaited(_renameActivePlaylist());
        case _PlaylistActionType.delete:
          unawaited(_deleteActivePlaylist());
      }
    },
    itemBuilder: (menuContext) => [
      for (final number in playlistNumbers)
        PopupMenuItem<_PlaylistMenuAction>(
          value: _PlaylistMenuAction.select(number),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () {
              Navigator.pop(menuContext);
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
                Flexible(child: Text(playlistNames[number] ?? 'Playlist $number', overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: _PlaylistMenuAction(_PlaylistActionType.create),
        child: _ToolbarMenuLabel(icon: Icons.add_rounded, label: 'New playlist'),
      ),
      const PopupMenuItem(
        value: _PlaylistMenuAction(_PlaylistActionType.rename),
        child: _ToolbarMenuLabel(icon: Icons.edit_rounded, label: 'Rename current'),
      ),
      PopupMenuItem(
        value: const _PlaylistMenuAction(_PlaylistActionType.delete),
        enabled: playlistNumbers.length > 1,
        child: const _ToolbarMenuLabel(icon: Icons.delete_outline_rounded, label: 'Delete current'),
      ),
    ],
  );
}

enum _ToolbarAction { refresh, transfer, importTransfer, importExternal, importLocal }

class _ToolbarMenuLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _ToolbarMenuLabel({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 10),
      Flexible(
        child: Text(label, style: color == null ? null : TextStyle(color: color)),
      ),
    ],
  );
}

enum _PlaylistActionType { select, create, rename, delete }

enum _SelectionAction { copy, move, remove, delete }

class _PlaylistMenuAction {
  final _PlaylistActionType type;
  final int? playlistNumber;
  const _PlaylistMenuAction(this.type) : playlistNumber = null;
  const _PlaylistMenuAction.select(this.playlistNumber) : type = _PlaylistActionType.select;
}

EncodedPlaylistTransfer _encodeTransferManifest(Map<String, dynamic> json) {
  return PlaylistTransferCodec.encode(PlaylistTransferManifest.fromJson(json));
}

class _IntroOverlay extends StatefulWidget {
  final VoidCallback onDismiss;

  const _IntroOverlay({required this.onDismiss});

  @override
  State<_IntroOverlay> createState() => _IntroOverlayState();
}

class _IntroOverlayState extends State<_IntroOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 3030))..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onDismiss,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final progress = reduceMotion ? 0.72 : _controller.value;
          final entrance = Curves.easeOutExpo.transform((progress / 0.42).clamp(0.0, 1.0));
          final exit = 1 - Curves.easeInCubic.transform(((progress - 0.84) / 0.16).clamp(0.0, 1.0));
          final logoScale = 0.78 + entrance * 0.22;
          final wordReveal = Curves.easeOutCubic.transform(((progress - 0.28) / 0.34).clamp(0.0, 1.0));
          return Opacity(
            opacity: reduceMotion ? 1 : exit,
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.08),
                  radius: 1.08,
                  colors: [Color.lerp(const Color(0xFF15121D), primary, 0.09)!, const Color(0xFF07070B), Colors.black],
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(child: CustomPaint(painter: _ResonancePainter(progress, primary, reduceMotion))),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Opacity(
                          opacity: entrance,
                          child: Transform.scale(
                            scale: logoScale,
                            child: Container(
                              width: 82,
                              height: 82,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(22),
                                boxShadow: [
                                  BoxShadow(
                                    color: primary.withValues(alpha: 0.34 * entrance),
                                    blurRadius: 54,
                                    spreadRadius: 4,
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(22),
                                child: Image.asset('assets/icon/icon.png', fit: BoxFit.cover),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        ClipRect(
                          child: Align(
                            heightFactor: wordReveal,
                            child: Opacity(
                              opacity: wordReveal,
                              child: Transform.translate(
                                offset: Offset(0, 10 * (1 - wordReveal)),
                                child: const Text(
                                  'RESONANCE',
                                  style: TextStyle(
                                    color: Color(0xFFF4F1FA),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 6.2,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: math.max(22, MediaQuery.paddingOf(context).bottom + 14),
                    child: Opacity(
                      opacity: 0.34 * wordReveal,
                      child: const Text(
                        'tap to skip',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          letterSpacing: 1.2,
                          decoration: TextDecoration.none,
                        ),
                      ),
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
  final bool reduceMotion;
  const _ResonancePainter(this.progress, this.color, this.reduceMotion);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final reveal = reduceMotion ? 1.0 : Curves.easeOutQuart.transform((progress / 0.58).clamp(0.0, 1.0));
    final halfWidth = size.width * 0.48 * reveal;
    final waveform = Path()..moveTo(center.dx - halfWidth, center.dy);
    const samples = 150;
    for (var index = 0; index <= samples; index++) {
      final normalized = index / samples * 2 - 1;
      final x = center.dx + normalized * halfWidth;
      final envelope = math.pow(1 - normalized.abs(), 2.2).toDouble();
      final fracture = math.sin(normalized * 33 + progress * math.pi * 5) * 11 + math.sin(normalized * 71) * 4;
      final y = center.dy + fracture * envelope * reveal;
      waveform.lineTo(x, y);
    }
    canvas.drawPath(
      waveform,
      Paint()
        ..color = color.withValues(alpha: 0.16)
        ..strokeWidth = 8
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawPath(
      waveform,
      Paint()
        ..color = Color.lerp(color, Colors.white, 0.34)!.withValues(alpha: 0.82)
        ..strokeWidth = 1.25
        ..style = PaintingStyle.stroke,
    );

    final flash = 1 - ((progress - 0.12) / 0.26).clamp(0.0, 1.0);
    canvas.drawLine(
      Offset(center.dx, center.dy - 82 * flash),
      Offset(center.dx, center.dy + 82 * flash),
      Paint()
        ..color = Colors.white.withValues(alpha: flash * 0.58)
        ..strokeWidth = 1.2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    for (var index = 0; index < 18; index++) {
      final side = index.isEven ? -1.0 : 1.0;
      final seed = (index * 37 % 101) / 101;
      final travel = reveal * (0.3 + seed * 0.7);
      final x = center.dx + side * size.width * (0.06 + seed * 0.43) * travel;
      final y = center.dy + math.sin(index * 2.31) * (18 + seed * 42) * travel;
      canvas.drawCircle(
        Offset(x, y),
        0.6 + seed * 1.2,
        Paint()..color = color.withValues(alpha: (1 - travel * 0.55) * 0.45),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResonancePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

// ── Theme builders ─────────────────────────────────────────────────────────────

// ignore: unused_element
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

// ignore: unused_element
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
