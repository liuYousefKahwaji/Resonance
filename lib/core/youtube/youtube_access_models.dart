import 'package:flutter/foundation.dart';

enum YoutubeAccessMethod { none, windowsBrowser, windowsCookieFile, androidCookieFile }

enum YoutubeAccessState {
  notConfigured,
  configuredUntested,
  testing,
  ready,
  verificationRequired,
  rejected,
  unavailable,
}

@immutable
class YoutubeAccessStatus {
  const YoutubeAccessStatus({
    this.method = YoutubeAccessMethod.none,
    this.state = YoutubeAccessState.notConfigured,
    this.browserId,
    this.configuredAt,
    this.lastTestedAt,
    this.shortMessage,
    this.revision = 0,
  });

  final YoutubeAccessMethod method;
  final YoutubeAccessState state;
  final String? browserId;
  final DateTime? configuredAt;
  final DateTime? lastTestedAt;
  final String? shortMessage;
  final int revision;

  bool get isConfigured => method != YoutubeAccessMethod.none;
  bool get isReady => state == YoutubeAccessState.ready;

  YoutubeAccessStatus copyWith({
    YoutubeAccessMethod? method,
    YoutubeAccessState? state,
    String? browserId,
    bool clearBrowserId = false,
    DateTime? configuredAt,
    bool clearConfiguredAt = false,
    DateTime? lastTestedAt,
    bool clearLastTestedAt = false,
    String? shortMessage,
    bool clearShortMessage = false,
    int? revision,
  }) => YoutubeAccessStatus(
    method: method ?? this.method,
    state: state ?? this.state,
    browserId: clearBrowserId ? null : browserId ?? this.browserId,
    configuredAt: clearConfiguredAt ? null : configuredAt ?? this.configuredAt,
    lastTestedAt: clearLastTestedAt ? null : lastTestedAt ?? this.lastTestedAt,
    shortMessage: clearShortMessage ? null : shortMessage ?? this.shortMessage,
    revision: revision ?? this.revision,
  );
}

enum YoutubeFailureKind {
  verificationRequired,
  sessionRejected,
  browserProfileMissing,
  browserCookiesLocked,
  browserDecryptionFailed,
  invalidCookieFile,
  rateLimited,
  network,
  unavailable,
  unsupported,
  unknown,
}

class YoutubeFailure implements Exception {
  const YoutubeFailure({required this.kind, required this.userMessage, this.technicalSummary = '', this.sourceUrl});

  final YoutubeFailureKind kind;
  final String userMessage;
  final String technicalSummary;
  final String? sourceUrl;

  bool get isAccessFailure =>
      kind == YoutubeFailureKind.verificationRequired ||
      kind == YoutubeFailureKind.sessionRejected ||
      kind == YoutubeFailureKind.browserProfileMissing ||
      kind == YoutubeFailureKind.browserCookiesLocked ||
      kind == YoutubeFailureKind.browserDecryptionFailed ||
      kind == YoutubeFailureKind.invalidCookieFile;

  YoutubeFailure withSourceUrl(String? value) => YoutubeFailure(
    kind: kind,
    userMessage: userMessage,
    technicalSummary: technicalSummary,
    sourceUrl: value ?? sourceUrl,
  );

  @override
  String toString() => userMessage;
}

@immutable
class ResolvedYoutubeStream {
  const ResolvedYoutubeStream({required this.uri, this.headers = const {}, required this.accessRevision});

  final Uri uri;
  final Map<String, String> headers;
  final int accessRevision;
}
