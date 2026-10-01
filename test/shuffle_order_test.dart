import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/shuffle_order.dart';

bool same(String a, String b) => a == b;

void main() {
  test('a cycle includes every track once and starts with the playing song', () {
    for (var seed = 0; seed < 100; seed++) {
      final order = PlaylistShuffleOrder(random: Random(seed));
      final tracks = List.generate(40, (i) => '$i');
      order.reset(tracks, current: '12', same: same);
      expect(order.paths.first, '12');
      expect(order.index, 0);
      expect(order.paths.toSet(), tracks.toSet());
      expect(order.paths.length, tracks.length);
    }
  });

  test('additions join the unplayed suffix without replaying the visited prefix', () {
    for (var seed = 0; seed < 100; seed++) {
      final order = PlaylistShuffleOrder(random: Random(seed));
      const tracks = ['a', 'b', 'c', 'd', 'e'];
      order.reset(tracks, current: 'a', same: same);
      final original = order.paths;
      order.select(original[2], preferredIndex: 2, same: same);
      order.reconcile([...tracks, 'f', 'g'], same: same);
      expect(order.paths.take(3), original.take(3));
      expect(order.index, 2);
      expect(order.paths.skip(3).where(original.contains), original.skip(3));
      expect(order.paths.skip(3), containsAll(['f', 'g']));
      expect(order.paths.toSet().length, 7);
      final edited = order.paths;
      order.reconcile([...tracks, 'f', 'g'], same: same);
      expect(order.paths, edited); // Reading the queue must never reshuffle it.
    }
  });

  test('removal preserves the playing cursor and the remaining order', () {
    final order = PlaylistShuffleOrder(random: Random(7));
    order.reset(['a', 'b', 'c', 'd'], current: 'a', same: same);
    final original = order.paths;
    order.select(original[2], preferredIndex: 2, same: same);
    order.reconcile(original.skip(1).toList(), same: same);
    expect(order.paths, original.skip(1));
    expect(order.index, 1);
  });

  test('duplicate entries retain their selected occurrence after edits', () {
    final order = PlaylistShuffleOrder(random: Random(4));
    order.reset(['a', 'a', 'b', 'c'], same: same);
    final secondA = order.paths.lastIndexOf('a');
    order.select('a', preferredIndex: secondA, same: same);
    order.reconcile(['a', 'a', 'b', 'c', 'd'], same: same);
    order.select('a', same: same);
    expect(order.index, secondA);
    expect(order.paths.where((path) => path == 'a').length, 2);
    expect(order.paths.skip(order.index + 1), contains('d'));
  });

  test('playlist sessions are independent', () {
    final first = PlaylistShuffleOrder(random: Random(1));
    final second = PlaylistShuffleOrder(random: Random(2));
    first.reset(['a', 'b', 'c'], current: 'a', same: same);
    final firstPaths = first.paths;
    second.reset(['x', 'y', 'z'], current: 'y', same: same);
    expect(first.paths, firstPaths);
    expect(first.index, 0);
    expect(second.paths.first, 'y');
  });
}
