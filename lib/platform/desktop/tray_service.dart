import 'package:tray_manager/tray_manager.dart';

class TrayService {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await trayManager.setIcon('assets/images/tray_icon.ico');
    await trayManager.setToolTip('Resonance');
    final menu = Menu(
      items: [
        MenuItem(key: 'open', label: 'Open'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Exit'),
      ],
    );
    await trayManager.setContextMenu(menu);
    _initialized = true;
  }
}
