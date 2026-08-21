import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_cookie_validator.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/android_youtube_access_backend.dart';
import 'package:resonance/services/youtube/youtube_access_backend.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef WindowsAccessTester = Future<void> Function(String browserId, String sourceUrl);

class YoutubeAccessService extends ChangeNotifier {
  YoutubeAccessService({
    YoutubeAccessBackend? androidBackend,
    SharedPreferences? preferences,
    bool? isWindows,
    bool? isAndroid,
  }) : _androidBackend = androidBackend ?? AndroidYoutubeAccessBackend(),
       _preferences = preferences,
       _isWindows = isWindows ?? Platform.isWindows,
       _isAndroid = isAndroid ?? Platform.isAndroid;

  // Resolve the first current search result instead of depending on one
  // hard-coded video which may later be removed or made private.
  static const fallbackTestTarget = 'ytsearch1:YouTube music';
  static YoutubeAccessService? active;
  static const _warningKey = 'youtube_access.warning_acknowledged';
  static const _browserKey = 'youtube_access.windows_browser_id';
  static const _configuredKey = 'youtube_access.windows_configured_at';
  static const _testedKey = 'youtube_access.last_successful_test_at';

  final YoutubeAccessBackend _androidBackend;
  SharedPreferences? _preferences;
  final bool _isWindows;
  final bool _isAndroid;
  Future<void>? _initializing;
  WindowsAccessTester? _windowsTester;
  YoutubeAccessStatus _status = const YoutubeAccessStatus();
  bool _warningAcknowledged = false;

  YoutubeAccessStatus get status => _status;
  bool get isConfigured => _status.isConfigured;
  bool get isReady => _status.isReady;
  int get revision => _status.revision;
  bool get warningAcknowledged => _warningAcknowledged;
  String? get windowsBrowserId => _status.method == YoutubeAccessMethod.windowsBrowser ? _status.browserId : null;
  YoutubeAccessBackend get androidBackend => _androidBackend;

