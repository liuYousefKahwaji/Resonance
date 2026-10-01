import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:resonance/services/update_manifest.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:resonance/services/verified_update_downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:resonance/services/update_manifest.dart';

const latestResonanceReleaseUrl = 'https://api.github.com/repos/liuYousefKahwaji/Resonance/releases/latest';

class AvailableUpdate {
  final AppVersion version;
  final String notes;
  final UpdateAsset asset;
  final SignedUpdateManifest? manifest;
  final UpdateDelta? delta;

  const AvailableUpdate({required this.version, required this.notes, required this.asset, this.manifest, this.delta});

  static AvailableUpdate? fromReleaseJson(Map<String, dynamic> release, AppVersion installed, {required bool android}) {
    final tag = release['tag_name'];
    final version = tag is String ? AppVersion.parse(tag) : null;
    if (version == null ||
        version.compareTo(installed) <= 0 ||
        release['draft'] == true ||
        release['prerelease'] == true) {
      return null;
    }
    final rawAssets = release['assets'];
    if (rawAssets is! List) return null;
    final assets = rawAssets.map(UpdateAsset.fromJson).whereType<UpdateAsset>().toList();
    final candidates = android
        ? assets.where((asset) => asset.name.toLowerCase().endsWith('.apk'))
        : assets.where(
            (asset) =>
                asset.name.toLowerCase().endsWith('.zip') &&
                asset.name.toLowerCase().contains('windows') &&
                !asset.name.contains('.delta.'),
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

  Future<AvailableUpdate?> check({bool force = false}) async {
    if (!Platform.isAndroid && !Platform.isWindows) return null;
    final package = await PackageInfo.fromPlatform();
    final installed = AppVersion.parse(package.version);
    if (installed == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final checked = prefs.getInt('update_last_checked') ?? 0;
    if (!force &&
        !updateTestMode &&
        DateTime.now().millisecondsSinceEpoch - checked < const Duration(hours: 6).inMilliseconds) {
      return null;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(updateTestMode ? updateTestFeed : latestResonanceReleaseUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'Resonance/${package.version}');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final etag = prefs.getString('update_release_etag');
      if (!updateTestMode && etag != null) request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.notModified) {
        throw HttpException('Update server returned ${response.statusCode}');
      }
      final body = response.statusCode == HttpStatus.notModified
          ? prefs.getString('update_release_json') ?? ''
          : utf8.decode(await _readBounded(response, 512 * 1024));
      final release = jsonDecode(body);
      if (release is! Map<String, dynamic>) throw const FormatException('Invalid release data');
      final latest = AppVersion.parse('${release['tag_name'] ?? ''}');
      if (latest == null || release['draft'] == true || release['prerelease'] == true) return null;
      if (latest.compareTo(installed) <= 0) {
        await prefs.setInt('update_last_checked', DateTime.now().millisecondsSinceEpoch);
        return null;
      }
      final rawAssets = release['assets'];
      if (rawAssets is! List) throw const FormatException('Missing release assets');
      final assets = <String, UpdateAsset>{};
      for (final raw in rawAssets) {
        final asset = UpdateAsset.fromJson(raw, testMode: updateTestMode);
        if (asset != null) {
          if (assets.containsKey(asset.name)) throw const FormatException('Duplicate release asset');
          assets[asset.name] = asset;
        }
      }
      final manifestAsset = assets['resonance-v$latest-update.json'];
      final signatureAsset = assets['resonance-v$latest-update.sig'];
      if (manifestAsset == null || signatureAsset == null) {
        throw const FormatException('This release is missing signed update metadata');
      }
      final manifest = await SignedUpdateManifest.verify(
        bytes: await _fetchMetadata(client, manifestAsset, 512 * 1024),
        signatureBytes: await _fetchMetadata(client, signatureAsset, 1024),
        trustedKeys: await SignedUpdateManifest.loadKeys(),
        assets: assets,
        android: Platform.isAndroid,
      );
      if (manifest.version.compareTo(latest) != 0 ||
          manifest.buildNumber <= (int.tryParse(package.buildNumber) ?? 0)) {
        throw const FormatException('Signed release version does not match this update');
      }
      UpdateDelta? selected;
      for (final delta in manifest.deltas) {
        if (delta.fromVersion.compareTo(installed) != 0) continue;
        if (Platform.isAndroid) {
          final identity = await _androidChannel.invokeMapMethod<String, dynamic>('installedUpdateIdentity');
          if (identity?['packageName'] != manifest.packageName ||
              identity?['signingCertSha256'] != manifest.signingCert) {
            throw const FormatException('Installed Android identity differs from release');
          }
          if (identity?['sourceApkSha256'] == delta.sourceHash && identity?['hasSplits'] == false) selected = delta;
        } else {
          final target = Directory(p.dirname(Platform.resolvedExecutable));
          final installedFile = File(p.join(target.path, 'resonance-install.json'));
          try {
            final source = WindowsFileManifest.parse(await installedFile.readAsBytes());
            if (source.version.compareTo(installed) == 0 &&
                source.treeHash == delta.sourceHash &&
                await source.matches(target)) {
              selected = delta;
            }
          } on FileSystemException {
            /* Unknown installation: use signed full. */
          } on FormatException {
            /* Edited installation: use signed full. */
          }
        }
        break;
      }
      if (!updateTestMode) {
        await prefs.setString('update_release_json', body);
        final newEtag = response.headers.value(HttpHeaders.etagHeader);
        if (newEtag != null) await prefs.setString('update_release_etag', newEtag);
        await prefs.setInt('update_last_checked', DateTime.now().millisecondsSinceEpoch);
      }
      return AvailableUpdate(
        version: manifest.version,
        notes: manifest.notes,
        asset: selected?.asset ?? manifest.full,
        manifest: manifest,
        delta: selected,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<int>> _readBounded(HttpClientResponse response, int limit) async {
    final result = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      if (result.length + chunk.length > limit) throw const FormatException('Update metadata exceeds limit');
      result.addAll(chunk);
    }
    return result;
  }

  Future<List<int>> _fetchMetadata(HttpClient client, UpdateAsset asset, int limit) async {
    if (asset.size > limit) throw const FormatException('Oversized signed metadata');
    final request = await client.getUrl(asset.url).timeout(const Duration(seconds: 12));
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw HttpException('Metadata returned ${response.statusCode}');
    final bytes = await _readBounded(response, limit);
    if (bytes.length != asset.size || sha256.convert(bytes).toString() != asset.sha256) {
      throw const FormatException('Metadata download failed verification');
    }
    return bytes;
  }

  Future<void> install(
    AvailableUpdate update, {
    void Function(UpdateDownloadProgress)? onProgress,
    UpdateDownloadController? controller,
  }) async {
    final manifest = update.manifest;
    if (manifest == null) throw const FormatException('Signed update metadata is required');
    if (Platform.isAndroid) {
      await _androidChannel.invokeMethod<void>('downloadAndInstall', {
        'url': update.asset.url.toString(),
        'sha256': update.asset.sha256,
        'version': update.version.toString(),
        'size': update.asset.size,
        'full': manifest.full.toChannel(),
        'sourceApkSha256': update.delta?.sourceHash,
        'targetApkSha256': update.manifest?.full.sha256,
        'algorithm': update.delta?.algorithm,
        'packageName': update.manifest?.packageName,
        'signingCertSha256': update.manifest?.signingCert,
        'buildNumber': update.manifest?.buildNumber,
      });
      return;
    }
    if (!Platform.isWindows) throw UnsupportedError('Updates are available only on Android and Windows');
    final target = p.dirname(Platform.resolvedExecutable);
    final probe = File(p.join(target, '.resonance-update-${DateTime.now().microsecondsSinceEpoch}.tmp'));
    try {
      await probe.writeAsString('write check', flush: true);
    } finally {
      if (await probe.exists()) await probe.delete();
    }
    final temporary = (await getTemporaryDirectory()).path;
    final staging = await Directory(
      p.join(
        temporary,
        'resonance-update',
        '${update.version}-${DateTime.now().microsecondsSinceEpoch}',
      ),
    ).create(recursive: true);
    var payload = update.asset;
    var delta = update.delta;
    Future<File> downloadPayload(UpdateAsset asset) async {
      final cache = await Directory(p.join(temporary, 'resonance-update', 'download-${update.version}-${asset.sha256}')).create(recursive: true);
      final destination = File(p.join(cache.path, 'payload.zip'));
      await VerifiedUpdateDownloader().download(url: asset.url, size: asset.size, sha256Hex: asset.sha256,
          destination: destination, onProgress: onProgress, controller: controller);
      return destination;
    }
    File downloaded;
    try {
      downloaded = await downloadPayload(payload);
    } on UpdateDownloadCancelled {
      rethrow;
    } catch (_) {
      if (delta == null || controller?.isCancelled == true) rethrow;
      payload = manifest.full;
      delta = null;
      downloaded = await downloadPayload(payload);
    }
    final zip = await downloaded.copy(p.join(staging.path, 'payload.zip'));
    if (controller?.isCancelled == true) throw const UpdateDownloadCancelled();
    final filesAsset = manifest.windowsFiles!;
    final files = File(p.join(staging.path, 'target-files.json'));
    await VerifiedUpdateDownloader().download(
      url: filesAsset.url,
      size: filesAsset.size,
      sha256Hex: filesAsset.sha256,
      destination: files,
      controller: controller,
    );
    final targetFiles = WindowsFileManifest.parse(await files.readAsBytes());
    if (targetFiles.version.compareTo(update.version) != 0 ||
        (delta != null && targetFiles.treeHash != delta.targetHash)) {
      throw const FormatException('Target file tree mismatch');
    }
    final transaction = File(p.join(staging.path, 'transaction.json'));
    Future<void> writeTransaction() async {
      await transaction.writeAsString(jsonEncode({
        'schemaVersion': 1,
        'mode': delta == null ? 'full' : 'delta',
        'target': jsonDecode(await files.readAsString()),
        'sourceTreeSha256': delta?.sourceHash,
        'payloadSha256': payload.sha256,
        'full': manifest.full.toChannel(),
        'testMode': updateTestMode,
      }), flush: true);
    }
    await writeTransaction();
    final script = File(p.join(staging.path, 'apply-update.ps1'));
    await script.writeAsString(await rootBundle.loadString('assets/windows/apply_update_transaction.ps1'), flush: true);
    if (controller?.isCancelled == true) throw const UpdateDownloadCancelled();
    final arguments = [
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
      '-Transaction',
      transaction.path,
    ];
    Future<int> preflight() async {
      onProgress?.call(UpdateDownloadProgress(payload.size, payload.size, verifying: true));
      final result = await Process.run('powershell.exe', [...arguments, '-PreflightOnly']);
      if (controller?.isCancelled == true) throw const UpdateDownloadCancelled();
      return result.exitCode;
    }
    var checked = await preflight();
    if (checked == 10 && delta != null) {
      payload = manifest.full;
      delta = null;
      downloaded = await downloadPayload(payload);
      await downloaded.copy(zip.path);
      await writeTransaction();
      checked = await preflight();
    }
    if (checked != 0) throw FileSystemException('Update preflight failed; see update.log', staging.path);
    final process = await Process.start('powershell.exe', arguments, mode: ProcessStartMode.normal);
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
}
