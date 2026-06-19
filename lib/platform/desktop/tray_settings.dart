import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TraySettings extends StatefulWidget {
  final TrayMode selectedMode;
  final ValueChanged<TrayMode?> onChanged;

  const TraySettings({
    super.key,
    required this.selectedMode,
    required this.onChanged,
  });

  @override
  State<TraySettings> createState() => _TraySettingsState();
}

class _TraySettingsState extends State<TraySettings> {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Row(
          children: [
            Radio<TrayMode>(
              value: TrayMode.closeToTray,
              groupValue: widget.selectedMode,
              onChanged: widget.onChanged,
            ),
            const Text('Close to tray'),
          ],
        ),
        Row(
          children: [
            Radio<TrayMode>(
              value: TrayMode.minimizeToTray,
              groupValue: widget.selectedMode,
              onChanged: widget.onChanged,
            ),
            const Text('Minimize to tray'),
          ],
        ),
        Row(
          children: [
            Radio<TrayMode>(
              value: TrayMode.noTray,
              groupValue: widget.selectedMode,
              onChanged: widget.onChanged,
            ),
            const Text('No tray'),
          ],
        ),
      ],
    );
  }
}

enum TrayMode {
  closeToTray,
  minimizeToTray,
  noTray,
}

class SettingsService {
  static const _trayModeKey = 'tray_mode';

  Future<TrayMode> getTrayMode() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_trayModeKey) ?? 0;
    return TrayMode.values[modeIndex];
  }

  Future<void> setTrayMode(TrayMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_trayModeKey, mode.index);
  }
}