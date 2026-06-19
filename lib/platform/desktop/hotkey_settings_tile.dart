// lib/platform/desktop/hotkey_settings_tile.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:resonance/platform/desktop/hotkey_service.dart';

class HotkeySettingsTile extends StatefulWidget {
  final String actionId;
  final String actionName;
  final Function callback;
  const HotkeySettingsTile({required this.actionId, required this.actionName, required this.callback, super.key});

  @override
  State<HotkeySettingsTile> createState() => _HotkeySettingsTileState();
}

class _HotkeySettingsTileState extends State<HotkeySettingsTile> {
  HotKey? _currentHotkey;

  @override
  void initState() {
    super.initState();
    _loadCurrentHotkey();
  }

  Future<void> _loadCurrentHotkey() async {
    final saved = await HotkeyService.getSavedHotkey(widget.actionId);
    if (mounted) setState(() => _currentHotkey = saved);
  }

  Future<void> _startRecording() async {
    final recorded = await showDialog<HotKey>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => const _HotkeyRecorderDialog(),
    );

    if (recorded != null) {
      await HotkeyService.register(widget.actionId, recorded, widget.callback);
      setState(() => _currentHotkey = recorded);
    }
  }

  String _formatHotKey(HotKey hk) {
    final mods = <String>[];
    if (hk.modifiers != null) {
      if (hk.modifiers!.contains(HotKeyModifier.control)) mods.add('Ctrl');
      if (hk.modifiers!.contains(HotKeyModifier.alt)) mods.add('Alt');
      if (hk.modifiers!.contains(HotKeyModifier.shift)) mods.add('Shift');
      if (hk.modifiers!.contains(HotKeyModifier.meta)) mods.add('Win');
    }
    final key = hk.key.keyLabel;
    return mods.isEmpty ? key : '${mods.join('+')}+$key';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(widget.actionName),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_currentHotkey != null) Text(_formatHotKey(_currentHotkey!)),
          if (_currentHotkey != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 18),
              onPressed: () async {
                await HotkeyService.unregister(widget.actionId);
                setState(() => _currentHotkey = null);
              },
            ),
          const SizedBox(width: 8),
          ElevatedButton(onPressed: _startRecording, child: const Text('Record')),
        ],
      ),
    );
  }
}

// Dialog that captures a single hotkey using RawKeyboardListener
class _HotkeyRecorderDialog extends StatefulWidget {
  const _HotkeyRecorderDialog();

  @override
  State<_HotkeyRecorderDialog> createState() => _HotkeyRecorderDialogState();
}

class _HotkeyRecorderDialogState extends State<_HotkeyRecorderDialog> {
  HotKey? _recorded;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final logicalKey = event.logicalKey;

      // Ignore modifier-only keys
      final isModifier = [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.controlRight,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.altRight,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.shiftRight,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.metaRight,
        LogicalKeyboardKey.control,
        LogicalKeyboardKey.alt,
        LogicalKeyboardKey.shift,
        LogicalKeyboardKey.meta,
      ].contains(logicalKey);
      if (isModifier) return KeyEventResult.ignored;

      // Detect modifiers
      final modifiers = <HotKeyModifier>[];
      if (HardwareKeyboard.instance.isControlPressed) modifiers.add(HotKeyModifier.control);
      if (HardwareKeyboard.instance.isAltPressed) modifiers.add(HotKeyModifier.alt);
      if (HardwareKeyboard.instance.isShiftPressed) modifiers.add(HotKeyModifier.shift);
      if (HardwareKeyboard.instance.isMetaPressed) modifiers.add(HotKeyModifier.meta);

      final hotKey = HotKey(key: logicalKey, modifiers: modifiers.isNotEmpty ? modifiers : null);

      setState(() {
        _recorded = hotKey;
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _formatHotKey(HotKey hk) {
    final mods = <String>[];
    if (hk.modifiers != null) {
      if (hk.modifiers!.contains(HotKeyModifier.control)) mods.add('Ctrl');
      if (hk.modifiers!.contains(HotKeyModifier.alt)) mods.add('Alt');
      if (hk.modifiers!.contains(HotKeyModifier.shift)) mods.add('Shift');
      if (hk.modifiers!.contains(HotKeyModifier.meta)) mods.add('Win');
    }
    final key = hk.key.keyLabel;
    return mods.isEmpty ? key : '${mods.join('+')}+$key';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record Shortcut'),
      content: SizedBox(
        width: 300,
        height: 120,
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleKey,
          child: Container(
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Press the desired key combination...'),
                const Text(
                  '(Must include Ctrl, Alt, Shift, or Win)',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                if (_recorded != null)
                  Text('Recorded: ${_formatHotKey(_recorded!)}', style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
        TextButton(
          onPressed: (_recorded != null && _recorded!.modifiers != null && _recorded!.modifiers!.isNotEmpty)
              ? () => Navigator.pop(context, _recorded)
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
