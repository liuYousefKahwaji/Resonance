import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/main.dart';
import 'package:resonance/platform/desktop/tray_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('maximized taskbar restore resumes tickers on maximize and focus events', () {
    var visible = true;
    final handler = DesktopWindowHandler(
      onShow: () {},
      onExit: () {},
      onSuspend: () => visible = false,
      onResume: () => visible = true,
      trayMode: TrayMode.noTray,
    );
    addTearDown(handler.dispose);
    for (final resume in [
      handler.onWindowMaximize,
      handler.onWindowFocus,
      handler.onWindowRestore,
      handler.onWindowUnmaximize,
    ]) {
      handler.onWindowMaximize();
      handler.onWindowMinimize();
      expect(visible, isFalse);
      resume();
      expect(visible, isTrue);
    }
  });

  test('ordinary minimize notification does not send another minimize command', () async {
    final commands = <String>[];
    const channel = MethodChannel('window_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call.method);
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final handler = DesktopWindowHandler(
      onShow: () {},
      onExit: () {},
      onSuspend: () {},
      onResume: () {},
      trayMode: TrayMode.noTray,
    );
    addTearDown(handler.dispose);
    handler.onWindowMinimize();
    await Future<void>.delayed(Duration.zero);
    expect(commands, isEmpty);
  });
}
