import 'dart:async';

import 'package:flutter/services.dart';

/// Attach the request-owned event listener before starting native work.
/// A late completion from a previous song must never complete this download.
class AndroidDownloadSession {
  static const _method = MethodChannel('resonance/android_youtube');
  static const _events = EventChannel('resonance/android_youtube/events');
  static int _nextId = 0;

  static Stream<String> open(String url, String outputDir, {bool? includeCover}) {
    final id = ++_nextId;
    StreamSubscription<dynamic>? subscription;
    var started = false;
    var cancelled = false;
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () {
        subscription = _events
            .receiveBroadcastStream({'requestId': id})
            .listen(
              (dynamic event) {
                if (cancelled) return;
                if (event == 'ready:$id') {
                  if (started) return;
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
                          if (!cancelled) controller.addError(error, stack);
                        }),
                  );
                } else if (event is String) {
                  controller.add(event);
                }
              },
              onError: controller.addError,
              onDone: controller.close,
            );
      },
      onCancel: () async {
        cancelled = true;
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }
}
