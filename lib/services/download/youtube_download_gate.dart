import 'dart:async';

/// A process-wide asynchronous mutex for native downloader backends. Android's
/// EventChannel is shared, and Windows downloads should follow the same
/// one-at-a-time user contract even when an import and Search overlap.
class YoutubeDownloadGate {
  YoutubeDownloadGate._();
  static final YoutubeDownloadGate instance = YoutubeDownloadGate._();
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  Future<T> run<T>(Future<T> Function() operation, {void Function()? onWaiting}) {
    if (_pending > 0) onWaiting?.call();
    _pending++;
    final completion = Completer<T>();
    _tail = _tail.catchError((_) {}).then((_) async {
      try {
        completion.complete(await operation());
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      } finally {
        _pending--;
      }
    });
    return completion.future;
  }
}
