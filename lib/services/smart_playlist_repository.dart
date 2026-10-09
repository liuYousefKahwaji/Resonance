import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/models/smart_playlist.dart';

class SmartPlaylistRepository extends ChangeNotifier {
  static const storageKey = 'smart_playlists_v1';
  List<SmartPlaylist> playlists = [];
  bool _disposed = false;
  Future<void> load() async {
    try {
      playlists = [
        for (final raw in jsonDecode((await SharedPreferences.getInstance()).getString(storageKey) ?? '[]') as List)
          SmartPlaylist.fromJson(Map<String, dynamic>.from(raw as Map)),
      ];
    } catch (_) {
      playlists = [];
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> save(SmartPlaylist playlist) async {
    playlists = [...playlists.where((entry) => entry.id != playlist.id), playlist];
    await _persist();
  }

  Future<void> remove(String id) async {
    playlists.removeWhere((entry) => entry.id == id);
    await _persist();
  }

  Future<void> _persist() async {
    await (await SharedPreferences.getInstance()).setString(
      storageKey,
      jsonEncode(playlists.map((entry) => entry.toJson()).toList()),
    );
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() { _disposed = true; super.dispose(); }
}
