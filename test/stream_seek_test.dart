import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';

void main() {
  test('rapid seeks finish the active command then apply only the latest waiting target', () async {
    final queue = LatestSeekOperationQueue();
    final active = Completer<void>();
    final started = Completer<void>();
    final targets = <int>[];
    final first = queue.run(() async {
      targets.add(10);
      started.complete();
      await active.future;
    }, isSourceCurrent: () => true);
    await started.future;
    final second = queue.run(() async => targets.add(20), isSourceCurrent: () => true);
    final third = queue.run(() async => targets.add(30), isSourceCurrent: () => true);
    final latest = queue.run(() async => targets.add(40), isSourceCurrent: () => true);
    expect(targets, [10]);
    active.complete();
    await Future.wait([first, second, third, latest]);
    expect(targets, [10, 40]);
  });

  test('a source switch discards seeks belonging to the old song', () async {
    final queue = LatestSeekOperationQueue();
    final active = Completer<void>();
    final started = Completer<void>();
    var source = 1;
    final targets = <String>[];
    final first = queue.run(() async {
      targets.add('old active');
      started.complete();
      await active.future;
    }, isSourceCurrent: () => source == 1);
    await started.future;
    final pending = queue.run(() async => targets.add('old pending'), isSourceCurrent: () => source == 1);
    source = 2;
    active.complete();
    await Future.wait([first, pending]);
    expect(targets, ['old active']);
    await queue.run(() async => targets.add('new song'), isSourceCurrent: () => source == 2);
    expect(targets, ['old active', 'new song']);
  });

  test('stop cancels pending seeks and a failed active seek does not block the queue', () async {
    final queue = LatestSeekOperationQueue();
    final active = Completer<void>();
    final started = Completer<void>();
    final targets = <int>[];
    final first = queue.run(() async {
      started.complete();
      await active.future;
      throw StateError('native seek failed');
    }, isSourceCurrent: () => true);
    final failure = expectLater(first, throwsStateError);
    await started.future;
    final pending = queue.run(() async => targets.add(20), isSourceCurrent: () => true);
    queue.cancelPending();
    active.complete();
    await failure;
    await pending;
    await queue.idle;
    expect(targets, isEmpty);
    await queue.run(() async => targets.add(30), isSourceCurrent: () => true);
    expect(targets, [30]);
  });

  testWidgets('backward seeking cancels the old progress window and monitors the new position', (tester) async {
    final watchdog = PlaybackProgressWatchdog();
    addTearDown(watchdog.cancel);
    var position = const Duration(seconds: 120);
    var progress = 0;
    var reloads = 0;
    void arm({Duration? initialPosition}) => watchdog.start(
      grace: const Duration(seconds: 8),
      position: () => position,
      initialPosition: initialPosition,
      shouldMonitor: () => true,
      isCompleted: () => false,
      onProgress: () => progress++,
      onStalled: () => reloads++,
    );
    arm();
    await tester.pump(const Duration(seconds: 7));
    watchdog.cancel();
    position = const Duration(seconds: 10);
    // The old deadline expires while the native seek is still unresolved.
    await tester.pump(const Duration(seconds: 4));
    expect(reloads, 0);
    // The backend's position event may still contain the old timestamp when
    // the seek command returns. Its requested target starts the new window.
    position = const Duration(seconds: 120);
    arm(initialPosition: const Duration(seconds: 10));
    position = const Duration(seconds: 12);
    await tester.pump(const Duration(seconds: 8));
    expect(progress, 1);
    expect(reloads, 0);
    // A genuinely stalled stream must still trigger recovery after seeking.
    arm();
    await tester.pump(const Duration(seconds: 8));
    expect(reloads, 1);
  });

  testWidgets('paused or replaced sources cannot trigger delayed recovery', (tester) async {
    final watchdog = PlaybackProgressWatchdog();
    addTearDown(watchdog.cancel);
    var current = true;
    var reloads = 0;
    watchdog.start(
      grace: const Duration(seconds: 5),
      position: () => const Duration(seconds: 30),
      shouldMonitor: () => current,
      isCompleted: () => false,
      onProgress: () {},
      onStalled: () => reloads++,
    );
    current = false;
    await tester.pump(const Duration(seconds: 6));
    expect(reloads, 0);
  });
}
