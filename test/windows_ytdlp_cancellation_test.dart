import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';
import 'package:resonance/services/youtube/youtube_request.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';

class _Process extends Fake implements Process {
  final output = StreamController<List<int>>(), errors = StreamController<List<int>>();
  final exit = Completer<int>();
  bool killed = false;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    unawaited(output.close());
    unawaited(errors.close());
    if (!exit.isCompleted) exit.complete(-1);
    return true;
  }
}

class _Runner extends WindowsYtdlpRunner {
  final owned = _Process();
  @override
  Future<WindowsYtdlpProcess> start(
    List<String> arguments, {
    String? overrideBrowserId,
    String? overrideCookieFile,
    bool guest = false,
  }) async => WindowsYtdlpProcess(process: owned, authenticated: false);
}

void main() {
  test('superseding Windows extraction kills its process and settles without a network response', () async {
    final runner = _Runner(), request = YoutubeRequest();
    final operation = runner.run(['--dump-single-json'], request: request);
    final result = expectLater(operation, throwsA(isA<YoutubeRequestCancelled>()));
    await Future<void>.delayed(Duration.zero);
    request.cancel();
    await result.timeout(const Duration(milliseconds: 250));
    expect(runner.owned.killed, isTrue);
  });
  test('a bounded extraction kills a stalled process', () async {
    final runner = _Runner();
    await expectLater(
      runner.run([], timeout: const Duration(milliseconds: 20)),
      throwsA(isA<YoutubeFailure>().having((failure) => failure.kind, 'kind', YoutubeFailureKind.network)),
    );
    expect(runner.owned.killed, isTrue);
  });
  test('download cache accepts exact audio and rejects expired links and mismatched identities', () {
    final runner = WindowsYtdlpRunner();
    const source = 'https://www.youtube.com/watch?v=abcdefghijk';
    String info(String id, String url) => jsonEncode({'id': id, 'url': url, 'vcodec': 'none'});
    runner.rememberAudioInfo(source, info('01234567890', 'https://audio.test/file'));
    expect(runner.audioInfoFor(source), isNull);
    runner.rememberAudioInfo(source, info('abcdefghijk', 'https://audio.test/file?expire=1'));
    expect(runner.audioInfoFor(source), isNull);
    final valid = info('abcdefghijk', 'https://audio.test/file');
    runner.rememberAudioInfo(source, valid);
    expect(runner.audioInfoFor(source), valid);
    runner.forgetAudioInfo(source);
    expect(runner.audioInfoFor(source), isNull);
  });
}
