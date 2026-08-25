import 'dart:convert';
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

  /// Resolves the browser profile which is active when the user completes the
  /// connection flow. yt-dlp otherwise searches every profile and selects the
  /// most recently modified cookie database, which can drift to a guest or a
  /// different Google profile after Resonance restarts.
  Future<String> resolveCookieSource(String browserId) async {
    final baseId = baseBrowserId(browserId);
    if (!Platform.isWindows) return baseId;
    final existingProfile = browserProfile(browserId);
    if (existingProfile != null) return '$baseId:$existingProfile';

    if (baseId == 'firefox') {
      final roaming = Platform.environment['APPDATA'];
      if (roaming == null) return baseId;
      final profilesIni = File(p.join(roaming, 'Mozilla', 'Firefox', 'profiles.ini'));
      if (!await profilesIni.exists()) return baseId;
      try {
        final profile = defaultFirefoxProfile(await profilesIni.readAsString());
        return profile == null ? baseId : '$baseId:$profile';
      } catch (_) {
        return baseId;
      }
    }

    if (baseId == 'opera') return baseId;
    final userData = _chromiumUserDataDirectory(baseId);
    if (userData == null) return baseId;
    final localState = File(p.join(userData, 'Local State'));
    if (!await localState.exists()) return baseId;
    try {
      final profile = lastUsedChromiumProfile(await localState.readAsString());
      if (profile == null || !await Directory(p.join(userData, profile)).exists()) return baseId;
      return '$baseId:$profile';
    } catch (_) {
      return baseId;
    }
  }

  Future<bool> launchBrowser(String browserId, String url) async {
    if (!Platform.isWindows || Uri.tryParse(url)?.scheme != 'https') return false;
    browserId = baseBrowserId(browserId);
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

  static String baseBrowserId(String source) => source.split(':').first.trim().toLowerCase();

  static String? browserProfile(String source) {
    final separator = source.indexOf(':');
    if (separator < 0) return null;
    return _safeProfileName(source.substring(separator + 1));
  }

  static String? lastUsedChromiumProfile(String localStateJson) {
    final decoded = jsonDecode(localStateJson);
    if (decoded is! Map) return null;
    final profile = decoded['profile'];
    if (profile is! Map) return null;
    return _safeProfileName(profile['last_used']?.toString());
  }

  static String? defaultFirefoxProfile(String profilesIni) {
    final sections = <Map<String, String>>[];
    Map<String, String>? current;
    for (final rawLine in profilesIni.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.startsWith('[') && line.endsWith(']')) {
        current = <String, String>{'_section': line.substring(1, line.length - 1)};
        sections.add(current);
        continue;
      }
      final separator = line.indexOf('=');
      if (current == null || separator <= 0) continue;
      current[line.substring(0, separator).trim()] = line.substring(separator + 1).trim();
    }
    final preferred =
        sections.where((section) => section['_section']?.startsWith('Install') == true).firstOrNull ??
        sections.where((section) => section['Default'] == '1').firstOrNull;
    final installSection = preferred?['_section']?.startsWith('Install') == true;
    final path = preferred == null
        ? null
        : installSection
        ? preferred['Default']
        : preferred['Path'];
    if (path == null || path.isEmpty) return null;
    return _safeProfileName(p.windows.basename(path.replaceAll('/', r'\')));
  }

  static String? _safeProfileName(String? value) {
    final profile = value?.trim();
    if (profile == null || profile.isEmpty || profile == '.' || profile == '..') return null;
    if (profile.contains('/') || profile.contains(r'\') || profile.contains(':')) return null;
    return profile;
  }

  static String? _chromiumUserDataDirectory(String browserId) {
    final local = Platform.environment['LOCALAPPDATA'];
    return switch (browserId) {
      'edge' when local != null => p.join(local, 'Microsoft', 'Edge', 'User Data'),
      'chrome' when local != null => p.join(local, 'Google', 'Chrome', 'User Data'),
      'brave' when local != null => p.join(local, 'BraveSoftware', 'Brave-Browser', 'User Data'),
      'vivaldi' when local != null => p.join(local, 'Vivaldi', 'User Data'),
      'chromium' when local != null => p.join(local, 'Chromium', 'User Data'),
      'whale' when local != null => p.join(local, 'Naver', 'Naver Whale', 'User Data'),
      _ => null,
    };
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

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
