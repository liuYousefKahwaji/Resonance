import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/services/youtube/youtube_request.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';
import 'package:resonance/widgets/youtube/windows_youtube.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cancel terminates owned Windows download and never imports late output', () async {
    final folder = await Directory.systemTemp.createTemp('resonance-download-cancel-');
    SharedPreferences.setMockInitialValues({'download_directory': folder.path});
    final runner = _OwnedProcessRunner();
    final request = YoutubeRequest();
    var imports = 0;
    try {
      await expectLater(
        MediaDownloader(runner: runner)
            .downloadAudio(
              url: 'https://www.youtube.com/watch?v=abcdefghijk',
              request: request,
              onProgress: (percent, _) {
                if (percent > 0) request.cancel();
              },
              onTrackDownloaded: (_, __) {
                imports++;
              },
            )
            .timeout(const Duration(seconds: 12)),
        throwsA(isA<YoutubeRequestCancelled>()),
      );
      expect(runner.starts, 1);
      expect(await runner.owned!.exitCode.timeout(const Duration(seconds: 1)), isNot(0));
      expect(imports, 0);
    } finally {
      runner.owned?.kill();
      await folder.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}

class _OwnedProcessRunner extends WindowsYtdlpRunner {
  Process? owned;
  int starts = 0;
  @override
  Future<WindowsYtdlpProcess> start(
    List<String> arguments, {
    String? overrideBrowserId,
    String? overrideCookieFile,
    bool guest = false,
  }) async {
    starts++;
    owned = await Process.start('python', [
      '-u',
      '-c',
      "import time; print('resonance_progress:1.0%', flush=True); time.sleep(30)",
    ]);
    return WindowsYtdlpProcess(process: owned!, authenticated: false);
  }
}