  void setWindowsTester(WindowsAccessTester tester) => _windowsTester = tester;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    active = this;
    _preferences ??= await SharedPreferences.getInstance();
    _warningAcknowledged = _preferences!.getBool(_warningKey) ?? false;
    try {
      if (_isWindows) {
        final browser = _preferences!.getString(_browserKey);
        if (browser != null && browser.isNotEmpty) {
          final configuredAt = _readDate(_configuredKey);
          final testedAt = _readDate(_testedKey);
          _status = YoutubeAccessStatus(
            method: YoutubeAccessMethod.windowsBrowser,
            state: testedAt == null ? YoutubeAccessState.configuredUntested : YoutubeAccessState.ready,
            browserId: browser,
            configuredAt: configuredAt,
            lastTestedAt: testedAt,
          );
        }
      } else if (_isAndroid) {
        final nativeStatus = await _androidBackend.getStatus();
        if (nativeStatus['configured'] == true) {
          _status = YoutubeAccessStatus(
            method: YoutubeAccessMethod.androidCookieFile,
            state: YoutubeAccessState.configuredUntested,
            configuredAt: _dateFromValue(nativeStatus['updatedAt']),
          );
        }
      }
    } catch (error) {
      _status = YoutubeAccessStatus(
        state: YoutubeAccessState.unavailable,
        shortMessage: YoutubeFailureClassifier.classify(error).userMessage,
      );
    }
    notifyListeners();
  }

  List<String> windowsAuthArguments({String? overrideBrowserId}) {
    final browser = overrideBrowserId ?? windowsBrowserId;
    return browser == null ? const [] : ['--cookies-from-browser', browser];
  }

  Future<void> acknowledgeWarning() async {
    _warningAcknowledged = true;
    await _preferences?.setBool(_warningKey, true);
    notifyListeners();
  }

  Future<void> connectWindowsBrowser(String browserId, {String? sourceUrl}) async {
    final tester = _windowsTester;
    if (tester == null) throw StateError('Windows YouTube access tester is unavailable.');
    final previous = _status;
    _setTesting(YoutubeAccessMethod.windowsBrowser, browserId: browserId);
    try {
      await tester(browserId, sourceUrl ?? fallbackTestTarget);
      final now = DateTime.now();
      final nextRevision = _status.revision + 1;
      await _preferences!.setString(_browserKey, browserId);
      await _preferences!.setString(_configuredKey, now.toIso8601String());
      await _preferences!.setString(_testedKey, now.toIso8601String());
      _status = YoutubeAccessStatus(
        method: YoutubeAccessMethod.windowsBrowser,
        state: YoutubeAccessState.ready,
        browserId: browserId,
        configuredAt: now,
        lastTestedAt: now,
        revision: nextRevision,
      );
      notifyListeners();
    } catch (error) {
      final failure = YoutubeFailureClassifier.classify(error, authenticated: true, sourceUrl: sourceUrl);
      _status = previous.copyWith(
        state: failure.kind == YoutubeFailureKind.sessionRejected
            ? YoutubeAccessState.rejected
            : YoutubeAccessState.unavailable,
        shortMessage: failure.userMessage,
      );
      notifyListeners();
      throw failure;
    }
  }

  Future<void> importAndroidCookies(Uint8List bytes, {String? sourceUrl}) async {
    final validation = YoutubeCookieValidator.validateBytes(bytes);
    if (!validation.isValid) {
      throw YoutubeFailure(kind: YoutubeFailureKind.invalidCookieFile, userMessage: validation.errorMessage!);
    }
    late Map<String, Object?> nativeStatus;
    try {
      nativeStatus = await _androidBackend.importCookies(bytes);
    } catch (error) {
      final technical = YoutubeFailureClassifier.sanitize(error.toString());
      final knownMessage = const [
        'This file is empty.',
        'Choose the Netscape cookies.txt file downloaded by the Firefox add-on.',
        'This file does not contain YouTube cookies. Export Current Site while youtube.com/robots.txt is open.',
        'This cookie file is too large. Do not export ALL sites.',
        YoutubeCookieValidator.signedOutMessage,
      ].where(technical.contains).firstOrNull;
      throw YoutubeFailure(
        kind: YoutubeFailureKind.invalidCookieFile,
        userMessage: knownMessage ?? 'Resonance could not import this cookies.txt file.',
        technicalSummary: technical,
      );
    }
    _status = YoutubeAccessStatus(
      method: YoutubeAccessMethod.androidCookieFile,
      state: YoutubeAccessState.configuredUntested,
      configuredAt: _dateFromValue(nativeStatus['updatedAt']) ?? DateTime.now(),
      revision: _status.revision + 1,
    );
    notifyListeners();
    await testCurrent(sourceUrl: sourceUrl);
  }

  Future<void> testCurrent({String? sourceUrl}) async {
    if (!_status.isConfigured) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.verificationRequired,
        userMessage: 'Configure YouTube access first.',
      );
    }
    final previous = _status;
    _setTesting(previous.method, browserId: previous.browserId);
    try {
      if (previous.method == YoutubeAccessMethod.windowsBrowser) {
        final tester = _windowsTester;
        if (tester == null) throw StateError('Windows YouTube access tester is unavailable.');
        await tester(previous.browserId!, sourceUrl ?? fallbackTestTarget);
      } else {
        await _androidBackend.testCookies(sourceUrl: sourceUrl ?? fallbackTestTarget);
      }
      final now = DateTime.now();
      if (previous.method == YoutubeAccessMethod.windowsBrowser) {
        await _preferences?.setString(_testedKey, now.toIso8601String());
      }
      _status = previous.copyWith(state: YoutubeAccessState.ready, lastTestedAt: now, clearShortMessage: true);
      notifyListeners();
    } catch (error) {
      final failure = YoutubeFailureClassifier.classify(error, authenticated: true, sourceUrl: sourceUrl);
      _status = previous.copyWith(
        state: failure.kind == YoutubeFailureKind.sessionRejected
            ? YoutubeAccessState.rejected
            : YoutubeAccessState.unavailable,
        shortMessage: failure.userMessage,
      );
      notifyListeners();
      throw failure;
    }
  }

  Future<void> clear() async {
    final nextRevision = _status.revision + 1;
    if (_status.method == YoutubeAccessMethod.androidCookieFile || _isAndroid) {
      await _androidBackend.clearCookies();
    }
    await _preferences?.remove(_browserKey);
    await _preferences?.remove(_configuredKey);
    await _preferences?.remove(_testedKey);
    _status = YoutubeAccessStatus(revision: nextRevision);
    notifyListeners();
  }

  void observeFailure(YoutubeFailure failure) {
    if (!failure.isAccessFailure) return;
    final state = failure.kind == YoutubeFailureKind.sessionRejected
        ? YoutubeAccessState.rejected
        : YoutubeAccessState.verificationRequired;
    _status = _status.copyWith(state: state, shortMessage: failure.userMessage);
    notifyListeners();
  }

  String get settingsSubtitle {
    switch (_status.state) {
      case YoutubeAccessState.notConfigured:
        return 'No authenticated session configured';
      case YoutubeAccessState.ready:
        final tested = _relative(_status.lastTestedAt);
        if (_status.method == YoutubeAccessMethod.windowsBrowser) {
          return 'Using ${browserDisplayName(_status.browserId)} browser session${tested == null ? '' : ' · tested $tested'}';
        }
        return 'YouTube cookies imported${tested == null ? '' : ' · tested $tested'}';
      case YoutubeAccessState.configuredUntested:
        return 'Session configured · test required';
      case YoutubeAccessState.testing:
        return 'Testing YouTube access…';
      case YoutubeAccessState.verificationRequired:
        return 'YouTube verification required';
      case YoutubeAccessState.rejected:
        return 'Session expired or was rejected';
      case YoutubeAccessState.unavailable:
        return _status.shortMessage ?? 'Could not verify session · tap for details';
    }
  }

  static String browserDisplayName(String? id) {
    const names = {
      'edge': 'Edge',
      'chrome': 'Chrome',
      'firefox': 'Firefox',
      'brave': 'Brave',
      'vivaldi': 'Vivaldi',
      'opera': 'Opera',
      'chromium': 'Chromium',
      'whale': 'Whale',
    };
    return names[id] ?? 'selected';
  }

  void _setTesting(YoutubeAccessMethod method, {String? browserId}) {
    _status = _status.copyWith(
      method: method,
      state: YoutubeAccessState.testing,
      browserId: browserId,
      clearShortMessage: true,
    );
    notifyListeners();
  }

  DateTime? _readDate(String key) => _dateFromValue(_preferences?.getString(key));

  static DateTime? _dateFromValue(Object? value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static String? _relative(DateTime? value) {
    if (value == null) return null;
    final difference = DateTime.now().difference(value);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} hr ago';
    return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
