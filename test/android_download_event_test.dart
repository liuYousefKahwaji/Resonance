import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/youtube/android_download_event.dart';

void main() {
  test('UTF-8 JSON transport preserves Unicode metadata and filename', () {
    const values = [
      ('øneheart - apathy (slowed)', 'øneheart'),
      ('São Paulo (Official Audio)', 'Anitta'),
      ('東京の夜', '宇多田ヒカル'),
      ('midnight drive 🎧', 'artist ✨'),
    ];

    for (final (title, artist) in values) {
      final path = '/music/$title.mp3';
      final payload = base64Encode(
        utf8.encode(
          jsonEncode({
            'path': path,
            'title': title,
            'artist': artist,
            'coverPath': '/covers/$title.jpg',
            'videoId': 'jNQXAC9IVRw',
          }),
        ),
      );

      final event = parseAndroidDownloadTrackEvent('track-json:$payload');
      expect(event, isNotNull);
      expect(event!.path, path);
      expect(event.title, title);
      expect(event.artist, artist);
      expect(event.coverPath, '/covers/$title.jpg');
    }
  });

  test('legacy malformed percent bytes do not throw FormatException', () {
    final invalidByte = parseAndroidDownloadTrackEvent('track:/music/apathy.mp3|%F8neheart|artist|||');
    final missingExtension = parseAndroidDownloadTrackEvent('track:/music/sao.mp3|S%E3o%20Paulo|artist|||');

    expect(invalidByte?.title, 'øneheart');
    expect(missingExtension?.title, 'São Paulo');
  });

  test('malformed structured event is ignored without breaking the stream', () {
    expect(parseAndroidDownloadTrackEvent('track-json:not-base64'), isNull);
  });
}
