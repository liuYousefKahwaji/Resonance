import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/playback_session.dart';

void main() {
  const entry = SavedPlaybackEntry(id: 'https://www.youtube.com/watch?v=abcdefghijk', title: 'Song', artist: 'Artist');
  test('session round trip retains duplicate queue occurrences and relative position', () {
    const session = PlaybackSession(
      current: entry,
      position: Duration(seconds: 42),
      duration: Duration(minutes: 3),
      standalone: true,
      queue: [entry, entry],
      originalQueue: [entry, entry],
      queueIndex: 1,
    );
    final restored = PlaybackSession.decode(session.encode())!;
    expect(restored.position, const Duration(seconds: 42));
    expect(restored.queueIndex, 1);
    expect(restored.queue, hasLength(2));
    expect(restored.encode(), session.encode());
  });
  test('malformed, future and excessive session data is ignored', () {
    for (final value in [
      null,
      '{',
      '[]',
      '{"version":2}',
      jsonEncode({
        'version': 1,
        'current': {'id': true},
      }),
    ]) {
      expect(PlaybackSession.decode(value), isNull);
    }
    expect(PlaybackSession.decode('x' * (8 * 1024 * 1024 + 1)), isNull);
  });
  test('completed session starts at beginning, not at a completed decoder', () {
    const completed = PlaybackSession(
      current: entry,
      position: Duration(seconds: 180),
      duration: Duration(seconds: 180),
      standalone: false,
    );
    expect(PlaybackSession.decode(completed.encode())!.position, Duration.zero);
  });
  test('invalid list entries and positions cannot corrupt restoration', () {
    final json =
        jsonDecode(const PlaybackSession(current: entry, position: Duration.zero, standalone: true).encode()) as Map;
    json['position'] = -50;
    json['queue'] = [
      entry.toJson(),
      {'id': 1},
      null,
    ];
    json['queueIndex'] = -1;
    final restored = PlaybackSession.decode(jsonEncode(json))!;
    expect(restored.position, Duration.zero);
    expect(restored.queue, hasLength(1));
    expect(restored.queueIndex, isNull);
  });
}
