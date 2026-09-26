import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const latestResonanceReleaseUrl = 'https://api.github.com/repos/liuYousefKahwaji/Resonance/releases/latest';

class AppVersion implements Comparable<AppVersion> {
  final int major;
  final int minor;
  final int patch;

  const AppVersion(this.major, this.minor, this.patch);

  static AppVersion? parse(String text) {
    final match = RegExp(r'^(?:[vV]\.?)?(\d+)\.(\d+)\.(\d+)$').firstMatch(text.trim());
    if (match == null) return null;
    return AppVersion(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
  }

  @override
  int compareTo(AppVersion other) {
    final majorOrder = major.compareTo(other.major);
    if (majorOrder != 0) return majorOrder;
    final minorOrder = minor.compareTo(other.minor);
    if (minorOrder != 0) return minorOrder;
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch';
}

class UpdateAsset {
  final Uri url;
  final String name;
  final String sha256;
  final int size;

  const UpdateAsset({required this.url, required this.name, required this.sha256, required this.size});

  static UpdateAsset? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final name = value['name'];
    final digest = value['digest'];
    final rawUrl = value['browser_download_url'];
    final size = value['size'];
    if (name is! String || digest is! String || rawUrl is! String || size is! int) return null;
    final url = Uri.tryParse(rawUrl);
    if (url == null || url.scheme != 'https' || url.host != 'github.com') return null;
    final match = RegExp(r'^sha256:([0-9a-fA-F]{64})$').firstMatch(digest);
    if (match == null || size <= 0) return null;
    return UpdateAsset(url: url, name: name, sha256: match[1]!.toLowerCase(), size: size);
  }
}

class AvailableUpdate {
  final AppVersion version;
  final String notes;
  final UpdateAsset asset;

  const AvailableUpdate({required this.version, required this.notes, required this.asset});

  static AvailableUpdate? fromReleaseJson(Map<String, dynamic> release, AppVersion installed, {required bool android}) {
    final tag = release['tag_name'];
    final version = tag is String ? AppVersion.parse(tag) : null;
    if (version == null || version.compareTo(installed) <= 0 || release['draft'] == true) return null;
    final rawAssets = release['assets'];
    if (rawAssets is! List) return null;
    final assets = rawAssets.map(UpdateAsset.fromJson).whereType<UpdateAsset>().toList();
    final candidates = android
        ? assets.where((asset) => asset.name.toLowerCase().endsWith('.apk'))
        : assets.where(
            (asset) => asset.name.toLowerCase().endsWith('.zip') && asset.name.toLowerCase().contains('windows'),
          );
    if (candidates.isEmpty) return null;
    final matching = candidates.where((asset) {
      final embedded = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(asset.name)?.group(1);
      return embedded == null || AppVersion.parse(embedded)?.compareTo(version) == 0;
    }).toList();
    if (matching.isEmpty) return null;
    final asset = matching.first;
    return AvailableUpdate(
      version: version,
      notes: release['body'] is String ? release['body'] as String : '',
      asset: asset,
    );
  }
}

class AppUpdateService {
  static const _androidChannel = MethodChannel('resonance/app_update');

  Future<AvailableUpdate?> check() async {
    if (!Platform.isAndroid && !Platform.isWindows) return null;
    final package = await PackageInfo.fromPlatform();
    final installed = AppVersion.parse(package.version);
    if (installed == null) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(latestResonanceReleaseUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'Resonance/${package.version}');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok) throw HttpException('GitHub returned ${response.statusCode}');
      final body = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 12));
      final release = jsonDecode(body);
      if (release is! Map<String, dynamic>) throw const FormatException('Invalid release data');
      final available = AvailableUpdate.fromReleaseJson(release, installed, android: Platform.isAndroid);
      final latest = AppVersion.parse('${release['tag_name'] ?? ''}');
      if (available == null && latest != null && latest.compareTo(installed) > 0) {
        throw const FormatException('The latest release has no verified build for this device');
      }
      return available;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> install(AvailableUpdate update) async {
    if (Platform.isAndroid) {
      await _androidChannel.invokeMethod<void>('downloadAndInstall', {
        'url': update.asset.url.toString(),
        'sha256': update.asset.sha256,
        'version': update.version.toString(),
        'size': update.asset.size,
      });
      return;
    }
    if (!Platform.isWindows) throw UnsupportedError('Updates are available only on Android and Windows');
    final staging = await Directory(
      p.join((await getTemporaryDirectory()).path, 'resonance-update'),
    ).create(recursive: true);
    final zip = File(p.join(staging.path, 'resonance-${update.version}-windows.zip'));
    await _downloadVerified(update.asset, zip);
    final script = File(p.join(staging.path, 'apply-update.ps1'));
    await script.writeAsString(await rootBundle.loadString('assets/windows/apply_update.ps1'), flush: true);
    final target = p.dirname(Platform.resolvedExecutable);
    final probe = File(p.join(target, '.resonance-update-${DateTime.now().microsecondsSinceEpoch}.tmp'));
    try {
      await probe.writeAsString('write check', flush: true);
    } finally {
      if (await probe.exists()) await probe.delete();
    }
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      '-Zip',
      zip.path,
      '-Target',
      target,
      '-ParentPid',
      pid.toString(),
    ], mode: ProcessStartMode.detached);
    if (process.pid <= 0) throw ProcessException('powershell.exe', [], 'Could not start updater');
    exit(0);
  }

  Future<void> resumeAndroidInstall() async {
    if (Platform.isAndroid) await _androidChannel.invokeMethod<void>('resumePendingInstall');
  }

  Future<bool> canInstallAndroidUpdates() async {
    if (!Platform.isAndroid) return false;
    return await _androidChannel.invokeMethod<bool>('canInstallUpdates') ?? false;
  }

  Future<void> _downloadVerified(UpdateAsset asset, File destination) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final temporary = File('${destination.path}.part');
    try {
      final request = await client.getUrl(asset.url);
      request.headers.set(HttpHeaders.userAgentHeader, 'Resonance-Updater');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) throw HttpException('Download returned ${response.statusCode}');
      final sink = temporary.openWrite();
      await response.pipe(sink);
      if (await temporary.length() != asset.size) throw const FormatException('Update download size mismatch');
      final digest = await sha256.bind(temporary.openRead()).first;
      if (digest.toString() != asset.sha256) throw const FormatException('Update checksum mismatch');
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
    } finally {
      client.close(force: true);
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
