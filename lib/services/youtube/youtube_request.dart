import 'dart:async';

/// Cancellation is a selection change, never a connection/authentication error.
class YoutubeRequestCancelled implements Exception {
  const YoutubeRequestCancelled();
}

class YoutubeRequest {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const YoutubeRequestCancelled();
  }

  Future<T> follow<T>(Future<T> operation) =>
      Future.any([operation, cancelled.then<T>((_) => throw const YoutubeRequestCancelled())]);
}
