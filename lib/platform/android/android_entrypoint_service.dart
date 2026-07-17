import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

typedef AndroidLaunchActionHandler = Future<void> Function(Map<String, dynamic> action);

/// Bridges Android share/tile/notification entry points into the existing
/// Flutter navigation and recognition flows.
class AndroidEntrypointService {
  static const MethodChannel _channel = MethodChannel('resonance/android_entrypoints');
  static final Set<String> _deliveredActionIds = <String>{};
  static AndroidLaunchActionHandler? _handler;

  static Future<void> initialize(AndroidLaunchActionHandler handler) async {
    if (!Platform.isAndroid) return;
    _handler = handler;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onLaunchAction') return;
      final action = _asStringMap(call.arguments);
      if (action != null) await _deliver(action);
    });
    try {
      final pending = _asStringMap(await _channel.invokeMethod<Object?>('getPendingAction'));
      if (pending != null) await _deliver(pending);
    } on PlatformException {
      // Native will dispatch the persisted action again from onPostResume.
    } on MissingPluginException {
      // The Activity may still be attaching to a cached Flutter engine.
    }
  }

  static Future<bool> beginRecognition({required bool fromTile}) async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('beginRecognition', {'fromTile': fromTile}) ?? false;
  }

  static Future<void> updateRecognitionStage(String stage) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('updateRecognitionStage', {'stage': stage});
    } on PlatformException {
      // Tile status is best-effort; scan ownership is completed separately.
    } on MissingPluginException {
      // The native Activity can be between attachments while backgrounded.
    }
  }

  /// Returns true when Android posted a background completion notification and
  /// Flutter should defer opening the result until that notification is tapped.
  static Future<bool> completeRecognition({
    required bool success,
    bool canOpenDirectly = true,
    String? title,
    String? artist,
    String? album,
    String? artworkUrl,
    String? shazamUrl,
    String? message,
  }) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('finishRecognition', {
          'success': success,
          'canOpenDirectly': canOpenDirectly,
          if (title != null) 'title': title,
          if (artist != null) 'artist': artist,
          if (album != null) 'album': album,
          if (artworkUrl != null) 'artworkUrl': artworkUrl,
          if (shazamUrl != null) 'shazamUrl': shazamUrl,
          if (message != null) 'message': message,
        }) ??
        false;
  }

  static Future<void> resetRecognition() async {
    if (!Platform.isAndroid) return;
    Object? lastError;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await _channel.invokeMethod<void>('resetRecognition');
        return;
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (lastError != null) throw lastError;
  }

  static Future<String> getDefaultRecognitionSource() async {
    if (!Platform.isAndroid) return 'microphone';
    try {
      final source = await _channel.invokeMethod<String>('getDefaultRecognitionSource');
      return source == 'deviceOutput' ? source! : 'microphone';
    } on PlatformException {
      return 'microphone';
    } on MissingPluginException {
      return 'microphone';
    }
  }

  static Future<void> setDefaultRecognitionSource(String source) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setDefaultRecognitionSource', {'source': source});
    } on PlatformException {
      // Keep the current native default if the Activity is being recreated.
    } on MissingPluginException {
      // Keep the current native default if the Activity is being recreated.
    }
  }

  static Future<void> clearPendingRecognitionResult(String? id) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('clearPendingRecognitionResult', {'id': id});
    } catch (_) {
      unawaited(_retryClearPendingRecognitionResult(id));
    }
  }

  static Future<void> _retryClearPendingRecognitionResult(String? id, {int attempt = 0}) async {
    if (attempt >= 20) return;
    await Future<void>.delayed(attempt < 4 ? const Duration(milliseconds: 250) : const Duration(seconds: 1));
    try {
      await _channel.invokeMethod<void>('clearPendingRecognitionResult', {'id': id});
    } catch (_) {
      unawaited(_retryClearPendingRecognitionResult(id, attempt: attempt + 1));
    }
  }

  static Future<void> _deliver(Map<String, dynamic> action, {int attempt = 0}) async {
    final id = action['id']?.toString();
    if (id != null && !_deliveredActionIds.add(id)) return;
    final handler = _handler;
    if (handler == null) {
      if (id != null) _deliveredActionIds.remove(id);
      return;
    }
    try {
      await handler(action);
    } catch (_) {
      // Leave the action persisted and retry in this process while the first
      // Flutter frame/library load is still settling. A recreated activity can
      // also retrieve the same action from native storage later.
      if (id != null) _deliveredActionIds.remove(id);
      if (attempt < 60 && _handler != null) {
        final delay = attempt < 8 ? const Duration(milliseconds: 250) : const Duration(seconds: 1);
        unawaited(Future<void>.delayed(delay, () => _deliver(action, attempt: attempt + 1)));
      }
      return;
    }
    // A transient channel detach after navigation must not reopen the same
    // route. Retry only the acknowledgement, leaving the delivered ID deduped.
    await _acknowledge(id);
  }

  static Future<void> _acknowledge(String? id, {int attempt = 0}) async {
    try {
      await _channel.invokeMethod<void>('acknowledgeAction', {'id': id});
    } catch (_) {
      if (attempt >= 20) return;
      final delay = attempt < 4 ? const Duration(milliseconds: 250) : const Duration(seconds: 1);
      unawaited(Future<void>.delayed(delay, () => _acknowledge(id, attempt: attempt + 1)));
    }
  }

  static Map<String, dynamic>? _asStringMap(Object? value) {
    if (value is! Map) return null;
    return <String, dynamic>{for (final entry in value.entries) entry.key.toString(): entry.value};
  }
}
