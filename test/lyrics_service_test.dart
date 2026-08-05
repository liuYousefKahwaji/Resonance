import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/lyrics.dart';
import 'package:resonance/services/lyrics_service.dart';

LrclibCandidate candidate({required int id, required int seconds, bool synced = true, bool plain = false}) =>
    LrclibCandidate(
      id: id,
      trackName: 'Song $id',
      artistName: 'Artist',
      albumName: 'Album',
      duration: Duration(seconds: seconds),
      instrumental: false,
      hasSyncedLyrics: synced,
      hasPlainLyrics: plain,
    );

void main() {
  test('LRCLIB candidate parses searchable record metadata', () {
    final parsed = LrclibCandidate.fromJson({
      'id': 42,
      'trackName': 'A song',
      'artistName': 'An artist',
      'albumName': 'An album',
      'duration': 184.6,
      'instrumental': false,
      'syncedLyrics': '[00:01.00]Line',
      'plainLyrics': 'Line',
    });

    expect(parsed.id, 42);
    expect(parsed.duration, const Duration(milliseconds: 184600));
    expect(parsed.hasSyncedLyrics, isTrue);
    expect(parsed.hasPlainLyrics, isTrue);
    expect(parsed.hasLyrics, isTrue);
  });

  test('automatic LRCLIB fallback preserves order within three seconds', () {
    final selected = selectAutomaticLrclibCandidate([
      candidate(id: 1, seconds: 204),
      candidate(id: 2, seconds: 203),
      candidate(id: 3, seconds: 200),
    ], const Duration(seconds: 200));

    expect(selected?.id, 2);
  });

  test('automatic LRCLIB fallback rejects unsafe and lyricless matches', () {
    final selected = selectAutomaticLrclibCandidate([
      candidate(id: 1, seconds: 203, synced: false),
      candidate(id: 2, seconds: 196),
    ], const Duration(seconds: 200));

    expect(selected, isNull);
    expect(selectAutomaticLrclibCandidate([candidate(id: 3, seconds: 200)], null), isNull);
  });

  test('automatic LRCLIB fallback compares fractional durations precisely', () {
    final close = LrclibCandidate(
      id: 4,
      trackName: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: const Duration(milliseconds: 203100),
      instrumental: false,
      hasSyncedLyrics: true,
      hasPlainLyrics: true,
    );

    expect(selectAutomaticLrclibCandidate([close], const Duration(milliseconds: 200100)), same(close));
    expect(selectAutomaticLrclibCandidate([close], const Duration(milliseconds: 200099)), isNull);
  });
}
