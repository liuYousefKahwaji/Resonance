import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/download/android_download_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('resonance/android_youtube');
  const events = MethodChannel('resonance/android_youtube/events');
  const codec = StandardMethodCodec();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late int id;
  late List<MethodCall> starts;
  late List<String> controls;

  Future<void> emit(String value) async {
    await messenger.handlePlatformMessage(events.name, codec.encodeSuccessEnvelope(value), (_) {});
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    starts = [];
    controls = [];
    messenger.setMockMethodCallHandler(events, (call) async {
      controls.add(call.method);
      if (call.method == 'listen') id = (call.arguments as Map)['requestId'] as int;
      return null;
    });
    messenger.setMockMethodCallHandler(method, (call) async {
      starts.add(call);
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(method, null);
  });

  test('native download starts only after listener readiness and is request scoped', () async {
    final received = <String>[];
    final subscription = AndroidDownloadSession.open('song', 'folder').listen(received.add);
    await Future<void>.delayed(Duration.zero);
    expect(controls, ['listen']);
    expect(starts, isEmpty);
    await emit('ready:$id');
    expect(starts.single.method, 'download');
    expect(starts.single.arguments, {'url': 'song', 'outputDir': 'folder', 'requestId': id});
    await emit('ready:$id');
    expect(starts.length, 1);
    await emit('progress:12:Downloading');
    expect(received, ['progress:12:Downloading']);
    await subscription.cancel();
    expect(controls.last, 'cancel');
    final previousId = id;
    final next = AndroidDownloadSession.open('next', 'folder').listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(id, isNot(previousId));
    await emit('ready:$id');
    expect((starts.last.arguments as Map)['url'], 'next');
    await next.cancel();
  });

  test('method channel startup failure reaches the waiting download', () async {
    messenger.setMockMethodCallHandler(method, (_) async {
      throw PlatformException(code: 'DOWNLOAD_ERROR');
    });
    final failure = Completer<Object>();
    final subscription = AndroidDownloadSession.open('song', 'folder').listen((_) {}, onError: failure.complete);
    await Future<void>.delayed(Duration.zero);
    await emit('ready:$id');
    expect(await failure.future.timeout(const Duration(seconds: 1)), isA<PlatformException>());
    await subscription.cancel();
  });
}
