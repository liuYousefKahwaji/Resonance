import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Keep Resonance alive until the helper confirms it is ready to wait for us.
/// This also prevents a missing/broken PowerShell launch from closing the app.
Future<Process> startWindowsHandoff(File script, List<String> arguments, File ready) async {
  if (await ready.exists()) await ready.delete();
  final process = await Process.start(
    'powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      ...arguments,
      '-ReadyFile',
      ready.path,
    ],
    workingDirectory: script.parent.path,
    mode: ProcessStartMode.normal,
  );
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  int? exitCode;
  unawaited(process.exitCode.then((value) => exitCode = value));
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    if (await ready.exists() && int.tryParse((await ready.readAsString()).trim()) == process.pid) return process;
    if (exitCode != null) {
      throw ProcessException('powershell.exe', [], 'Restart helper exited before it was ready', exitCode!);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  process.kill();
  throw const FileSystemException('Restart helper did not become ready. Resonance is still open.');
}

Future<void> restartWindowsApp() async {
  final stage = await Directory(
    p.join((await getTemporaryDirectory()).path, 'resonance-restart', DateTime.now().microsecondsSinceEpoch.toString()),
  ).create(recursive: true);
  final script = File(p.join(stage.path, 'restart.ps1'));
  await script.writeAsString(await rootBundle.loadString('assets/windows/restart_app.ps1'), flush: true);
  await startWindowsHandoff(script, [
    '-Executable',
    Platform.resolvedExecutable,
    '-ParentPid',
    '$pid',
  ], File(p.join(stage.path, 'ready')));
  exit(0);
}
