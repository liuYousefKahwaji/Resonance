import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';
import 'package:resonance/widgets/youtube/windows_youtube.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Process implements Process {
  _Process(this.output, this.error, this.code);
  final String output, error;
  final int code;
  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(output));
  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(error));
  @override
  Future<int> get exitCode async => code;
  @override
  int get pid => 1;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _Runner extends WindowsYtdlpRunner {
  _Runner(this.responses, {this.configured = true});
  final List<Process> responses;
  final bool configured;
  final List<bool> guests = [];
  final List<List<String>> arguments = [];
  @override
  bool get hasConfiguredAccess => configured;
  @override
  Future<WindowsYtdlpProcess> start(
    List<String> args, {
    String? overrideBrowserId,
    String? overrideCookieFile,
    bool guest = false,
  }) async {
    guests.add(guest);
    arguments.add(args);
    return WindowsYtdlpProcess(process: responses.removeAt(0), authenticated: !guest);
  }
}

class _CachedRunner extends _Runner {
  _CachedRunner(super.responses);
  bool cleared = false;
  int reused = 0;
  bool rejectInput = false;
  @override
  String? audioInfoFor(String url) => cleared ? null : '{}';
  @override
  void forgetAudioInfo(String url) {
    cleared = true;
  }

  @override
  Future<WindowsYtdlpProcess> startWithAudioInfo(List<String> args, String info, {bool guest = true}) {
    reused++;
    if (rejectInput) throw const FileSystemException('Cached input pipe closed');
    return start(args, guest: guest);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File audio;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('resonance-download-regression-');
    audio = await File(p.join(directory.path, 'Song [aaaaaaaaaaa].mp3')).writeAsBytes([1, 2, 3]);
    SharedPreferences.setMockInitialValues({'download_directory': directory.path});
  });
  tearDown(() => directory.delete(recursive: true));

  test('completed authoritative file survives a later extractor error without downloading again', () async {
    final runner = _Runner([
      _Process('${audio.path}|aaaaaaaaaaa\n', 'ERROR: unrelated later playlist item unavailable', 1),
    ]);
    final paths = <String>[];
    await MediaDownloader(runner: runner).downloadAudio(
      url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
      onProgress: (_, __) {},
      onTrackDownloaded: (path, id) {
        expect(id, 'aaaaaaaaaaa');
        paths.add(path);
      },
    );
    expect(paths, [audio.path]);
    expect(runner.guests, [true]);
    expect(runner.arguments.single, contains(endsWith('%(title)s [%(id)s].%(ext)s')));
    expect(runner.arguments.single, isNot(contains('--audio-format')), reason: 'Original audio does not transcode');
  });

  test('MP3 remains selectable for all download entry points', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('audio_download_format', 'mp3');
    final runner = _Runner([_Process('${audio.path}|aaaaaaaaaaa\n', '', 0)]);
    await MediaDownloader(runner: runner).downloadAudio(
      url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
      onProgress: (_, __) {},
      onTrackDownloaded: (_, __) {},
    );
    expect(runner.arguments.single, containsAllInOrder(['-x', '--audio-format', 'mp3']));
  });

  test('a rejected cached media link falls back once to fresh extraction without an account detour', () async {
    final runner = _CachedRunner([
      _Process('', 'ERROR: HTTP Error 403: expired media link', 1),
      _Process('${audio.path}|aaaaaaaaaaa\n', '', 0),
    ]);
    final paths = <String>[];
    await MediaDownloader(runner: runner).downloadAudio(
      url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
      onProgress: (_, __) {},
      onTrackDownloaded: (path, _) => paths.add(path),
    );
    expect(paths, [audio.path]);
    expect(runner.reused, 1);
    expect(runner.cleared, isTrue);
    expect(runner.guests, [true, true]);
    expect(runner.arguments.last, contains('https://www.youtube.com/watch?v=aaaaaaaaaaa'));
    expect(runner.arguments.last, contains('--no-continue'));
  });

  test('cached input startup failure also falls back to ordinary extraction', () async {
    final runner = _CachedRunner([_Process('${audio.path}|aaaaaaaaaaa\n', '', 0)])..rejectInput = true;
    final paths = <String>[];
    await MediaDownloader(runner: runner).downloadAudio(
      url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
      onProgress: (_, __) {},
      onTrackDownloaded: (path, _) => paths.add(path),
    );
    expect(paths, [audio.path]);
    expect(runner.reused, 1);
    expect(runner.cleared, isTrue);
  });

  test('public extraction uses no browser and restricted audio falls back immediately to account', () async {
    final runner = _Runner([
      _Process('', 'ERROR: Sign in to confirm your age', 1),
      _Process('${audio.path}|aaaaaaaaaaa\n', '', 0),
    ]);
    final paths = <String>[];
    await MediaDownloader(runner: runner)
        .downloadAudio(
          url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
          onProgress: (_, __) {},
          onTrackDownloaded: (path, _) {
            paths.add(path);
          },
        )
        .timeout(const Duration(seconds: 1));
    expect(runner.guests, [true, false]);
    expect(paths, [audio.path]);
  });

  test('the completion for a different video cannot replace the requested stream', () async {
    await audio.delete();
    final other = await File(p.join(directory.path, 'Other [bbbbbbbbbbb].mp3')).writeAsBytes([1, 2, 3]);
    final runner = _Runner([_Process('${other.path}|bbbbbbbbbbb\n', '', 0)]);
    await expectLater(
      MediaDownloader(runner: runner).downloadAudio(
        url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
        onProgress: (_, __) {},
        onTrackDownloaded: (_, __) => fail('Wrong song was imported'),
      ),
      throwsA(anything),
    );
  });

  test('zero-byte output is not accepted as a successful download', () async {
    await audio.writeAsBytes([]);
    final runner = _Runner([_Process('${audio.path}|aaaaaaaaaaa\n', 'ERROR: Video unavailable', 1)], configured: false);
    await expectLater(
      MediaDownloader(runner: runner).downloadAudio(
        url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
        onProgress: (_, __) {},
        onTrackDownloaded: (_, __) => fail('Invalid audio was imported'),
      ),
      throwsA(anything),
    );
  });
}
