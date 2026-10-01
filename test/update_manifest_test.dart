import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as signing;
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/update_manifest.dart';

void main() {
  late signing.SimpleKeyPair pair;
  late Map<String, String> keys;
  late Map<String, UpdateAsset> assets;
  late Map<String, dynamic> manifest;
  final algorithm = signing.Ed25519();
  final zero = '0' * 64;
  setUp(() async {
    pair = await algorithm.newKeyPairFromSeed(List.generate(32, (i) => i));
    keys = {'test': base64Encode((await pair.extractPublicKey()).bytes)};
    assets = {};
    Map<String, Object> asset(String name, int size) {
      assets[name] = UpdateAsset(name: name, sha256: zero, size: size,
          url: Uri.parse('https://github.com/liuYousefKahwaji/Resonance/releases/download/v3.4.6/$name'));
      return {'name': name, 'sha256': zero, 'size': size};
    }
    manifest = {
      'schemaVersion': 1,
      'release': {'version': '3.4.6', 'tag': 'v.3.4.6', 'buildNumber': 13, 'notes': '# New release'},
      'android': {
        'full': {...asset('resonance-v3.4.6.apk', 1000), 'packageName': 'com.example.resonance',
          'signingCertSha256': resonanceSigningCert, 'versionCode': 13},
        'deltas': [{...asset('resonance-v3.4.5-to-v3.4.6-android.xdelta', 100),
          'fromVersion': '3.4.5', 'sourceApkSha256': zero, 'targetApkSha256': zero, 'algorithm': 'xdelta3-vcdiff'}],
      },
      'windows': {
        'full': asset('resonance-v3.4.6-windows.zip', 1000),
        'fileManifest': asset('resonance-v3.4.6-windows.files.json', 100),
        'deltas': [{...asset('resonance-v3.4.5-to-v3.4.6-windows.delta.zip', 100),
          'fromVersion': '3.4.5', 'sourceTreeSha256': zero, 'targetTreeSha256': zero}],
      },
    };
  });
  Future<SignedUpdateManifest> verify({bool android = true, bool tamper = false, String keyId = 'test'}) async {
    final bytes = utf8.encode(jsonEncode(manifest));
    final signature = await algorithm.sign(bytes, keyPair: pair);
    return SignedUpdateManifest.verify(bytes: tamper ? [...bytes, 32] : bytes,
        signatureBytes: utf8.encode(jsonEncode({'keyId': keyId, 'signature': base64Encode(signature.bytes)})),
        trustedKeys: keys, assets: assets, android: android);
  }
  test('verified Android and Windows metadata selects direct patches', () async {
    expect((await verify()).deltas.single.fromVersion.toString(), '3.4.5');
    expect((await verify(android: false)).windowsFiles!.name, endsWith('.files.json'));
  });
  test('modified metadata fails even when JSON remains valid', () async {
    await expectLater(verify(tamper: true), throwsFormatException);
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
    expect(isAllowedUpdateUrl(Uri.parse('https://github.com@evil.com/liuYousefKahwaji/Resonance/releases/download/v1/a.apk')), isFalse);
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
    final raw = {'schemaVersion': 1, 'version': '3.4.5', 'treeSha256': tree,
      'files': [{'path': 'app.dll', 'size': 8, 'sha256': hash}]};
    final parsed = WindowsFileManifest.parse(utf8.encode(jsonEncode(raw)));
    expect(await parsed.matches(root), isTrue);
    await File('${root.path}/app.dll').writeAsString('tampered');
    expect(await parsed.matches(root), isFalse);
  });
}
