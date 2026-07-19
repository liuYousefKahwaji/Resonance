import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:resonance/services/companion/discord_keybind_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Discord shortcuts default to the standard mute and deafen combinations', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = DiscordKeybindService(preferences: prefs);

    final mute = await service.get(DiscordKeybindAction.toggleMute);
    final deafen = await service.get(DiscordKeybindAction.toggleDeafen);

    expect(mute.logicalKey, LogicalKeyboardKey.keyM);
    expect(deafen.logicalKey, LogicalKeyboardKey.keyD);
    expect(mute.modifiers, containsAll([HotKeyModifier.control, HotKeyModifier.shift]));
    expect(deafen.modifiers, containsAll([HotKeyModifier.control, HotKeyModifier.shift]));
  });

  test('recorded shortcuts persist and reset without global registration', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = DiscordKeybindService(preferences: prefs);
    final recorded = HotKey(key: LogicalKeyboardKey.f8, modifiers: const [HotKeyModifier.alt]);

    await service.set(DiscordKeybindAction.toggleMute, recorded);
    expect((await service.get(DiscordKeybindAction.toggleMute)).logicalKey, LogicalKeyboardKey.f8);

    await service.resetDefaults();
    expect((await service.get(DiscordKeybindAction.toggleMute)).logicalKey, LogicalKeyboardKey.keyM);
  });

  test('trigger resolves the saved key and delegates to the outbound sender', () async {
    final prefs = await SharedPreferences.getInstance();
    HotKey? sent;
    final service = DiscordKeybindService(
      preferences: prefs,
      sender: (hotKey) async {
        sent = hotKey;
        return true;
      },
    );

    expect(await service.trigger(DiscordKeybindAction.toggleDeafen), isTrue);
    expect(sent?.logicalKey, LogicalKeyboardKey.keyD);
  });

  test('native dispatch includes the Windows virtual key and USB HID usage', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('resonance/media_keys');
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = DiscordKeybindService(preferences: await SharedPreferences.getInstance());
    expect(await service.trigger(DiscordKeybindAction.toggleMute), isTrue);
    expect(received?.method, 'sendShortcut');
    final arguments = Map<String, dynamic>.from(received!.arguments as Map);
    expect(arguments['keyCode'], 0x4D);
    expect(arguments['hidUsage'], PhysicalKeyboardKey.keyM.usbHidUsage);
    expect(arguments['modifiers'], ['control', 'shift']);
  });
}
