import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/youtube/windows_process_output.dart';

void main() {
  test('UTF-8 Windows downloader output preserves Unicode paths exactly', () {
    const output = r'C:\Music\øneheart — São Paulo 東京 🎧.mp3|jNQXAC9IVRw';

    expect(decodeWindowsProcessOutput(utf8.encode(output)), output);
  });

  test('legacy Windows bytes cannot abort a successful Unicode download', () {
    const output = r'C:\Music\øneheart - São Paulo.mp3|jNQXAC9IVRw';
    final legacyBytes = latin1.encode(output);

    expect(decodeWindowsProcessOutput(legacyBytes), output);
  });

  test('completed process output is decoded after all byte chunks arrive', () async {
    const output = r'C:\Music\øneheart - São Paulo.mp3|jNQXAC9IVRw';
    final bytes = latin1.encode(output);
    final decoded = await collectWindowsProcessOutput(
      Stream<List<int>>.fromIterable([bytes.sublist(0, 12), bytes.sublist(12, 26), bytes.sublist(26)]),
    );

    expect(decoded, output);
  });

  test('yt-dlp is explicitly configured for UTF-8 output', () {
    expect(windowsYtDlpUtf8Environment['PYTHONUTF8'], '1');
    expect(windowsYtDlpUtf8Environment['PYTHONIOENCODING'], 'utf-8');
    expect(windowsYtDlpUtf8Arguments, ['--encoding', 'utf-8']);
  });
}
