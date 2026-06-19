import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class TrayService {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await trayManager.setIcon('assets/images/tray_icon.ico');
    await trayManager.setToolTip('Resonance');
    final menu = Menu(
      items: [
        MenuItem(key: 'open', label: 'Open', onClick: (_) => _showWindow()),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Exit', onClick: (_) => _exitApp()),
      ],
    );
    await trayManager.setContextMenu(menu);
    _initialized = true;
  }

  static Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  static Future<void> _exitApp() async {
    await trayManager.destroy();
    await windowManager.destroy();
  }
}