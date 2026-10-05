import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/playback_interruption_controller.dart';

void main() {
  late PlaybackInterruptionController controller;
  late int pauses;
  late int resumes;
  Completer<void>? pauseCompletion;
  setUp(() {
    pauses = 0;
    resumes = 0;
    pauseCompletion = null;
    controller = PlaybackInterruptionController(
      pauseBackend: () async {
        pauses++;
        await pauseCompletion?.future;
      },
      resumeBackend: () async => resumes++,
      onError: (error, _) => fail('Unexpected interruption error: $error'),
    );
  });
  void begin([AudioInterruptionType type = AudioInterruptionType.pause]) =>
      controller.handle(AudioInterruptionEvent(true, type));
  void end([AudioInterruptionType type = AudioInterruptionType.pause]) =>
      controller.handle(AudioInterruptionEvent(false, type));
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('a manually paused stream stays paused through a call and focus gain', () async {
    begin();
    expect(controller.canPlay, isFalse);
    end();
    await flush();
    expect(pauses, 1);
    expect(resumes, 0);
    expect(controller.canPlay, isFalse);
  });

  test('active playback resumes only after focus returns and backend pause finishes', () async {
    controller.desiredPlaying = true;
    pauseCompletion = Completer<void>();
    begin();
    expect(controller.canPlay, isFalse); // Stream recovery also sees false.
    end();
    await flush();
    expect(controller.blocked, isTrue);
    expect(resumes, 0);
    pauseCompletion!.complete();
    await flush();
    expect(resumes, 1);
    expect(controller.canPlay, isTrue);
  });

  test('manual pause during a call cancels the pending automatic resume', () async {
    controller.desiredPlaying = true;
    begin();
    controller.desiredPlaying = false;
    end();
    await flush();
    expect(resumes, 0);
  });

  test('a selected track may prepare during a call but cannot play until focus gain', () async {
    begin();
    controller.desiredPlaying = true;
    expect(controller.canPlay, isFalse);
    end();
    await flush();
    expect(resumes, 1);
  });

  test('duplicate pause events preserve the original playback intent', () async {
    controller.desiredPlaying = true;
    begin();
    begin();
    end();
    end();
    await flush();
    expect(resumes, 1);
  });

  test('a new call invalidates an older pending focus-gain callback', () async {
    controller.desiredPlaying = true;
    pauseCompletion = Completer<void>();
    begin();
    end();
    begin();
    pauseCompletion!.complete();
    await flush();
    expect(resumes, 0);
    expect(controller.canPlay, isFalse);
    end();
    await flush();
    expect(resumes, 1);
  });

  test('overlapping native pauses must all finish before resuming', () async {
    controller.desiredPlaying = true;
    final first = Completer<void>();
    final second = Completer<void>();
    pauseCompletion = first;
    begin();
    pauseCompletion = second;
    begin();
    end();
    second.complete();
    await flush();
    expect(resumes, 0);
    first.complete();
    await flush();
    expect(resumes, 1);
  });

  test('an unmatched focus gain cannot start a paused backend', () async {
    end();
    await flush();
    expect(pauses, 0);
    expect(resumes, 0);
  });

  test('permanent focus loss never resumes automatically but allows a later explicit Play', () async {
    controller.desiredPlaying = true;
    begin(AudioInterruptionType.unknown);
    end();
    await flush();
    expect(resumes, 0);
    expect(controller.canPlay, isFalse);
    begin(AudioInterruptionType.unknown);
    controller.desiredPlaying = true;
    expect(controller.canPlay, isTrue);
  });

  test('headphone disconnect or Stop clears intent while interrupted', () async {
    controller.desiredPlaying = true;
    begin();
    controller.desiredPlaying = false;
    end();
    await flush();
    expect(resumes, 0);
  });

  test('ducking leaves music volume and playback intent under Android control', () async {
    controller.desiredPlaying = true;
    begin(AudioInterruptionType.duck);
    end(AudioInterruptionType.duck);
    await flush();
    expect(controller.canPlay, isTrue);
    expect(pauses, 0);
    expect(resumes, 0);
  });

  test('disposal prevents a queued focus gain from restarting the backend', () async {
    controller.desiredPlaying = true;
    pauseCompletion = Completer<void>();
    begin();
    end();
    controller.dispose();
    pauseCompletion!.complete();
    await flush();
    expect(resumes, 0);
    expect(controller.canPlay, isFalse);
  });
}
