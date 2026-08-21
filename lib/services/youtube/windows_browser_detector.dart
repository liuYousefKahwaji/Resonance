import 'dart:io';

import 'package:path/path.dart' as p;

class WindowsBrowserChoice {
  const WindowsBrowserChoice(this.id, this.name);

  final String id;
  final String name;
}

class WindowsBrowserDetector {
  const WindowsBrowserDetector();

  static const supported = <WindowsBrowserChoice>[
    WindowsBrowserChoice('edge', 'Microsoft Edge'),
    WindowsBrowserChoice('chrome', 'Google Chrome'),
    WindowsBrowserChoice('firefox', 'Mozilla Firefox'),
    WindowsBrowserChoice('brave', 'Brave'),
    WindowsBrowserChoice('vivaldi', 'Vivaldi'),
    WindowsBrowserChoice('opera', 'Opera'),
    WindowsBrowserChoice('chromium', 'Chromium'),
    WindowsBrowserChoice('whale', 'Whale'),
  ];

  Future<String?> detectDefaultBrowser() async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run('reg.exe', const [
        'query',
        r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice',
        '/v',
        'ProgId',
      ], runInShell: false);
      if (result.exitCode != 0) return null;
      final match = RegExp(r'ProgId\s+REG_\w+\s+(.+)', caseSensitive: false).firstMatch(result.stdout.toString());
      final progId = match?.group(1)?.trim() ?? '';
      final direct = browserIdForProgId(progId);
      if (direct != null || progId.isEmpty) return direct;
      final command = await Process.run('reg.exe', [
        'query',
        'HKCR\\$progId\\shell\\open\\command',
        '/ve',
      ], runInShell: false);
      return command.exitCode == 0 ? browserIdForCommand(command.stdout.toString()) : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> launchBrowser(String browserId, String url) async {
    if (!Platform.isWindows || Uri.tryParse(url)?.scheme != 'https') return false;
    final executableName = const {
      'edge': 'msedge.exe',
      'chrome': 'chrome.exe',
      'firefox': 'firefox.exe',
      'brave': 'brave.exe',
      'vivaldi': 'vivaldi.exe',
      'opera': 'opera.exe',
      'chromium': 'chromium.exe',
      'whale': 'whale.exe',
    }[browserId];
    if (executableName == null) return false;
    final executable = await _findExecutable(executableName);
    if (executable == null) return false;
    try {
      await Process.start(executable, [url], runInShell: false, mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _findExecutable(String name) async {
    try {
      final result = await Process.run('where.exe', [name], runInShell: false);
      if (result.exitCode == 0) {
        for (final line in result.stdout.toString().split(RegExp(r'[\r\n]+'))) {
          final candidate = line.trim();
          if (candidate.isNotEmpty && await File(candidate).exists()) return candidate;
        }
      }
    } catch (_) {}
    final roots = <String>{
      if (Platform.environment['PROGRAMFILES'] case final value?) value,
      if (Platform.environment['PROGRAMFILES(X86)'] case final value?) value,
      if (Platform.environment['LOCALAPPDATA'] case final value?) value,
    };
    const relative = {
      'msedge.exe': [r'Microsoft\Edge\Application\msedge.exe'],
      'chrome.exe': [r'Google\Chrome\Application\chrome.exe'],
      'firefox.exe': [r'Mozilla Firefox\firefox.exe'],
      'brave.exe': [r'BraveSoftware\Brave-Browser\Application\brave.exe'],
      'vivaldi.exe': [r'Vivaldi\Application\vivaldi.exe'],
      'opera.exe': [r'Programs\Opera\opera.exe', r'Opera\launcher.exe'],
      'chromium.exe': [r'Chromium\Application\chromium.exe'],
      'whale.exe': [r'Naver\Naver Whale\Application\whale.exe'],
    };
    for (final root in roots) {
      for (final suffix in relative[name] ?? const <String>[]) {
        final candidate = p.join(root, suffix);
        if (await File(candidate).exists()) return candidate;
      }
    }
    return null;
  }

  static String? browserIdForProgId(String value) {
    final lower = value.toLowerCase();
    if (lower.startsWith('msedgehtm') || lower.contains('microsoftedge')) return 'edge';
    if (lower.startsWith('chromehtml')) return 'chrome';
    if (lower.contains('firefox')) return 'firefox';
    if (lower.contains('brave')) return 'brave';
    if (lower.contains('vivaldi')) return 'vivaldi';
    if (lower.contains('opera')) return 'opera';
    if (lower.contains('chromium')) return 'chromium';
    if (lower.contains('whale')) return 'whale';
    return browserIdForExecutable(value);
  }

  static String? browserIdForExecutable(String value) {
    final executable = p.windows.basename(value.replaceAll('"', '')).toLowerCase();
    const mapping = {
      'msedge.exe': 'edge',
      'chrome.exe': 'chrome',
      'firefox.exe': 'firefox',
      'brave.exe': 'brave',
      'vivaldi.exe': 'vivaldi',
      'opera.exe': 'opera',
      'chromium.exe': 'chromium',
      'whale.exe': 'whale',
    };
    return mapping[executable];
  }

  static String? browserIdForCommand(String command) {
    final quoted = RegExp(r'"([^"]+\.exe)"', caseSensitive: false).firstMatch(command)?.group(1);
    final unquoted = RegExp(r'([a-z]:\\[^\r\n]+?\.exe)', caseSensitive: false).firstMatch(command)?.group(1);
    return browserIdForExecutable(quoted ?? unquoted ?? command);
  }
}
