import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/providers/theme_provider.dart';

/// Publishes a small persisted snapshot for the native Android home-screen
/// widget. The native side owns rendering and button dispatch.
class AndroidPlaybackWidgetService {
  AndroidPlaybackWidgetService._();

  static final AndroidPlaybackWidgetService instance = AndroidPlaybackWidgetService._();
  static const MethodChannel _channel = MethodChannel('resonance/playback_widget');

  PlayerHandler? _handler;
  ThemeProvider? _themeProvider;
  Timer? _debounce;
  Timer? _safetySync;
  Future<void> _syncQueue = Future<void>.value();
  String? _resolvedArtworkUri;
  String? _resolvedArtworkPath;
  int _artworkGeneration = 0;

  Future<void> attach(PlayerHandler handler, ThemeProvider themeProvider) async {
    if (!Platform.isAndroid || identical(_handler, handler)) return;
    _handler = handler;
    _themeProvider = themeProvider;
    _channel.setMethodCallHandler(_handleNativeCall);
    handler.mediaItem.listen((_) => _scheduleSync(resolveArtwork: true));
    handler.playbackVisualNotifier.addListener(_scheduleSync);
    handler.playbackModeRevision.addListener(_scheduleSync);
    themeProvider.addListener(_scheduleSync);
    _beginArtworkResolution();
    _safetySync?.cancel();
    _safetySync = Timer.periodic(const Duration(seconds: 3), (_) => _enqueueSync());
    await _enqueueSync();
  }

  void _scheduleSync({bool resolveArtwork = false}) {
    if (resolveArtwork) _beginArtworkResolution();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _enqueueSync);
  }

  Future<void> _enqueueSync() {
    _syncQueue = _syncQueue.then((_) => _sync()).catchError((Object error, StackTrace stackTrace) {
      debugPrint('[PlaybackWidget] Snapshot sync failed: $error');
    });
    return _syncQueue;
  }

  void _beginArtworkResolution() {
    final uri = _handler?.mediaItem.value?.artUri;
    final uriString = uri?.toString();
    if (uriString == _resolvedArtworkUri) return;

    _resolvedArtworkUri = uriString;
    _resolvedArtworkPath = null;
    final generation = ++_artworkGeneration;
    unawaited(() async {
      final path = await _widgetSafeArtwork(uri);
      if (generation != _artworkGeneration) return;
      _resolvedArtworkPath = path;
      await _enqueueSync();
    }());
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'command') throw MissingPluginException('Unknown widget method: ${call.method}');
    final handler = _handler;
    if (handler == null) return false;

    switch (call.arguments) {
      case 'shuffle':
        await handler.toggleShuffle();
      case 'repeat':
        await handler.toggleLoopMode();
      default:
        return false;
    }
    _scheduleSync();
    return true;
  }

  Future<void> _sync() async {
    final handler = _handler;
    final themeProvider = _themeProvider;
    if (!Platform.isAndroid || handler == null || themeProvider == null) return;

    final item = handler.mediaItem.value;
    if (item?.artUri?.toString() != _resolvedArtworkUri) _beginArtworkResolution();

    final platformBrightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final brightness = switch (themeProvider.themeMode) {
      ThemeMode.dark => Brightness.dark,
      ThemeMode.light => Brightness.light,
      ThemeMode.system => platformBrightness,
    };
    final theme = buildResonanceTheme(
      themeProvider.themeStyle,
      brightness,
      fullPalette: themeProvider.fullThemePalette,
    );
    final scheme = theme.colorScheme;

    try {
      await _channel.invokeMethod<void>('update', {
        'hasTrack': item != null,
        'title': item?.title.trim().isNotEmpty == true ? item!.title.trim() : 'Nothing playing',
        'artist': item?.artist?.trim() ?? '',
        'artworkPath': _resolvedArtworkPath ?? '',
        'playing': handler.playbackVisualNotifier.value.playing,
        'shuffle': handler.getShuffleMode(),
        'repeatMode': handler.getLoopMode().name,
        'accent': scheme.primary.toARGB32(),
        'surface': scheme.surface.toARGB32(),
        'surfaceElevated': scheme.surfaceContainerHigh.toARGB32(),
        'onSurface': scheme.onSurface.toARGB32(),
        'onSurfaceVariant': scheme.onSurfaceVariant.toARGB32(),
      });
    } on MissingPluginException {
      // Widget integration is Android-only and unavailable in Flutter tests.
    } on PlatformException catch (error) {
      debugPrint('[PlaybackWidget] Could not update native widget: $error');
    }
  }

  Future<String?> _widgetSafeArtwork(Uri? uri) async {
    if (uri == null) return null;
    if (uri.scheme == 'file') {
      final file = File.fromUri(uri);
      return await file.exists() ? file.path : null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    try {
      final directory = Directory(p.join((await getTemporaryDirectory()).path, 'resonance_widget_artwork'));
      await directory.create(recursive: true);
      final extension = p.extension(uri.path).toLowerCase();
      final safeExtension = const {'.jpg', '.jpeg', '.png', '.webp'}.contains(extension) ? extension : '.img';
      final file = File(p.join(directory.path, '${sha1.convert(uri.toString().codeUnits)}$safeExtension'));
      if (await file.exists() && await file.length() > 0) return file.path;

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(uri);
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) return null;
        final sink = file.openWrite();
        await response.pipe(sink);
        return await file.exists() && await file.length() > 0 ? file.path : null;
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      debugPrint('[PlaybackWidget] Could not cache artwork: $error');
      return null;
    }
  }
}
