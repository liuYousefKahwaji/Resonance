import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:resonance/models/listening_history_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ListeningHistoryRepository extends ChangeNotifier {
  ListeningHistoryRepository._();

  static final instance = ListeningHistoryRepository._();
  static const storageKey = 'resonance_listening_history_v1';
  static const maxEntries = 100;

  SharedPreferences? _preferences;
  List<ListeningHistoryEntry> _entries = const [];
  Future<void> _writeTail = Future<void>.value();

  List<ListeningHistoryEntry> get entries => List.unmodifiable(_entries);

  Future<void> initialize({SharedPreferences? preferences}) async {
    _preferences = preferences ?? await SharedPreferences.getInstance();
    _entries = _decode(_preferences!.getString(storageKey));
    notifyListeners();
  }

  Future<void> record(ListeningHistoryEntry entry) => _serialize(() async {
    final updated = _entries.where((item) => item.trackPath != entry.trackPath).toList();
    updated.insert(0, entry);
    _entries = updated.take(maxEntries).toList(growable: false);
    await _persist();
  });

  Future<void> remove(String trackPath) => _serialize(() async {
    _entries = _entries.where((item) => item.trackPath != trackPath).toList(growable: false);
    await _persist();
  });

  Future<void> clear() => _serialize(() async {
    _entries = const [];
    await _persist();
  });

  Future<void> _persist() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    await preferences.setString(storageKey, jsonEncode([for (final entry in _entries) entry.toJson()]));
    notifyListeners();
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _writeTail.catchError((_) {}).then((_) => operation());
    _writeTail = next;
    return next;
  }

  static List<ListeningHistoryEntry> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final value in decoded)
          if (value is Map) ListeningHistoryEntry.fromJson(Map<String, dynamic>.from(value)),
      ].where((entry) => entry.trackPath.isNotEmpty).take(maxEntries).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}
