import 'package:flutter/services.dart';

class AndroidBassBoost {
  static const _channel = MethodChannel('resonance/bass_boost');

  static Future<bool> setStrength({required int audioSessionId, required double strength}) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('setStrength', {
      'audioSessionId': audioSessionId,
      'strength': strength.clamp(0.0, 1.0),
    });
    return result?['applied'] == true;
  }

  static Future<void> release(int audioSessionId) =>
      _channel.invokeMethod<void>('release', {'audioSessionId': audioSessionId});
}
