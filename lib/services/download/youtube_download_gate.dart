import 'dart:async';

/// A process-wide asynchronous mutex for native downloader backends. Android's
/// EventChannel is shared, and Windows downloads should follow the same
/// one-at-a-time user contract even when an import and Search overlap.
class YoutubeDownloadGate {
  YoutubeDownloadGate._();
  static final YoutubeDownloadGate instance = YoutubeDownloadGate._();
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final completion = Completer<T>();
    _tail = _tail.catchError((_) {}).then((_) async {
      try {
        completion.complete(await operation());
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }
}
