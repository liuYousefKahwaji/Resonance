import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:resonance/core/youtube/youtube_access_models.dart';

class WindowsCookieLease {
  WindowsCookieLease(this.path);
  final String path;
  Future<void> close() async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A bounded startup cleanup in the helper handles leftover crash leases.
    }
  }
}

class WindowsChromiumConnection {
  const WindowsChromiumConnection(this.source, this.extensionDirectory);
  final String source, extensionDirectory;
}

/// Chromium's cookie API supplies the session via the user's installed
/// extension. This never opens, decrypts or changes a browser cookie database.
class WindowsChromiumConnector {
  WindowsChromiumConnector({String? helperPath, String? directory})
    : helperPath = helperPath ?? p.join(p.dirname(Platform.resolvedExecutable), 'bin', 'resonance-ytmusic-home.exe'),
      directory = directory ?? p.join(Platform.environment['LOCALAPPDATA'] ?? '', 'Resonance', 'BrowserConnector');
  final String helperPath, directory;
  static const extensionId = 'ijekcmdjbphddbjhkedmhjaampmjaogp';
  static const hostName = 'com.resonance.youtube';
  static final _source = RegExp(r'^(chrome|edge|brave|vivaldi|opera|chromium|whale)\+connector:([a-f0-9]{32})$');

  static bool isSource(String? value) => value != null && _source.hasMatch(value);
  static bool supports(String browser) =>
      const {'chrome', 'edge', 'brave', 'vivaldi', 'opera', 'chromium', 'whale'}.contains(browser);

  Future<WindowsChromiumConnection> begin(String browser) async {
    if (!Platform.isWindows || !supports(browser) || !await File(helperPath).exists()) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.unsupported,
        userMessage: 'The browser connector is missing. Reinstall or update Resonance.',
      );
    }
    final folder = Directory(p.join(directory, 'extension'));
    await folder.create(recursive: true);
    for (final name in ['manifest.json', 'background.js', 'popup.html', 'popup.js', 'icon.png']) {
      final asset = await rootBundle.load('assets/browser_connector/$name');
      await File(
        p.join(folder.path, name),
      ).writeAsBytes(asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes), flush: true);
    }
    final manifest = File(p.join(directory, '$hostName.json'));
    await manifest.writeAsString(
      jsonEncode({
        'name': hostName,
        'description': 'Resonance YouTube Connector',
        'path': p.absolute(helperPath),
        'type': 'stdio',
        'allowed_origins': ['chrome-extension://$extensionId/'],
      }),
      flush: true,
    );
    // Chromium forks use Chrome's registration fallback; Edge also has its
    // own host lookup. Only HKCU is modified; installation needs no admin.
    for (final vendor in [r'Google\Chrome', r'Microsoft\Edge', r'BraveSoftware\Brave-Browser', 'Chromium']) {
      final result = await Process.run('reg.exe', [
        'add',
        'HKCU\\Software\\$vendor\\NativeMessagingHosts\\$hostName',
        '/ve',
        '/t',
        'REG_SZ',
        '/d',
        manifest.path,
        '/f',
      ], runInShell: false);
      if (result.exitCode != 0) {
        throw const YoutubeFailure(
          kind: YoutubeFailureKind.unsupported,
          userMessage: 'Windows could not register the browser connector.',
        );
      }
    }
    final random = Random.secure();
    final ticket = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final source = '$browser+connector:$ticket';
    await File(p.join(directory, '$ticket.permit.json')).writeAsString(
      jsonEncode({
        'source': source,
        'browser': browser,
        'created': DateTime.now().millisecondsSinceEpoch / 1000,
        'state': 'pending',
      }),
      flush: true,
    );
    return WindowsChromiumConnection(source, folder.path);
  }

  Future<Map<String, dynamic>> _invoke(String command, String source) async {
    if (!isSource(source)) throw const FormatException('Invalid browser connection.');
    final process = await Process.start(helperPath, [
      '--connector-tool',
      command,
      '--source',
      source,
    ], runInShell: false);
    try {
      final outputs = await Future.wait<Object>([
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.transform(utf8.decoder).join(),
        process.exitCode,
      ]).timeout(const Duration(seconds: 15));
      if (outputs[2] != 0) {
        throw const YoutubeFailure(
          kind: YoutubeFailureKind.verificationRequired,
          userMessage:
              'Sign in to YouTube, open the Resonance browser connector and press Connect, then test access again.',
        );
      }
      return Map<String, dynamic>.from(jsonDecode(outputs[0] as String) as Map);
    } catch (_) {
      process.kill();
      rethrow;
    }
  }

  Future<void> activate(String source) async {
    await _invoke('activate', source);
  }

  Future<void> revoke(String source) async {
    try {
      await _invoke('revoke', source);
    } catch (_) {
      // Disconnect still invalidates authorization if the installed helper
      // was moved or removed. An orphan encrypted snapshot cannot authorize.
      final ticket = _source.firstMatch(source)?.group(2);
      if (ticket == null) return;
      for (final suffix in ['.permit.json', '.session']) {
        final file = File(p.join(directory, '$ticket$suffix'));
        if (await file.exists()) await file.delete();
      }
    }
  }

  Future<WindowsCookieLease> materialize(String source) async {
    final result = await _invoke('export', source);
    final path = result['path']?.toString();
    if (path == null || !p.isWithin(p.join(directory, 'leases'), path) || !await File(path).exists()) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.verificationRequired,
        userMessage: 'Reconnect the Resonance browser connector.',
      );
    }
    return WindowsCookieLease(path);
  }
}
