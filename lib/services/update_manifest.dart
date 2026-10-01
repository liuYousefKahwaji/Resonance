import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as signing;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class AppVersion implements Comparable<AppVersion> {
  final int major;
  final int minor;
  final int patch;
  const AppVersion(this.major, this.minor, this.patch);

  static AppVersion? parse(String text) {
    final match = RegExp(r'^(?:[vV]\.?)?(\d+)\.(\d+)\.(\d+)$').firstMatch(text.trim());
    return match == null ? null : AppVersion(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
  }

  @override
  int compareTo(AppVersion other) {
    for (final pair in [(major, other.major), (minor, other.minor), (patch, other.patch)]) {
      if (pair.$1 != pair.$2) return pair.$1.compareTo(pair.$2);
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch';
}

const updateTestMode = bool.fromEnvironment('RESONANCE_UPDATE_TEST');
const updateTestFeed = String.fromEnvironment(
  'RESONANCE_UPDATE_TEST_FEED',
  defaultValue: 'http://127.0.0.1:8765/release.json',
);
const updateTestPublicKey = String.fromEnvironment('RESONANCE_UPDATE_TEST_KEY');
const resonanceSigningCert = 'd504a82e662a5a2596607084b2b64d84170519c3193fc7d7cc915bdfdc794fba';

bool isAllowedUpdateUrl(Uri uri, {bool testMode = false}) {
  if (uri.userInfo.isNotEmpty || uri.hasFragment) return false;
  if (testMode) return uri.scheme == 'http' && const {'127.0.0.1', 'localhost', '10.0.2.2'}.contains(uri.host);
  return uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.path.startsWith('/liuYousefKahwaji/Resonance/releases/download/');
}

class UpdateAsset {
  final Uri url;
  final String name;
  final String sha256;
  final int size;
  const UpdateAsset({required this.url, required this.name, required this.sha256, required this.size});

  static UpdateAsset? fromJson(Object? value, {bool testMode = false}) {
    if (value is! Map<String, dynamic>) return null;
    final name = value['name'], digest = value['digest'], rawUrl = value['browser_download_url'], size = value['size'];
    if (name is! String ||
        digest is! String ||
        rawUrl is! String ||
        size is! int ||
        size <= 0 ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) {
      return null;
    }
    final url = Uri.tryParse(rawUrl);
    final match = RegExp(r'^sha256:([0-9a-fA-F]{64})$').firstMatch(digest);
    if (url == null || !isAllowedUpdateUrl(url, testMode: testMode) || match == null) return null;
    return UpdateAsset(url: url, name: name, sha256: match[1]!.toLowerCase(), size: size);
  }

  Map<String, Object> toChannel() => {'url': url.toString(), 'sha256': sha256, 'size': size};
}

class UpdateDelta {
  final UpdateAsset asset;
  final AppVersion fromVersion;
  final String sourceHash;
  final String targetHash;
  final String algorithm;
  const UpdateDelta({
    required this.asset,
    required this.fromVersion,
    required this.sourceHash,
    required this.targetHash,
    required this.algorithm,
  });
}

class SignedUpdateManifest {
  final AppVersion version;
  final int buildNumber;
  final String notes;
  final UpdateAsset full;
  final UpdateAsset? windowsFiles;
  final List<UpdateDelta> deltas;
  final String? packageName;
  final String? signingCert;
  const SignedUpdateManifest({
    required this.version,
    required this.buildNumber,
    required this.notes,
    required this.full,
    required this.windowsFiles,
    required this.deltas,
    this.packageName,
    this.signingCert,
  });

  static Future<SignedUpdateManifest> verify({
    required List<int> bytes,
    required List<int> signatureBytes,
    required Map<String, String> trustedKeys,
    required Map<String, UpdateAsset> assets,
    required bool android,
  }) async {
    if (bytes.length > 512 * 1024 || signatureBytes.length > 1024) {
      throw const FormatException('Update metadata is too large');
    }
    final signature = jsonDecode(utf8.decode(signatureBytes));
    if (signature is! Map || signature['keyId'] is! String || signature['signature'] is! String) {
      throw const FormatException('Invalid update signature');
    }
    final key = trustedKeys[signature['keyId']];
    if (key == null ||
        base64Decode(key).length != 32 ||
        base64Decode(signature['signature']).length != 64 ||
        !await signing.Ed25519().verify(
          bytes,
          signature: signing.Signature(
            base64Decode(signature['signature']),
            publicKey: signing.SimplePublicKey(base64Decode(key), type: signing.KeyPairType.ed25519),
          ),
        )) {
      throw const FormatException('Update signature could not be verified');
    }
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map || json['schemaVersion'] != 1) throw const FormatException('Unsupported update manifest');
    final release = json['release'];
    final section = json[android ? 'android' : 'windows'];
    if (release is! Map ||
        section is! Map ||
        release['version'] is! String ||
        release['buildNumber'] is! int ||
        release['buildNumber'] <= 0 ||
        release['notes'] is! String ||
        section['full'] is! Map ||
        section['deltas'] is! List) {
      throw const FormatException('Incomplete update manifest');
    }
    final version = AppVersion.parse(release['version']);
    if (version == null || AppVersion.parse('${release['tag']}')?.compareTo(version) != 0) {
      throw const FormatException('Update version mismatch');
    }
    UpdateAsset resolve(Object? raw) {
      if (raw is! Map || raw['name'] is! String || raw['sha256'] is! String || raw['size'] is! int) {
        throw const FormatException('Invalid signed asset');
      }
      final asset = assets[raw['name']];
      if (asset == null || asset.sha256 != raw['sha256'] || asset.size != raw['size']) {
        throw const FormatException('Release asset does not match signed metadata');
      }
      return asset;
    }

    final full = resolve(section['full']);
    final files = android ? null : resolve(section['fileManifest']);
    if (full.name != 'resonance-v$version${android ? '.apk' : '-windows.zip'}' ||
        (!android && files!.name != 'resonance-v$version-windows.files.json')) {
      throw const FormatException('Unexpected canonical package name');
    }
    if (android &&
        (section['full']['versionCode'] != release['buildNumber'] ||
            section['full']['signingCertSha256'] != resonanceSigningCert ||
            section['full']['packageName'] != (updateTestMode ? 'com.example.resonance.updatertest' : 'com.example.resonance'))) {
      throw const FormatException('Android identity mismatch');
    }
    final deltas = <UpdateDelta>[];
    final sources = <String>{};
    if (section['deltaEnabled'] != false) {
      for (final raw in section['deltas']) {
        if (raw is! Map || raw['fromVersion'] is! String) throw const FormatException('Invalid delta');
        final from = AppVersion.parse(raw['fromVersion']);
        final source = raw[android ? 'sourceApkSha256' : 'sourceTreeSha256'];
        final target = raw[android ? 'targetApkSha256' : 'targetTreeSha256'];
        final algorithm = android ? raw['algorithm'] : 'windows-files-v1';
        if (from == null ||
            from.compareTo(version) >= 0 ||
            !sources.add(from.toString()) ||
            source is! String ||
            target is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(source) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(target) ||
            (android && target != full.sha256)) {
          throw const FormatException('Invalid delta identity');
        }
        // Unknown patch algorithms may be skipped, but never interpreted as a
        // different format. The signed full package remains available.
        if (android && algorithm != 'xdelta3-vcdiff') continue;
        final asset = resolve(raw);
        if (asset.size < full.size * 0.7) {
          deltas.add(
            UpdateDelta(asset: asset, fromVersion: from, sourceHash: source, targetHash: target, algorithm: algorithm),
          );
        }
      }
    }
    return SignedUpdateManifest(
      version: version,
      buildNumber: release['buildNumber'],
      notes: release['notes'],
      full: full,
      windowsFiles: files,
      deltas: List.unmodifiable(deltas),
      packageName: android ? section['full']['packageName'] : null,
      signingCert: android ? section['full']['signingCertSha256'] : null,
    );
  }

  static Future<Map<String, String>> loadKeys() async {
    if (updateTestMode) {
      if (updateTestPublicKey.isEmpty) throw const FormatException('Test signing key is missing');
      return {'resonance-test': updateTestPublicKey};
    }
    final value = jsonDecode(await rootBundle.loadString('assets/update/trusted_keys.json'));
    return Map<String, String>.from(value['keys']);
  }
}

String safeUpdatePath(String name) {
  if (name.isEmpty ||
      name.contains('\\') ||
      name.contains(':') ||
      name.contains('\x00') ||
      name.startsWith('/') ||
      p.posix.normalize(name) != name ||
      name
          .split('/')
          .any(
            (part) =>
                part == '..' ||
                part == '.' ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\..*)?$', caseSensitive: false).hasMatch(part),
          )) {
    throw const FormatException('Unsafe update path');
  }
  return name;
}

class WindowsFileManifest {
  final AppVersion version;
  final List<Map<String, dynamic>> files;
  final String treeHash;
  const WindowsFileManifest(this.version, this.files, this.treeHash);

  factory WindowsFileManifest.parse(List<int> bytes) {
    if (bytes.length > 1024 * 1024) throw const FormatException('File manifest is too large');
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map || json['schemaVersion'] != 1 || json['files'] is! List) {
      throw const FormatException('Invalid file manifest');
    }
    final version = AppVersion.parse('${json['version']}');
    if (version == null) throw const FormatException('Invalid file version');
    final files = <Map<String, dynamic>>[];
    final seen = <String>{};
    String? previous;
    for (final raw in json['files']) {
      if (raw is! Map ||
          raw['path'] is! String ||
          raw['size'] is! int ||
          raw['size'] < 0 ||
          raw['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['sha256'])) {
        throw const FormatException('Invalid file entry');
      }
      final path = safeUpdatePath(raw['path']);
      if (!seen.add(path.toLowerCase()) || (previous != null && previous.compareTo(path) >= 0)) {
        throw const FormatException('Duplicate or unsorted managed paths');
      }
      previous = path;
      files.add(Map<String, dynamic>.from(raw));
    }
    final calculated = sha256
        .convert(utf8.encode(files.map((f) => '${f['path']}\x00${f['size']}\x00${f['sha256']}\n').join()))
        .toString();
    if (calculated != json['treeSha256']) throw const FormatException('File tree hash mismatch');
    return WindowsFileManifest(version, List.unmodifiable(files), calculated);
  }

  Future<bool> matches(Directory root) async {
    try {
      final resolvedRoot = await root.resolveSymbolicLinks();
      for (final entry in files) {
        final file = File(p.join(root.path, entry['path']));
        // Reject reparse-point parents that could send writes outside install.
        final resolved = await file.resolveSymbolicLinks();
        if (!p.isWithin(resolvedRoot, resolved) ||
            await file.length() != entry['size'] ||
            (await sha256.bind(file.openRead()).first).toString() != entry['sha256']) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
