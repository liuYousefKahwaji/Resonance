import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/platform/desktop/windows_restart.dart';

void main() {
  test('Windows handoff waits for a live helper acknowledgement', () async {
    final stage = await Directory.systemTemp.createTemp('resonance-handoff-test-');
    addTearDown(() => stage.delete(recursive: true));
    final ready = File('${stage.path}/ready');
    final script = await File('assets/windows/restart_app.ps1').copy('${stage.path}/restart.ps1');
    final helper = await startWindowsHandoff(script, [
      '-Executable',
      '${Platform.environment['SystemRoot']}/System32/whoami.exe',
      '-ParentPid',
      '$pid',
    ], ready);
    try {
      expect(int.parse(await ready.readAsString()), helper.pid);
      expect(await File('${stage.path}/restart.log').readAsString(), isNot(contains('Relaunched')));
    } finally {
      helper.kill();
      await helper.exitCode;
    }
  }, skip: !Platform.isWindows);

  test('a failed helper cannot use a stale acknowledgement or close the parent', () async {
    final stage = await Directory.systemTemp.createTemp('resonance-handoff-failure-');
    addTearDown(() => stage.delete(recursive: true));
    final ready = File('${stage.path}/ready');
    await ready.writeAsString('$pid');
    final script = File('${stage.path}/broken.ps1');
    await script.writeAsString("param([string]\$ReadyFile)\nthrow 'Intentional startup failure'\n");
    await expectLater(startWindowsHandoff(script, [], ready), throwsA(isA<ProcessException>()));
    expect(await ready.exists(), isFalse);
  }, skip: !Platform.isWindows);
}
