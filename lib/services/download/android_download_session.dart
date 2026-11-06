import 'package:resonance/services/youtube/youtube_request.dart';
import 'dart:async';

import 'package:flutter/services.dart';

/// Attach the request-owned event listener before starting native work.
/// A late completion from a previous song must never complete this download.
class AndroidDownloadSession {
  static const _method = MethodChannel('resonance/android_youtube');
  static const _events = EventChannel('resonance/android_youtube/events');
  static int _nextId = 0;

  static Stream<String> open(String url, String outputDir, {bool? includeCover, YoutubeRequest? request}) {
    final id = ++_nextId;
    StreamSubscription<dynamic>? subscription;
    request?.check();
    var started = false;
    var finished = false;
    var cancelSent = false;
    Future<void> cancelNative() async {
      if (!started || finished || cancelSent) return;
      cancelSent = true;
      await _method.invokeMethod<void>('cancelDownload', {'requestId': id});
    }

    var cancelled = false;
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () {
        if (request != null) unawaited(request.cancelled.then((_) => cancelNative()).catchError((Object _) {}));
        subscription = _events
            .receiveBroadcastStream({'requestId': id})
            .listen(
              (dynamic event) {
                if (cancelled) return;
                if (event == 'ready:$id') {
                  if (started) return;
                  if (request?.isCancelled ?? false) {
                    controller.add('cancelled');
                    return;
                  }
                  started = true;
                  unawaited(
                    _method
                        .invokeMethod<void>('download', {
                          'url': url,
                          'outputDir': outputDir,
                          'requestId': id,
                          if (includeCover != null) 'includeCover': includeCover,
                        })
                        .catchError((Object error, StackTrace stack) {
                          finished = true;
                          if (!cancelled) controller.addError(error, stack);
                        }),
                  );
                } else if (event is String) {
                  if (event == 'done' || event == 'cancelled' || event.startsWith('error:')) finished = true;
                  controller.add(event);
                }
              },
              onError: controller.addError,
              onDone: controller.close,
            );
      },
      onCancel: () async {
        cancelled = true;
        try {
          await cancelNative();
        } catch (_) {}
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }
}
