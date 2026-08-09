import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/download/youtube_download_gate.dart';

void main() {
  test('native download work is globally FIFO and never overlaps', () async {
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = YoutubeDownloadGate.instance.run(() async {
      events.add('first-start');
      await releaseFirst.future;
      events.add('first-end');
      return 1;
    });
    final second = YoutubeDownloadGate.instance.run(() async {
      events.add('second-start');
      events.add('second-end');
      return 2;
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, const ['first-start']);
    releaseFirst.complete();

    expect(await first, 1);
    expect(await second, 2);
    expect(events, const ['first-start', 'first-end', 'second-start', 'second-end']);
  });
}
