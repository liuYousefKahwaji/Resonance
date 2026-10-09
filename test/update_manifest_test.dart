import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as signing;
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  late signing.SimpleKeyPair pair;
  late Map<String, String> keys;
  late Map<String, UpdateAsset> assets;
  late Map<String, dynamic> manifest;
  final algorithm = signing.Ed25519();
  final zero = '0' * 64;
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    pair = await algorithm.newKeyPairFromSeed(List.generate(32, (i) => i));
    keys = {'test': base64Encode((await pair.extractPublicKey()).bytes)};
    assets = {};
    Map<String, Object> asset(String name, int size) {
      assets[name] = UpdateAsset(
        name: name,
        sha256: zero,
        size: size,
        url: Uri.parse('https://github.com/liuYousefKahwaji/Resonance/releases/download/v3.4.6/$name'),
      );
      return {'name': name, 'sha256': zero, 'size': size};
    }

    manifest = {
      'schemaVersion': 1,
      'release': {'version': '3.4.6', 'tag': 'v.3.4.6', 'buildNumber': 13, 'notes': '# New release'},
      'android': {
        'full': {
          ...asset('resonance-v3.4.6.apk', 1000),
          'packageName': 'com.example.resonance',
          'signingCertSha256': resonanceSigningCert,
          'versionCode': 13,
        },
        'deltas': [
          {
            ...asset('resonance-v3.4.5-to-v3.4.6-android.xdelta', 100),
            'fromVersion': '3.4.5',
            'sourceApkSha256': zero,
            'targetApkSha256': zero,
            'algorithm': 'xdelta3-vcdiff',
          },
        ],
      },
      'windows': {
        'full': asset('resonance-v3.4.6-windows.zip', 1000),
        'fileManifest': asset('resonance-v3.4.6-windows.files.json', 100),
        'deltas': [
          {
            ...asset('resonance-v3.4.5-to-v3.4.6-windows.delta.zip', 100),
            'fromVersion': '3.4.5',
            'sourceTreeSha256': zero,
            'targetTreeSha256': zero,
          },
        ],
      },
    };
  });
  Future<SignedUpdateManifest> verify({bool android = true, bool tamper = false, String keyId = 'test'}) async {
    final bytes = utf8.encode(jsonEncode(manifest));
    final signature = await algorithm.sign(bytes, keyPair: pair);
    return SignedUpdateManifest.verify(
      bytes: tamper ? [...bytes, 32] : bytes,
      signatureBytes: utf8.encode(jsonEncode({'keyId': keyId, 'signature': base64Encode(signature.bytes)})),
      trustedKeys: keys,
      assets: assets,
      android: android,
    );
  }

  test('verified Android and Windows metadata selects direct patches', () async {
    expect((await verify()).deltas.single.fromVersion.toString(), '3.4.5');
    expect((await verify(android: false)).windowsFiles!.name, endsWith('.files.json'));
  });
  test('update information uses the selected patch and signed full download size', () async {
    final signed = await verify(android: false);
    final patch = signed.deltas.single;
    final update = AvailableUpdate(
      version: signed.version,
      notes: signed.notes,
      asset: patch.asset,
      manifest: signed,
      delta: patch,
    );
    expect(update.asset.size, 100);
    expect(update.fullDownloadBytes, 1000);
    expect(update.savedDownloadBytes, 900);
    expect(update.downloadSavingsPercent, 90);
    final full = AvailableUpdate(version: signed.version, notes: signed.notes, asset: signed.full, manifest: signed);
    expect(full.savedDownloadBytes, 0);
    expect(full.downloadSavingsPercent, 0);
  });
  test('modified metadata fails even when JSON remains valid', () async {
    await expectLater(verify(tamper: true), throwsFormatException);
  });
  test('cooldown retains verified availability across restart and rejects altered cache', () async {
    final bytes = utf8.encode(jsonEncode(manifest));
    final signature = await algorithm.sign(bytes, keyPair: pair);
    final signatureBytes = utf8.encode(jsonEncode({'keyId': 'test', 'signature': base64Encode(signature.bytes)}));
    for (final name in ['resonance-v3.4.6-update.json', 'resonance-v3.4.6-update.sig']) {
      assets[name] = UpdateAsset(
        name: name,
        sha256: zero,
        size: 100,
        url: Uri.parse('https://github.com/liuYousefKahwaji/Resonance/releases/download/v3.4.6/$name'),
      );
    }
    PackageInfo.setMockInitialValues(
      appName: 'Resonance',
      packageName: 'com.example.resonance',
      version: '3.4.5',
      buildNumber: '12',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({
      'update_last_checked': DateTime.now().millisecondsSinceEpoch,
      'update_release_json': jsonEncode({
        'tag_name': 'v3.4.6',
        'assets': [
          for (final asset in assets.values)
            {
              'name': asset.name,
              'size': asset.size,
              'digest': 'sha256:${asset.sha256}',
              'browser_download_url': '${asset.url}',
            },
        ],
      }),
      'update_verified_manifest': base64Encode(bytes),
      'update_verified_signature': base64Encode(signatureBytes),
    });
    AppUpdateService.available.value = null;
    var loads = 0;
    final service = AppUpdateService(
      keyLoader: () async {
        loads++;
        return keys;
      },
    );
    final first = service.check(), overlapping = service.check();
    expect((await first)!.version.toString(), '3.4.6');
    expect(await overlapping, same(await first));
    expect(loads, 1);
    expect((await service.check())!.notes, '# New release');
    expect(loads, 1);
    AppUpdateService.available.value = null;
    expect((await service.check())!.version.toString(), '3.4.6');
    expect(loads, 2);
    AppUpdateService.available.value = null;
    await (await SharedPreferences.getInstance()).setString('update_verified_manifest', base64Encode([...bytes, 32]));
    await expectLater(service.check(), throwsFormatException);
    AppUpdateService.available.value = null;
  });
  test('unknown signing key fails closed', () async {
    await expectLater(verify(keyId: 'attacker'), throwsFormatException);
  });
  test('API asset digest must match signed identity', () async {
    final old = assets['resonance-v3.4.6.apk']!;
    assets[old.name] = UpdateAsset(name: old.name, url: old.url, size: old.size, sha256: '1' * 64);
    await expectLater(verify(), throwsFormatException);
  });
  test('unknown algorithm uses signed full package', () async {
    manifest['android']['deltas'][0]['algorithm'] = 'future-format';
    expect((await verify()).deltas, isEmpty);
  });
  test('duplicate bases and mismatched APK identity are rejected', () async {
    manifest['android']['deltas'].add(manifest['android']['deltas'][0]);
    await expectLater(verify(), throwsFormatException);
    manifest['android']['deltas'].removeLast();
    manifest['android']['full']['packageName'] = 'another.app';
    await expectLater(verify(), throwsFormatException);
  });
  test('large patches are skipped and explicit delta disable works', () async {
    final raw = manifest['android']['deltas'][0];
    raw['size'] = 800;
    final old = assets[raw['name']]!;
    assets[old.name] = UpdateAsset(name: old.name, url: old.url, size: 800, sha256: zero);
    expect((await verify()).deltas, isEmpty);
    manifest['windows']['deltaEnabled'] = false;
    expect((await verify(android: false)).deltas, isEmpty);
  });
  test('production accepts only own GitHub release URLs; local feed is test-only', () {
    expect(isAllowedUpdateUrl(Uri.parse('http://127.0.0.1:8765/app.apk')), isFalse);
    expect(isAllowedUpdateUrl(Uri.parse('http://127.0.0.1:8765/app.apk'), testMode: true), isTrue);
    expect(isAllowedUpdateUrl(Uri.parse('https://github.com/attacker/Resonance/releases/download/v1/a.apk')), isFalse);
    expect(
      isAllowedUpdateUrl(
        Uri.parse('https://github.com@evil.com/liuYousefKahwaji/Resonance/releases/download/v1/a.apk'),
      ),
      isFalse,
    );
  });
  test('unsafe managed Windows paths cannot be interpreted as file destinations', () {
    for (final name in ['../settings.json', '/app.dll', 'a\\b', 'C:/app.dll', 'NUL.txt', 'file.', 'a/../b', 'a//b']) {
      expect(() => safeUpdatePath(name), throwsFormatException, reason: name);
    }
  });
  test('managed tree validates real contents while allowing user files', () async {
    final root = await Directory.systemTemp.createTemp('resonance-tree-test');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/app.dll').writeAsString('original');
    await File('${root.path}/preferences.json').writeAsString('user data');
    final hash = sha256.convert(utf8.encode('original')).toString();
    final tree = sha256.convert(utf8.encode('app.dll\x008\x00$hash\n')).toString();
    final raw = {
      'schemaVersion': 1,
      'version': '3.4.5',
      'treeSha256': tree,
      'files': [
        {'path': 'app.dll', 'size': 8, 'sha256': hash},
      ],
    };
    final parsed = WindowsFileManifest.parse(utf8.encode(jsonEncode(raw)));
    expect(await parsed.matches(root), isTrue);
    await File('${root.path}/app.dll').writeAsString('tampered');
    expect(await parsed.matches(root), isFalse);
  });
}
