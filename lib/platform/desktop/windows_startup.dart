import 'dart:io';
import 'package:flutter/services.dart';
import 'package:resonance/services/update_manifest.dart' show updateTestMode;

class WindowsStartup {
  const WindowsStartup({this.channel = const MethodChannel('resonance/windows_shutdown')});
  final MethodChannel channel;
  static bool get available => Platform.isWindows && !updateTestMode;
  Future<bool> read() async => available && await channel.invokeMethod<bool>('getStartup') == true;
  Future<bool> setEnabled(bool enabled) async {
    if (!available) return false;
    return await channel.invokeMethod<bool>('setStartup', {'enabled': enabled}) == true;
  }

  Future<void> refreshRegisteredPath() async {
    if (available) await channel.invokeMethod<bool>('refreshStartup');
  }
}
