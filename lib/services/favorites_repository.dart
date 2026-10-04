import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:resonance/core/storage/file_service.dart';

/// Favorites use their own protected numbered playlist. Membership is shared
/// across library views; source mappings join downloaded songs to their URLs.
class FavoritesRepository extends ChangeNotifier {
  static const gold = Color(0xFFFFD600);
  final FileService files;
  late final StreamSubscription<PlaylistMutation> _subscription;
  Set<String> _keys = {};
  Map<String, String> _sourceIds = {};
  int _generation = 0;
  bool _disposed = false;
  Future<void> _operations = Future<void>.value();

  FavoritesRepository({FileService? files}) : files = files ?? FileService() {
    _subscription = FileService.mutations.listen((mutation) {
      // Imports may introduce a local file mapped to an already-favorited URL.
      unawaited(refresh().catchError((Object error) => debugPrint('[Favorites] Refresh failed: $error')));
    });
  }

  bool isFavorite(String track) => _keys.contains(files.favoriteIdentity(track, sourceIds: _sourceIds));

  bool allFavorite(Iterable<String> tracks) => tracks.isNotEmpty && tracks.every(isFavorite);

  bool mostlyFavorite(Iterable<String> tracks) {
    final selected = tracks.toList(growable: false);
    return selected.where(isFavorite).length * 2 > selected.length;
  }

  Future<void> setTracks(Iterable<String> tracks, bool favorite) {
    final selected = tracks.toList(growable: false);
    final operation = _operations.then((_) async {
      await files.setTracksFavorite(selected, favorite);
      await refresh();
    });
    _operations = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    final tracks = await files.readPlaylistTracks(FileService.favoritesPlaylistNumber);
    final sources = await files.favoriteSourceIds();
    if (_disposed || generation != _generation) return;
    _sourceIds = sources;
    _keys = tracks.map((track) => files.favoriteIdentity(track, sourceIds: sources)).toSet();
    notifyListeners();
  }

  Future<void> toggle(String track) {
    final operation = _operations.then((_) async {
      await files.toggleTrackFavorite(track);
      await refresh();
    });
    _operations = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
