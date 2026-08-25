import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_cookie_validator.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';

void main() {
  group('YouTube failure classification', () {
    const screenshotError = '''ERROR: [youtube] 8mhMnaht-cM: Sign in to confirm you're not a bot.
Use --cookies-from-browser or --cookies for the authentication.''';

    test('recognizes the verification challenge and rejected sessions', () {
      expect(YoutubeFailureClassifier.classify(screenshotError).kind, YoutubeFailureKind.verificationRequired);
      expect(
        YoutubeFailureClassifier.classify(screenshotError, authenticated: true).kind,
        YoutubeFailureKind.sessionRejected,
      );
      expect(YoutubeFailureClassifier.classify('LOGIN_REQUIRED').kind, YoutubeFailureKind.verificationRequired);
      expect(
        YoutubeFailureClassifier.classify(
          'The provided YouTube account cookies are no longer valid',
          authenticated: true,
        ).kind,
        YoutubeFailureKind.sessionRejected,
      );
      expect(
        YoutubeFailureClassifier.classify(
          'The selected browser profile is not signed in to YouTube Music',
          authenticated: true,
        ).kind,
        YoutubeFailureKind.sessionRejected,
      );
    });

    test('does not treat a bare 403 as missing cookies', () {
      expect(YoutubeFailureClassifier.classify('HTTP Error 403: Forbidden').kind, YoutubeFailureKind.network);
    });

    test('recognizes browser, rate-limit, and unavailable failures', () {
      expect(
        YoutubeFailureClassifier.classify('ERROR: could not copy Chrome cookie database: database is locked').kind,
        YoutubeFailureKind.browserCookiesLocked,
      );
      expect(
        YoutubeFailureClassifier.classify('Failed to decrypt with DPAPI').kind,
        YoutubeFailureKind.browserDecryptionFailed,
      );
      expect(
        YoutubeFailureClassifier.classify('HTTP Error 429: Too Many Requests').kind,
        YoutubeFailureKind.rateLimited,
      );
      expect(YoutubeFailureClassifier.classify('This video is private').kind, YoutubeFailureKind.unavailable);
      expect(YoutubeFailureClassifier.classify('This video is unavailable').kind, YoutubeFailureKind.unavailable);
      expect(
        YoutubeFailureClassifier.classify("This content isn't available, try again later").kind,
        YoutubeFailureKind.rateLimited,
      );
      expect(YoutubeFailureClassifier.classify('Only images are available').kind, YoutubeFailureKind.unsupported);
    });

    test('sanitizes diagnostics and caps their size', () {
      final sanitized = YoutubeFailureClassifier.sanitize(
        '\u001b[31mfailed C:\\Users\\someone\\AppData\\cookies.txt --cookies C:\\private\\cookies.txt\u001b[0m ${'x' * 5000}',
      );
      expect(sanitized, isNot(contains('someone')));
      expect(sanitized, isNot(contains(r'C:\private\cookies.txt')));
      expect(sanitized.length, lessThanOrEqualTo(4096));
      expect(
        YoutubeFailureClassifier.sanitize('/data/user/0/com.example.resonance/no_backup/cookies-123.txt failed'),
        isNot(contains('cookies-123')),
      );
    });
  });

  group('YouTube cookie validation', () {
    const valid =
        '# Netscape HTTP Cookie File\r\n'
        '#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t0\tLOGIN_INFO\tfake-login\r\n'
        '.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tfake-sapisid\r\n';

    test('accepts BOM, CRLF, HttpOnly rows, and both headers', () {
      final withBom = Uint8List.fromList([...utf8.encode('\ufeff'), ...utf8.encode(valid)]);
      final first = YoutubeCookieValidator.validateBytes(withBom);
      final second = YoutubeCookieValidator.validateText(
        '# HTTP Cookie File\n'
        'www.youtube.com\tFALSE\t/\tTRUE\t123\tLOGIN_INFO\tfake\n'
        '.youtube.com\tTRUE\t/\tTRUE\t123\t__Secure-3PAPISID\tfake\n',
      );
      expect(first.isValid, isTrue);
      expect(first.cookieCount, 2);
      expect(first.domains, contains('youtube.com'));
      expect(second.isValid, isTrue);
    });

    test('rejects malformed and non-YouTube exports', () {
      expect(YoutubeCookieValidator.validateBytes(Uint8List(0)).errorMessage, 'This file is empty.');
      expect(YoutubeCookieValidator.validateText('hello').isValid, isFalse);
      expect(
        YoutubeCookieValidator.validateText(
          '# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tA\tfake',
        ).errorMessage,
        contains('does not contain YouTube cookies'),
      );
      expect(
        YoutubeCookieValidator.validateText('# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tA').isValid,
        isFalse,
      );
    });

    test('rejects a valid YouTube export which is not signed in', () {
      final result = YoutubeCookieValidator.validateText(
        '# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tPREF\tfake',
      );
      expect(result.isValid, isFalse);
      expect(result.errorMessage, contains('does not contain a signed-in YouTube session'));
    });

    test('rejects oversized files with ALL-sites guidance', () {
      final bytes = Uint8List(YoutubeCookieValidator.maxBytes + 1);
      expect(YoutubeCookieValidator.validateBytes(bytes).errorMessage, contains('Do not export ALL'));
    });
  });
}
