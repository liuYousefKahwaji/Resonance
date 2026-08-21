import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:resonance/core/youtube/windows_process_output.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';

class WindowsYtdlpResult {
  const WindowsYtdlpResult({
    required this.exitCode,
    required this.stdout,
    required this.stderrTail,
    required this.authenticated,
  });

  final int exitCode;
  final String stdout;
  final String stderrTail;
  final bool authenticated;
}

class WindowsYtdlpProcess {
  const WindowsYtdlpProcess({required this.process, required this.authenticated});

  final Process process;
  final bool authenticated;
}

class WindowsYtdlpRunner {
  WindowsYtdlpRunner({YoutubeAccessService? accessService, String? executableDirectory})
    : _accessService = accessService,
      _executableDirectory = executableDirectory;

  static final WindowsYtdlpRunner instance = WindowsYtdlpRunner();
  static const maximumDiagnosticBytes = 64 * 1024;

  YoutubeAccessService? _accessService;
  final String? _executableDirectory;

  void configure(YoutubeAccessService accessService) => _accessService = accessService;

  String get binDirectory => _executableDirectory ?? p.join(p.dirname(Platform.resolvedExecutable), 'bin');
  String get ytDlpPath => p.join(binDirectory, 'yt-dlp.exe');
  String get denoPath => p.join(binDirectory, 'deno.exe');
  String get ffmpegPath => p.join(binDirectory, 'ffmpeg.exe');

  List<String> buildArguments(List<String> arguments, {String? overrideBrowserId}) => [
    '--js-runtimes',
    'deno:$denoPath',
    '--force-ipv4',
    ...windowsYtDlpUtf8Arguments,
    if (overrideBrowserId != null) ...[
      '--cookies-from-browser',
      overrideBrowserId,
    ] else
      ...?_accessService?.windowsAuthArguments(),
    ...arguments,
  ];

  Future<WindowsYtdlpProcess> start(List<String> arguments, {String? overrideBrowserId}) async {
    if (!await File(ytDlpPath).exists()) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.unsupported,
        userMessage: 'The bundled YouTube downloader is missing.',
        technicalSummary: 'Missing Windows yt-dlp executable.',
      );
    }
    if (!await File(denoPath).exists()) {
      throw const YoutubeFailure(
        kind: YoutubeFailureKind.unsupported,
        userMessage: 'The bundled YouTube JavaScript runtime is missing.',
        technicalSummary: 'Missing Windows deno executable.',
      );
    }
    final authenticated = overrideBrowserId != null || _accessService?.windowsBrowserId != null;
    try {
      final process = await Process.start(
        ytDlpPath,
        buildArguments(arguments, overrideBrowserId: overrideBrowserId),
        environment: windowsYtDlpUtf8Environment,
        includeParentEnvironment: true,
        runInShell: false,
      );
      return WindowsYtdlpProcess(process: process, authenticated: authenticated);
    } on ProcessException catch (error) {
      throw YoutubeFailureClassifier.classify(error, authenticated: authenticated);
    }
  }

  Future<WindowsYtdlpResult> run(
    List<String> arguments, {
    String? overrideBrowserId,
    Duration? timeout,
    String? sourceUrl,
    bool requireOutput = false,
  }) async {
    final started = await start(arguments, overrideBrowserId: overrideBrowserId);
    final stdoutFuture = collectWindowsProcessOutput(started.process.stdout);
    final stderrFuture = _collectTail(started.process.stderr);
    try {
      final completed = Future.wait<Object>([stdoutFuture, stderrFuture, started.process.exitCode]);
      final values = timeout == null ? await completed : await completed.timeout(timeout);
      final result = WindowsYtdlpResult(
        exitCode: values[2] as int,
        stdout: values[0] as String,
        stderrTail: YoutubeFailureClassifier.sanitize(values[1] as String),
        authenticated: started.authenticated,
      );
      if (result.exitCode != 0 || (requireOutput && result.stdout.trim().isEmpty)) {
        final failure = failureForResult(result, sourceUrl: sourceUrl);
        _accessService?.observeFailure(failure);
        throw failure;
      }
      return result;
    } on TimeoutException {
      started.process.kill();
      final failure = YoutubeFailure(
        kind: YoutubeFailureKind.network,
        userMessage: 'YouTube took too long to respond.',
        technicalSummary: 'yt-dlp timed out.',
        sourceUrl: sourceUrl,
      );
      _accessService?.observeFailure(failure);
      throw failure;
    }
  }

  YoutubeFailure failureForResult(WindowsYtdlpResult result, {String? sourceUrl}) => YoutubeFailureClassifier.classify(
    result.stderrTail.isEmpty ? 'yt-dlp exited with code ${result.exitCode}' : result.stderrTail,
    authenticated: result.authenticated,
    sourceUrl: sourceUrl,
  );

  YoutubeFailure failureForDiagnostics(String diagnostics, {required bool authenticated, String? sourceUrl}) {
    final failure = YoutubeFailureClassifier.classify(diagnostics, authenticated: authenticated, sourceUrl: sourceUrl);
    _accessService?.observeFailure(failure);
    return failure;
  }

  Future<void> testAccess(String browserId, String sourceUrl) async {
    final result = await run(
      ['--dump-single-json', '--skip-download', '--no-playlist', '--playlist-end', '1', sourceUrl],
      overrideBrowserId: browserId,
      timeout: const Duration(seconds: 30),
      sourceUrl: sourceUrl,
      requireOutput: true,
    );
    final output = result.stdout;
    if (!RegExp(r'"id"\s*:\s*"[A-Za-z0-9_-]{6,}"').hasMatch(output)) {
      throw YoutubeFailure(
        kind: YoutubeFailureKind.unknown,
        userMessage: 'YouTube did not return a valid video during the access test.',
        technicalSummary: 'Access test output did not contain a video ID.',
        sourceUrl: sourceUrl,
      );
    }
  }

  static Future<String> _collectTail(Stream<List<int>> source) async {
    final bytes = <int>[];
    await for (final chunk in source) {
      bytes.addAll(chunk);
      if (bytes.length > maximumDiagnosticBytes) {
        bytes.removeRange(0, bytes.length - maximumDiagnosticBytes);
      }
    }
    return decodeWindowsProcessOutput(bytes);
  }
}
