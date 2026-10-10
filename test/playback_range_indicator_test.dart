import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_range.dart';
import 'package:resonance/widgets/player/playback_range_indicator.dart';

class _Handler extends Fake implements PlayerHandler {
  @override
  final playbackRangeRevision = ValueNotifier(0);
  final requests = <String, List<Completer<PlaybackRange>>>{};
  @override
  Future<PlaybackRange> savedPlaybackRangeFor(String path) {
    final request = Completer<PlaybackRange>();
    requests.putIfAbsent(path, () => []).add(request);
    return request.future;
  }
}

void main() {
  testWidgets('row reuse ignores a late old cut and reset updates every matching row', (tester) async {
    final handler = _Handler();
    Widget rows(String first) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            PlaybackRangeIndicator(key: const Key('first'), handler: handler, path: first, title: first),
            PlaybackRangeIndicator(key: const Key('second'), handler: handler, path: 'b.wav', title: 'B'),
          ],
        ),
      ),
    );
    await tester.pumpWidget(rows('a.wav'));
    await tester.pumpWidget(rows('b.wav'));
    handler.requests['a.wav']!.single.complete(const PlaybackRange(start: Duration(seconds: 1)));
    for (final request in handler.requests['b.wav']!) {
      request.complete(const PlaybackRange(start: Duration(seconds: 5), end: Duration(seconds: 20)));
    }
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.content_cut_rounded), findsNWidgets(2));
    expect(tester.widget<Tooltip>(find.byType(Tooltip).first).message, 'Trimmed: 00:05 – 00:20');
    handler.playbackRangeRevision.value++;
    for (final request in handler.requests['b.wav']!.skip(2)) {
      request.complete(PlaybackRange.full);
    }
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.content_cut_rounded), findsNothing);
    await tester.pumpWidget(const SizedBox());
    handler.playbackRangeRevision.dispose();
  });
}
