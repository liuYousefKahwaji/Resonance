import 'package:resonance/core/youtube/youtube_access_models.dart';

class YoutubeFailureClassifier {
  const YoutubeFailureClassifier._();

  static YoutubeFailure classify(Object error, {bool authenticated = false, String? sourceUrl}) {
    if (error is YoutubeFailure) return error.withSourceUrl(sourceUrl);
    final technical = sanitize(error.toString());
    final lower = technical.toLowerCase();

    if (_containsAny(lower, const [
      "sign in to confirm you're not a bot",
      'sign in to confirm you’re not a bot',
      'use --cookies-from-browser or --cookies',
      'login_required',
      'login required',
      'login details are needed',
      'provided youtube account cookies are no longer valid',
      'account cookies are no longer valid',
      'no youtube music cookies were found',
      'missing its authenticated sapisid cookie',
      'not signed in to youtube music',
      'this video may be inappropriate for some users',
      'confirm your age',
    ])) {
      return YoutubeFailure(
        kind: authenticated ? YoutubeFailureKind.sessionRejected : YoutubeFailureKind.verificationRequired,
        userMessage: authenticated
            ? 'Your saved YouTube session was rejected or expired.'
            : 'YouTube verification is required.',
        technicalSummary: technical,
        sourceUrl: sourceUrl,
      );
    }
    if (_containsAny(lower, const [
          'could not find',
          'browser profile',
          'no such file or directory',
          'failed to find cookies database',
        ]) &&
        lower.contains('cookie')) {
      return _failure(
        YoutubeFailureKind.browserProfileMissing,
        'No browser profile was found. Open the browser once, sign in, and retry.',
        technical,
        sourceUrl,
      );
    }
    if (_containsAny(lower, const [
          'database is locked',
          'could not copy chrome cookie database',
          'permission denied',
          'being used by another process',
        ]) &&
        lower.contains('cookie')) {
      return _failure(
        YoutubeFailureKind.browserCookiesLocked,
        'Close all browser windows, then retry the test.',
        technical,
        sourceUrl,
      );
    }
    if (_containsAny(lower, const ['failed to decrypt', 'could not decrypt', 'decrypting cookies', 'dpapi'])) {
      return _failure(
        YoutubeFailureKind.browserDecryptionFailed,
        'Windows could not unlock this browser session. Try Firefox or another supported browser.',
        technical,
        sourceUrl,
      );
    }
    if (_containsAny(lower, const [
      'too many requests',
      'rate limit',
      'request limit',
      'http error 429',
      "this content isn't available, try again later",
      'this content isn’t available, try again later',
    ])) {
      return _failure(
        YoutubeFailureKind.rateLimited,
        'YouTube is temporarily limiting requests. Wait a while before retrying.',
        technical,
        sourceUrl,
      );
    }
    if (_containsAny(lower, const [
      'video unavailable',
      'video is unavailable',
      'private video',
      'video is private',
      'has been removed',
      'not available in your country',
      'geo restricted',
      'copyright',
    ])) {
      return _failure(YoutubeFailureKind.unavailable, 'This YouTube video is unavailable.', technical, sourceUrl);
    }
    if (_containsAny(lower, const [
      'no video formats found',
      'no formats found',
      'only images are available',
      'requested format is not available',
      'no playable formats',
    ])) {
      return _failure(
        YoutubeFailureKind.unsupported,
        'YouTube returned no playable audio for this session. Open Details for the yt-dlp reason.',
        technical,
        sourceUrl,
      );
    }
    if (_containsAny(lower, const [
      'timed out',
      'timeout',
      'network is unreachable',
      'temporary failure in name resolution',
      'connection reset',
      'connection refused',
      'http error 403',
      '403 forbidden',
    ])) {
      return _failure(
        YoutubeFailureKind.network,
        'YouTube could not be reached. Check your connection and try again.',
        technical,
        sourceUrl,
      );
    }
    return _failure(YoutubeFailureKind.unknown, 'The YouTube request failed. Try again.', technical, sourceUrl);
  }

  static String sanitize(String input) {
    var value = input.replaceAll(RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))'), '');
    value = value.replaceAll(
      RegExp(r'(?:[a-z]:\\users\\|/home/)[^\\/\s]+(?:[\\/][^\s,:;]+)*', caseSensitive: false),
      '<private path>',
    );
    value = value.replaceAll(
      RegExp(r'/(?:data/(?:user|user_de)/\d+|data/data)/[^\s,:;]+', caseSensitive: false),
      '<private path>',
    );
    value = value.replaceAll(
      RegExp(r'(--cookies(?:-from-browser)?\s+)(?:"[^"]+"|\S+)', caseSensitive: false),
      r'$1<redacted>',
    );
    value = value.replaceAll(
      RegExp(r'((?:set-)?cookie|authorization)\s*[:=]\s*[^\s,;]+', caseSensitive: false),
      r'$1: <redacted>',
    );
    value = value.replaceAll(RegExp(r'[\r\n\t ]+'), ' ').trim();
    if (value.length > 4096) value = '${value.substring(0, 4093)}...';
    return value;
  }

  static bool _containsAny(String value, List<String> needles) => needles.any(value.contains);

  static YoutubeFailure _failure(YoutubeFailureKind kind, String message, String technical, String? sourceUrl) =>
      YoutubeFailure(kind: kind, userMessage: message, technicalSummary: technical, sourceUrl: sourceUrl);
}
