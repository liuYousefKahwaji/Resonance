import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/music_recognition/music_recognition_service.dart';
import 'package:resonance/widgets/music_recognition/music_recognition_dialog.dart';

void main() {
  testWidgets('offers both sources and returns a recognized track', (tester) async {
    final service = _FakeRecognitionService();
    MusicRecognitionResult? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                selected = await showMusicRecognitionDialog(context, service: service);
              },
              child: const Text('Identify'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Identify'));
    await tester.pumpAndSettle();
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Device audio'), findsOneWidget);

    await tester.tap(find.byKey(const Key('recognition-source-microphone')));
    await tester.pump();
    expect(service.source, MusicRecognitionSource.microphone);
    expect(find.text('Listening…'), findsOneWidget);

    service.complete(const MusicRecognitionResult(title: 'Judas', artist: 'Lady Gaga'));
    await tester.pumpAndSettle();
    expect(selected?.youtubeQuery, 'Lady Gaga Judas');
  });

  testWidgets('keeps the Android source picker usable on a compact screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MusicRecognitionDialog(androidOverride: true))));
    await tester.pumpAndSettle();

    expect(find.text('Listen with microphone'), findsOneWidget);
    expect(find.text('Capture device audio'), findsOneWidget);
    expect(find.textContaining('Recommended'), findsOneWidget);
    expect(find.text('Star sets the Quick Settings tile source.'), findsOneWidget);
    expect(find.byTooltip('Quick Settings tile default'), findsOneWidget);

    for (final key in const [Key('recognition-source-microphone'), Key('recognition-source-device-output')]) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('is compact at a 1080x2400 Android logical viewport', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MusicRecognitionDialog(androidOverride: true))));
    await tester.pumpAndSettle();

    final pickerRect = tester.getRect(find.byKey(const ValueKey('source-picker')));
    final dialogRect = tester.getRect(
      find.ancestor(of: find.byKey(const ValueKey('source-picker')), matching: find.byType(Material)).first,
    );
    expect(dialogRect.width, lessThanOrEqualTo(320));
    expect(dialogRect.height, lessThan(600));
    expect(pickerRect.height, lessThan(480));
    expect(dialogRect.top, greaterThan(0));
    expect(dialogRect.bottom, lessThan(800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('releases scan ownership after success so another scan can start', (tester) async {
    final service = _FakeRecognitionService();
    final entrypoint = _FakeDialogEntrypoint();
    await _pumpDialogLauncher(tester, service: service, entrypoint: entrypoint);

    await _openAndStartMicrophoneScan(tester);
    service.complete(const MusicRecognitionResult(title: 'Judas', artist: 'Lady Gaga'));
    await tester.pumpAndSettle();

    expect(entrypoint.events, ['begin', 'complete:true', 'reset']);
    await _openAndStartMicrophoneScan(tester);
    expect(service.attemptCount, 2);
    expect(entrypoint.events, ['begin', 'complete:true', 'reset', 'begin']);

    service.complete(const MusicRecognitionResult(title: 'Abracadabra', artist: 'Lady Gaga'));
    await tester.pumpAndSettle();
    expect(entrypoint.resetCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('releases scan ownership after no match so retry starts', (tester) async {
    final service = _FakeRecognitionService();
    final entrypoint = _FakeDialogEntrypoint();
    await _pumpDialogLauncher(tester, service: service, entrypoint: entrypoint);

    await _openAndStartMicrophoneScan(tester);
    service.complete(null);
    await tester.pumpAndSettle();

    expect(find.textContaining('No song matched'), findsOneWidget);
    expect(entrypoint.events, ['begin', 'complete:false', 'reset']);
    await tester.tap(find.byKey(const Key('recognition-source-microphone')));
    await tester.pump();
    expect(service.attemptCount, 2);
    expect(entrypoint.events, ['begin', 'complete:false', 'reset', 'begin']);

    service.complete(const MusicRecognitionResult(title: 'Disease', artist: 'Lady Gaga'));
    await tester.pumpAndSettle();
    expect(entrypoint.resetCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel still completes, resets, and closes when cleanup throws', (tester) async {
    final service = _ThrowingCancelRecognitionService();
    final entrypoint = _FakeDialogEntrypoint(throwOnComplete: true);
    await _pumpDialogLauncher(tester, service: service, entrypoint: entrypoint);

    await _openAndStartMicrophoneScan(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('music-recognition-dialog')), findsNothing);
    expect(entrypoint.events, ['begin', 'complete:false', 'reset']);
    expect(entrypoint.locked, isFalse);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpDialogLauncher(
  WidgetTester tester, {
  required MusicRecognitionService service,
  required MusicRecognitionDialogEntrypoint entrypoint,
}) => tester.pumpWidget(
  MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () => showMusicRecognitionDialog(context, service: service, entrypoint: entrypoint),
          child: const Text('Identify'),
        ),
      ),
    ),
  ),
);

Future<void> _openAndStartMicrophoneScan(WidgetTester tester) async {
  await tester.tap(find.text('Identify'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('recognition-source-microphone')));
  await tester.pump();
}

class _FakeRecognitionService extends MusicRecognitionService {
  Completer<MusicRecognitionResult?>? _result;
  MusicRecognitionSource? source;
  int attemptCount = 0;

  @override
  Future<MusicRecognitionResult?> recognize(
    MusicRecognitionSource source, {
    required void Function(MusicRecognitionStage stage) onStage,
  }) {
    this.source = source;
    attemptCount++;
    onStage(MusicRecognitionStage.listening);
    return (_result = Completer<MusicRecognitionResult?>()).future;
  }

  void complete(MusicRecognitionResult? result) => _result!.complete(result);
}

class _ThrowingCancelRecognitionService extends MusicRecognitionService {
  final Completer<MusicRecognitionResult?> _result = Completer<MusicRecognitionResult?>();

  @override
  Future<MusicRecognitionResult?> recognize(
    MusicRecognitionSource source, {
    required void Function(MusicRecognitionStage stage) onStage,
  }) {
    onStage(MusicRecognitionStage.listening);
    return _result.future;
  }

  @override
  Future<void> cancel() async {
    if (!_result.isCompleted) {
      _result.completeError(const MusicRecognitionException('Music recognition was cancelled.'));
    }
    throw StateError('Capture service already stopped.');
  }
}

class _FakeDialogEntrypoint extends MusicRecognitionDialogEntrypoint {
  final bool throwOnComplete;
  final List<String> events = [];
  bool locked = false;
  int resetCount = 0;

  _FakeDialogEntrypoint({this.throwOnComplete = false});

  @override
  Future<bool> beginRecognition({required bool fromTile}) async {
    events.add('begin');
    if (locked) return false;
    locked = true;
    return true;
  }

  @override
  Future<bool> completeRecognition({
    required bool success,
    required bool canOpenDirectly,
    MusicRecognitionResult? result,
    String? message,
  }) async {
    events.add('complete:$success');
    if (throwOnComplete) throw StateError('Native completion failed.');
    return false;
  }

  @override
  Future<String> getDefaultRecognitionSource() async => 'microphone';

  @override
  Future<void> resetRecognition() async {
    events.add('reset');
    resetCount++;
    locked = false;
  }

  @override
  Future<void> setDefaultRecognitionSource(String source) async {}

  @override
  Future<void> updateRecognitionStage(String stage) async {}
}
