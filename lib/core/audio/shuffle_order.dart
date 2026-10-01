import 'dart:math';

/// A playlist's shuffle session. Edits preserve the visited prefix and the
/// remaining order; additions are mixed only into the unplayed suffix.
class PlaylistShuffleOrder {
  PlaylistShuffleOrder({Random? random}) : _random = random ?? Random();

  final Random _random;
  List<String> _paths = [];
  int _index = -1;

  List<String> get paths => List.unmodifiable(_paths);
  int get index => _index;

  void reset(List<String> tracks, {String? current, required bool Function(String, String) same}) {
    _paths = List.of(tracks)..shuffle(_random);
    _index = current == null ? -1 : _paths.indexWhere((path) => same(path, current));
    if (_index >= 0) {
      final playing = _paths.removeAt(_index);
      _paths.insert(0, playing);
      _index = 0;
    }
  }

  void select(String current, {int? preferredIndex, required bool Function(String, String) same}) {
    if (preferredIndex != null &&
        preferredIndex >= 0 &&
        preferredIndex < _paths.length &&
        same(_paths[preferredIndex], current)) {
      _index = preferredIndex;
    } else if (_index < 0 || _index >= _paths.length || !same(_paths[_index], current)) {
      _index = _paths.indexWhere((path) => same(path, current));
    }
  }

  void reconcile(List<String> tracks, {required bool Function(String, String) same}) {
    final remaining = List.of(tracks);
    final retained = <String>[];
    var retainedIndex = -1;
    var insertionStart = 0;
    for (var index = 0; index < _paths.length; index++) {
      final match = remaining.indexWhere((path) => same(path, _paths[index]));
      if (match < 0) continue;
      retained.add(remaining.removeAt(match));
      if (index <= _index) insertionStart = retained.length;
      if (index == _index) retainedIndex = retained.length - 1;
    }
    remaining.shuffle(_random);
    for (final path in remaining) {
      final position = insertionStart + _random.nextInt(retained.length - insertionStart + 1);
      retained.insert(position, path);
    }
    _paths = retained;
    _index = retainedIndex;
  }
}
