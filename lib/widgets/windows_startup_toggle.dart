import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/platform/desktop/windows_startup.dart';

class WindowsStartupToggle extends StatefulWidget {
  const WindowsStartupToggle({super.key, this.startup = const WindowsStartup()});
  final WindowsStartup startup;
  @override
  State<WindowsStartupToggle> createState() => _WindowsStartupToggleState();
}

class _WindowsStartupToggleState extends State<WindowsStartupToggle> {
  bool _enabled = false, _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await widget.startup.read();
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      _error = 'Could not read the Windows startup setting.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _change(bool value) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final enabled = await widget.startup.setEnabled(value);
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not change the Windows startup setting.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    secondary: const Icon(Icons.power_settings_new_rounded),
    title: Text(context.tr('Launch on startup')),
    subtitle: Text(context.tr(_error ?? 'Open Resonance when you sign in to Windows, even with tray mode enabled.')),
    value: _enabled,
    onChanged: _busy ? null : _change,
  );
}
