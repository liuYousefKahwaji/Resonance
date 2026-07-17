import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:resonance/models/download_history_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DownloadHistoryRepository {
  static const storageKey = 'download_history_v1';
  static Future<void> _pendingWrite = Future<void>.value();
  static int _idSequence = 0;

  const DownloadHistoryRepository();

  Future<List<DownloadHistoryEntry>> load() async {
    await _pendingWrite;
    final prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(storageKey));
  }

  Future<void> recordSuccess({
    required String source,
    required String localPath,
    String? title,
    String? artist,
    DateTime? downloadedAt,
  }) {
    return add(
      DownloadHistoryEntry(
        id: _newId(),
        title: _nonEmpty(title) ?? p.basenameWithoutExtension(localPath),
        artist: _nonEmpty(artist) ?? 'Unknown artist',
        source: source,
        localPath: localPath,
        downloadedAt: (downloadedAt ?? DateTime.now()).toUtc(),
        succeeded: true,
      ),
    );
  }

  Future<void> recordFailure({
    required String source,
    required Object error,
    String? title,
    String? artist,
    DateTime? downloadedAt,
  }) {
    return add(
      DownloadHistoryEntry(
        id: _newId(),
        title: _nonEmpty(title) ?? _sourceLabel(source),
        artist: _nonEmpty(artist) ?? 'Unknown artist',
        source: source,
        localPath: '',
        downloadedAt: (downloadedAt ?? DateTime.now()).toUtc(),
        succeeded: false,
        failureMessage: error.toString().replaceFirst('Exception: ', ''),
      ),
    );
  }

  Future<void> add(DownloadHistoryEntry entry) => _mutate((entries) {
    entries.removeWhere((existing) => existing.id == entry.id);
    entries.insert(0, entry);
  });

  Future<void> remove(String id) => _mutate((entries) => entries.removeWhere((entry) => entry.id == id));

  Future<void> clear() => _mutate((entries) => entries.clear());

  Future<void> _mutate(void Function(List<DownloadHistoryEntry> entries) update) {
    final operation = _pendingWrite.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final entries = _decode(prefs.getString(storageKey));
      update(entries);
      await prefs.setString(storageKey, jsonEncode(entries.map((entry) => entry.toJson()).toList()));
    });
    _pendingWrite = operation.catchError((_) {});
    return operation;
  }

  static List<DownloadHistoryEntry> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <DownloadHistoryEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <DownloadHistoryEntry>[];
      return [
        for (final item in decoded)
          if (item is Map) DownloadHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
      ]..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    } catch (_) {
      // A damaged history must never prevent downloads or Settings from opening.
      return <DownloadHistoryEntry>[];
    }
  }

  static String _newId() => '${DateTime.now().microsecondsSinceEpoch}-${_idSequence++}';

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String _sourceLabel(String source) {
    final uri = Uri.tryParse(source);
    final videoId = uri?.queryParameters['v'];
    if (videoId != null && videoId.isNotEmpty) return videoId;
    if (uri != null && uri.pathSegments.isNotEmpty) return uri.pathSegments.last;
    return source.trim().isEmpty ? 'Unknown track' : source;
  }
}
