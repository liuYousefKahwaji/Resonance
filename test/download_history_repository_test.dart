import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/download_history_entry.dart';
import 'package:resonance/services/download_history_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('persists successful and failed downloads newest first', () async {
    const repository = DownloadHistoryRepository();
    await repository.recordSuccess(
      source: 'https://youtu.be/jNQXAC9IVRw',
      localPath: '/music/東京 🎧.mp3',
      title: 'São Paulo 🎧',
      artist: 'øneheart',
      downloadedAt: DateTime.utc(2026, 7, 15),
    );
    await repository.recordFailure(
      source: 'https://youtu.be/failure0001',
      title: 'Не удалось',
      artist: '测试艺术家',
      error: const FormatException('Invalid UTF-8 byte'),
      downloadedAt: DateTime.utc(2026, 7, 16),
    );

    final entries = await repository.load();
    expect(entries, hasLength(2));
    expect(entries.first.succeeded, isFalse);
    expect(entries.first.title, 'Не удалось');
    expect(entries.last.localPath, '/music/東京 🎧.mp3');
    expect(entries.last.artist, 'øneheart');
  });

  test('removes one entry and clears without touching files', () async {
    final prefs = await SharedPreferences.getInstance();
    final entry = DownloadHistoryEntry(
      id: 'entry-1',
      title: 'Track',
      artist: 'Artist',
      source: 'video-id',
      localPath: '/music/track.mp3',
      downloadedAt: DateTime.utc(2026, 7, 16),
      succeeded: true,
    );
    await prefs.setString(DownloadHistoryRepository.storageKey, jsonEncode([entry.toJson()]));

    const repository = DownloadHistoryRepository();
    await repository.remove('entry-1');
    expect(await repository.load(), isEmpty);

    await repository.add(entry);
    await repository.clear();
    expect(await repository.load(), isEmpty);
  });

  test('damaged stored JSON is treated as an empty history', () async {
    SharedPreferences.setMockInitialValues({DownloadHistoryRepository.storageKey: '{bad json'});
    expect(await const DownloadHistoryRepository().load(), isEmpty);
  });
}
