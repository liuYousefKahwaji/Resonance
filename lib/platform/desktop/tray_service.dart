import 'package:tray_manager/tray_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:resonance/l10n/app_strings.dart';

class TrayService {
  static bool _initialized = false;

  static Future<void> init({Locale locale = const Locale('en')}) async {
    if (_initialized) return;
    await trayManager.setIcon('assets/images/tray_icon.ico');
    await _applyLocale(locale);
    _initialized = true;
  }

  static Future<void> updateLocale(Locale locale) async {
    if (!_initialized) return;
    await _applyLocale(locale);
  }

  static Future<void> _applyLocale(Locale locale) async {
    final strings = AppStrings(locale);
    await trayManager.setToolTip(strings.text('Resonance'));
    final menu = Menu(
      items: [
        MenuItem(key: 'open', label: strings.text('Open')),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: strings.text('Exit')),
      ],
    );
    await trayManager.setContextMenu(menu);
  }
}
