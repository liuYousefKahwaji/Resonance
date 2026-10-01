import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'app_update_service.dart';

/// Compile-time only. Test builds cannot read production Windows preferences or
/// playlists; Android uses a separate application ID and private sandbox.
Future<void> initializeUpdateTestProfile() async {
  if (!updateTestMode || !Platform.isWindows) return;
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null) throw StateError('Test profile storage unavailable');
  final root = await Directory(p.join(local, 'ResonanceUpdateTest')).create(recursive: true);
  PathProviderPlatform.instance = _TestPaths(root.path);
  final file = File(p.join(root.path, 'preferences.json'));
  final values = <String, Object>{};
  if (await file.exists()) {
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    for (final entry in json.entries) {
      values[entry.key] = entry.value is List ? List<String>.from(entry.value) : entry.value as Object;
    }
  }
  SharedPreferencesStorePlatform.instance = _TestPreferences(file, values);
}

class _TestPaths extends PathProviderPlatform {
  final String root;
  _TestPaths(this.root);
  Future<String> _directory(String name) async => (await Directory(p.join(root, name)).create(recursive: true)).path;
  @override
  Future<String?> getTemporaryPath() => _directory('tmp');
  @override
  Future<String?> getApplicationSupportPath() => _directory('support');
  @override
  Future<String?> getApplicationDocumentsPath() => _directory('documents');
  @override
  Future<String?> getApplicationCachePath() => _directory('cache');
  @override
  Future<String?> getDownloadsPath() => _directory('downloads');
  @override
  Future<String?> getLibraryPath() => _directory('library');
}

class _TestPreferences extends InMemorySharedPreferencesStore {
  final File file;
  Future<void> _writes = Future.value();
  _TestPreferences(this.file, Map<String, Object> values) : super.withData(values);
  Future<bool> _persist(bool result) async {
    final bytes = jsonEncode(await getAll());
    _writes = _writes.then((_) async {
      final partial = File('${file.path}.part');
      await partial.writeAsString(bytes, flush: true);
      await partial.rename(file.path);
    });
    await _writes;
    return result;
  }
  @override
  Future<bool> setValue(String valueType, String key, Object value) async => _persist(await super.setValue(valueType, key, value));
  @override
  Future<bool> remove(String key) async => _persist(await super.remove(key));
  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async => _persist(await super.clearWithParameters(parameters));
}

/// A first rendered frame after normal initialization acknowledges a Windows
/// install. Network playback is deliberately not a prerequisite for startup.
Future<void> acknowledgeUpdateStartup(List<String> args) async {
  if (!Platform.isWindows) return;
  String? value(String prefix) {
    final matches = args.where((arg) => arg.startsWith(prefix));
    return matches.length == 1 ? matches.single.substring(prefix.length) : null;
  }
  final health = value('--resonance-update-health=');
  final token = value('--resonance-update-token=');
  if (health == null || token == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(token)) return;
  final file = File(health);
  // Only acknowledge the helper's staging directory, never arbitrary files.
  final temporary = PathProviderPlatform.instance;
  final temp = await temporary.getTemporaryPath();
  if (temp == null || !p.isWithin(p.join(temp, 'resonance-update'), file.path) || p.basename(file.path) != 'healthy.json') return;
  await file.writeAsString(jsonEncode({'token': token, 'pid': pid}), flush: true);
}

/// Explicit automation entry for the isolated lab build, absent in production.
Future<void> runRequestedUpdateLab(List<String> args) async {
  if (!updateTestMode) return;
  var requested = args.contains('--resonance-update-lab-install');
  if (Platform.isAndroid) {
    requested = await const MethodChannel('resonance/app_update').invokeMethod<bool>('testAutoInstallRequested') ?? false;
  }
  if (!requested) return;
  final report = File(p.join((await getApplicationSupportDirectory()).path, 'update-lab-result.json'));
  Future<void> record(Map<String, Object?> value) async {
    await report.writeAsString(jsonEncode(value), flush: true);
    if (Platform.isAndroid) await const MethodChannel('resonance/app_update').invokeMethod<void>('testRecordResult', value);
  }
  try {
    final update = await AppUpdateService().check(force: true);
    if (update == null) {
      await record({'state': 'no-update'});
      return;
    }
    await record({'state': 'verified', 'version': update.version.toString(), 'delta': update.delta != null,
      'downloadBytes': update.asset.size, 'fullBytes': update.manifest!.full.size});
    await AppUpdateService().install(update);
  } catch (error) {
    await record({'state': 'rejected', 'error': error.toString()});
  }
}
