import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart-side bridge to the native Win32 media-key plugin
/// (windows/runner/media_keys_plugin.cpp).
///
/// This exists because:
/// 1. hotkey_manager_windows crashes the entire native process when
///    asked to register LogicalKeyboardKey.mediaTrackNext/Previous
///    (confirmed: causes "Lost connection to device", i.e. a native
///    crash, not a recoverable Dart exception).
/// 2. audio_service_win's SMTC integration has its own bug where the
///    Next/Previous buttons only arm after a play/pause transition.
///
/// This bridge talks directly to Win32's RegisterHotKey with
/// VK_MEDIA_NEXT_TRACK / VK_MEDIA_PREV_TRACK, bypassing both plugins
/// entirely for just these two keys. Play/Pause is left to
/// audio_service_win/SMTC since that already works correctly.
class MediaKeysService {
  static const MethodChannel _methodChannel = MethodChannel('resonance/media_keys');
  static const EventChannel _eventChannel = EventChannel('resonance/media_keys/events');

  static StreamSubscription<dynamic>? _subscription;
  static bool _registered = false;

  /// Registers the hardware Media Next/Previous keys and starts
  /// listening for press events. Safe to call multiple times - it's a
  /// no-op if already registered.
  ///
  /// [onNext] and [onPrevious] are called whenever the corresponding
  /// hardware key is pressed.
  ///
  /// Returns true if registration succeeded. On non-Windows platforms,
  /// or if the native call fails for any reason, this returns false
  /// without throwing - callers should treat this as "feature
  /// unavailable" rather than a fatal error.
  static Future<bool> register({
    required VoidCallback onNext,
    required VoidCallback onPrevious,
  }) async {
    if (_registered) return true;

    try {
      final bool ok = await _methodChannel.invokeMethod<bool>('register') ?? false;
      if (!ok) return false;

      _subscription = _eventChannel.receiveBroadcastStream().listen(
        (event) {
          debugPrint('[MediaKeysService] received event: $event');
          if (event == 'next') {
            onNext();
          } else if (event == 'previous') {
            onPrevious();
          }
        },
        onError: (Object error) {
          debugPrint('[MediaKeysService] stream error: $error');
        },
      );

      _registered = true;
      return true;
    } catch (_) {
      // PlatformException, MissingPluginException (e.g. running on a
      // platform without this native plugin compiled in), etc.
      // Treat as "not available" rather than crashing the app.
      return false;
    }
  }

  /// Unregisters the hotkeys and stops listening. Call this on app
  /// shutdown if you want to be tidy, though the OS will clean up the
  /// hotkey registration automatically when the process exits anyway.
  static Future<void> unregister() async {
    if (!_registered) return;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _methodChannel.invokeMethod('unregister');
    } catch (_) {}
    _registered = false;
  }
}

typedef VoidCallback = void Function();