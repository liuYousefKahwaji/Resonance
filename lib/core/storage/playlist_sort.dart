import 'dart:math';
import 'package:crypto/crypto.dart';
import 'dart:convert';

enum PlaylistSortMode { dateAdded, title, random, custom }

class PlaylistSortState {
  final PlaylistSortMode mode;
  final bool descending;
  final bool favoritesFirst;
  final int seed;
  final List<String> addedOrder;

  const PlaylistSortState({
    this.mode = PlaylistSortMode.dateAdded,
    this.descending = false,
    this.favoritesFirst = false,
    this.seed = 0,
    this.addedOrder = const [],
  });

  PlaylistSortState copyWith({
    PlaylistSortMode? mode,
    bool? descending,
    bool? favoritesFirst,
    int? seed,
    List<String>? addedOrder,
  }) => PlaylistSortState(
    mode: mode ?? this.mode,
    descending: descending ?? this.descending,
    favoritesFirst: favoritesFirst ?? this.favoritesFirst,
    seed: seed ?? this.seed,
    addedOrder: addedOrder ?? this.addedOrder,
  );

  static int newSeed() => Random.secure().nextInt(0x7fffffff);

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'descending': descending,
    'favoritesFirst': favoritesFirst,
    'seed': seed,
    'addedOrder': addedOrder,
  };

  factory PlaylistSortState.fromJson(Map<String, dynamic> json) => PlaylistSortState(
    mode: PlaylistSortMode.values.firstWhere(
      (mode) => mode.name == json['mode'],
      orElse: () => PlaylistSortMode.dateAdded,
    ),
    descending: json['descending'] == true,
    favoritesFirst: json['favoritesFirst'] == true,
    seed: json['seed'] is int ? json['seed'] as int : 0,
    addedOrder: json['addedOrder'] is List ? (json['addedOrder'] as List).whereType<String>().toList() : [],
  );

  /// Keep surviving occurrences in their original insertion order, including
  /// duplicate playlist entries. Re-added songs receive a new insertion position.
  PlaylistSortState reconcile(List<String> tracks) {
    final remaining = <String, int>{};
    for (final track in tracks) {
      remaining.update(track, (count) => count + 1, ifAbsent: () => 1);
    }
    final added = <String>[];
    for (final track in addedOrder) {
      if ((remaining[track] ?? 0) > 0) {
        added.add(track);
        remaining[track] = remaining[track]! - 1;
      }
    }
    for (final track in tracks) {
      if ((remaining[track] ?? 0) > 0) {
        added.add(track);
        remaining[track] = remaining[track]! - 1;
      }
    }
    return copyWith(addedOrder: added);
  }

  List<String> sorted(List<String> tracks, {Map<String, String> titles = const {}, Set<String> favorites = const {}}) {
    final indices = List.generate(tracks.length, (i) => i);
    final slots = <String, List<int>>{};
    for (var i = 0; i < addedOrder.length; i++) {
      (slots[addedOrder[i]] ??= []).add(i);
    }
    final ranks = [
      for (var i = 0; i < tracks.length; i++)
        slots[tracks[i]]?.isNotEmpty == true ? slots[tracks[i]]!.removeAt(0) : addedOrder.length + i,
    ];
    final randomRanks = <String, String>{};
    String randomRank(String track) =>
        randomRanks.putIfAbsent(track, () => sha256.convert(utf8.encode('$seed\u0000$track')).toString());
    indices.sort((a, b) {
      if (favoritesFirst) {
        final favoriteOrder = (favorites.contains(tracks[b]) ? 1 : 0) - (favorites.contains(tracks[a]) ? 1 : 0);
        if (favoriteOrder != 0) return favoriteOrder;
      }
      if (mode == PlaylistSortMode.custom) return a.compareTo(b);
      var result = switch (mode) {
        PlaylistSortMode.title => compareAlphanumeric(titles[tracks[a]] ?? tracks[a], titles[tracks[b]] ?? tracks[b]),
        PlaylistSortMode.random => randomRank(tracks[a]).compareTo(randomRank(tracks[b])),
        _ => ranks[a].compareTo(ranks[b]),
      };
      if (result == 0) result = ranks[a].compareTo(ranks[b]);
      return descending ? -result : result;
    });
    return [for (final index in indices) tracks[index]];
  }
}

int compareAlphanumeric(String first, String second) {
  final chunks = RegExp(r'\d+|\D+');
  final a = chunks.allMatches(first.trim().toLowerCase()).map((m) => m.group(0)!).toList();
  final b = chunks.allMatches(second.trim().toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < min(a.length, b.length); i++) {
    final numberA = BigInt.tryParse(a[i]);
    final numberB = BigInt.tryParse(b[i]);
    final result = numberA != null && numberB != null ? numberA.compareTo(numberB) : a[i].compareTo(b[i]);
    if (result != 0) return result;
  }
  return a.length.compareTo(b.length);
}
