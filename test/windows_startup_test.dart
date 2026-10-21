import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/platform/desktop/windows_startup.dart';
import 'package:resonance/widgets/windows_startup_toggle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('resonance/windows_shutdown');
  test('startup uses native registration state and disabling removes the registration', () async {
    var enabled = false;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'setStartup') enabled = (call.arguments as Map)['enabled'] as bool;
      return enabled;
    });
    const service = WindowsStartup();
    expect(await service.read(), false);
    expect(await service.setEnabled(true), true);
    await service.refreshRegisteredPath();
    expect(await service.setEnabled(false), false);
    expect(calls, ['getStartup', 'setStartup', 'refreshStartup', 'setStartup']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isWindows);

  testWidgets('startup toggle loads OS state and retains it when an OS write fails', (tester) async {
    final service = _Startup();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WindowsStartupToggle(startup: service)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Launch on startup'), findsOneWidget);
    expect(find.textContaining('even with tray mode enabled'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(service.enabled, true);
    expect(tester.widget<Switch>(find.byType(Switch)).value, true);
    service.fail = true;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, true);
    expect(find.text('Could not change the Windows startup setting.'), findsOneWidget);
  });
}

class _Startup extends WindowsStartup {
  bool enabled = false, fail = false;
  @override
  Future<bool> read() async => enabled;
  @override
  Future<bool> setEnabled(bool value) async {
    if (fail) throw StateError('Access denied');
    return enabled = value;
  }
}
