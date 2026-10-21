import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:resonance/core/audio/voice_chat_controller.dart';
import 'package:resonance/widgets/player/voice_chat_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('resonance/voice_chat');
  final calls = <String>[];
  var deviceData = <String, dynamic>{};
  setUp(() {
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    deviceData = {
      'microphones': [
        {'id': 'mic', 'name': 'Headset microphone'},
        {'id': 'feedback', 'name': 'CABLE Output (VB-Audio Virtual Cable)'},
      ],
      'outputs': [
        {'id': '{0.0.0.00000000}.{abc}', 'name': 'CABLE Input (VB-Audio Virtual Cable)'},
        {'id': 'speakers', 'name': 'Headphones'},
      ],
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'devices') return deviceData;
      if (call.method == 'status') return {'running': false, 'error': 'Microphone access denied'};
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('setup remembers physical mic/cable/levels without starting capture or monitoring', () async {
    SharedPreferences.setMockInitialValues({'voice_chat_music': 0.8, 'voice_chat_mic': 1.4});
    final controller = VoiceChatController(frame: () => null);
    await controller.initialize();
    expect(controller.enabled, isFalse);
    expect(controller.hearMyself, isFalse);
    expect(controller.microphones.single.id, 'mic', reason: 'Virtual inputs must not feed the mix back into itself');
    expect(controller.cable!.mpvName, 'wasapi/{abc}');
    expect(controller.musicLevel, 0.8);
    expect(controller.microphoneLevel, 1.4);
    expect(calls, ['devices']);
    await controller.shutdown();
  });

  test('missing cable never opens the microphone; failed mic stops the whole route', () async {
    final controller = VoiceChatController(frame: () => null);
    deviceData['outputs'] = [
      {'id': 'speakers', 'name': 'Headphones'},
    ];
    await controller.setEnabled(true);
    expect(controller.enabled, isFalse);
    expect(controller.error, contains('Install a virtual cable'));
    expect(calls, isNot(contains('start')));
    deviceData['outputs'] = [
      {'id': 'cable', 'name': 'CABLE Input'},
    ];
    await controller.refreshDevices();
    await controller.setEnabled(true);
    expect(controller.enabled, isFalse);
    expect(controller.error, contains('Microphone access denied'));
    expect(calls.last, 'stop');
    await controller.shutdown();
  });

  test('broadcast seeks cannot leave a saved local cut, even during native startup', () {
    final frame = VoiceChatFrame(
      media: mk.Media('cut.wav', start: const Duration(seconds: 10), end: const Duration(seconds: 20)),
      generation: 1,
      position: Duration.zero,
      playing: false,
      rate: 1,
      pitch: 1,
      filter: '',
      gain: 1,
    );
    expect(frame.targetPosition, const Duration(seconds: 10));
  });

  testWidgets('microphone button opens compact setup and keeps sharing off on failure', (tester) async {
    final controller = VoiceChatController(frame: () => null);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VoiceChatButton(controller: controller)),
      ),
    );
    await tester.tap(find.byIcon(Icons.mic_none_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Music sent to chat'), findsOneWidget);
    expect(find.text('Hear myself'), findsOneWidget);
    expect(find.text('Audio devices'), findsOneWidget);
    expect(find.text('The usual volume bar only changes what you hear.'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Microphone access denied'), findsOneWidget);
    expect(controller.enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
    await controller.shutdown();
  });

  Future<void> waitFor(bool Function() ready) async {
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (!ready()) {
      if (DateTime.now().isAfter(end)) fail('Voice chat transport timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  bool micRunning = false;
  void workingMicrophone() {
    micRunning = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'devices') return deviceData;
      if (call.method == 'start') micRunning = true;
      if (call.method == 'stop') micRunning = false;
      if (call.method == 'status') return {'running': micRunning, 'peak': 0.0, 'error': ''};
      return null;
    });
  }

  VoiceChatFrame snapshot(
    String uri, {
    int generation = 1,
    int seekRevision = 0,
    int seconds = 0,
    bool playing = true,
  }) => VoiceChatFrame(
    media: mk.Media(uri),
    generation: generation,
    position: Duration(seconds: seconds),
    playing: playing,
    rate: 1,
    pitch: 1,
    filter: 'scaletempo',
    gain: 1,
    seekRevision: seekRevision,
  );

  test('endpoint latency cannot trigger seek/reload loops; actual seeks and pause still apply', () async {
    workingMicrophone();
    final player = _VoicePlayer();
    var current = snapshot('https://audio.test/song', seconds: 2);
    final c = VoiceChatController(frame: () => current, createMusicPlayer: () => player);
    addTearDown(c.shutdown);
    await c.setEnabled(true);
    await waitFor(() => player.state.playing);
    final seekCount = player.seeks.length, writes = player.volumeWrites;
    current = snapshot('https://audio.test/song', seconds: 20);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(player.seeks.length, seekCount, reason: 'Different endpoint latency is not a user seek');
    expect(player.opens.length, 1);
    expect(player.volumeWrites, writes, reason: 'Unchanged gain must not flood the native player');
    current = snapshot('https://audio.test/song', seconds: 30, seekRevision: 1);
    await waitFor(() => player.seeks.length == seekCount + 1);
    expect(player.seeks.last, const Duration(seconds: 30));
    current = snapshot('https://audio.test/song', seconds: 30, seekRevision: 1, playing: false);
    await waitFor(() => !player.state.playing);
    expect(micRunning, true);
    current = snapshot('https://audio.test/song', seconds: 30, seekRevision: 1);
    await waitFor(() => player.state.playing);
  });

  test('music failure leaves microphone active and can retry without rebuilding the mic route', () async {
    workingMicrophone();
    final player = _VoicePlayer();
    final current = snapshot('https://audio.test/song');
    final c = VoiceChatController(frame: () => current, createMusicPlayer: () => player);
    addTearDown(c.shutdown);
    await c.setEnabled(true);
    await waitFor(() => player.state.playing);
    player.errors.add('Network stream interrupted');
    await waitFor(() => c.canRetryMusic);
    expect(c.enabled, true);
    expect(micRunning, true);
    expect(calls.where((call) => call == 'stop').length, 1);
    c.retryMusic();
    await waitFor(() => player.opens.length == 2 && player.state.playing);
    expect(calls.where((call) => call == 'start').length, 1);
  });

  test('a superseded open cannot play old audio, and completed music cannot restart itself', () async {
    workingMicrophone();
    final gate = Completer<void>();
    final player = _VoicePlayer()..openGate = gate;
    var current = snapshot('https://audio.test/old');
    final c = VoiceChatController(frame: () => current, createMusicPlayer: () => player);
    addTearDown(c.shutdown);
    await c.setEnabled(true);
    await waitFor(() => player.opens.isNotEmpty);
    current = snapshot('https://audio.test/new', generation: 2);
    c.suspendMusic();
    gate.complete();
    await waitFor(() => player.played.isNotEmpty);
    expect(player.played, ['https://audio.test/new']);
    player.state = player.state.copyWith(completed: true, playing: false);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(player.played.length, 1, reason: 'Only a real queue repeat command may restart completed music');
    current = snapshot('https://audio.test/new', generation: 2, seekRevision: 1);
    await waitFor(() => player.played.length == 2);
  });
}

class _VoiceNative extends Fake implements mk.NativePlayer {
  @override
  Future<void> setProperty(String property, String value, {bool waitForInitialization = true}) async {}
}

class _VoiceStream extends Fake implements mk.PlayerStream {
  _VoiceStream(this.errors);
  final Stream<String> errors;
  @override
  Stream<String> get error => errors;
}

class _VoicePlayer extends Fake implements mk.Player {
  final errors = StreamController<String>.broadcast();
  final opens = <String>[], played = <String>[];
  final seeks = <Duration>[];
  int volumeWrites = 0;
  Completer<void>? openGate;
  @override
  mk.PlayerState state = const mk.PlayerState();
  @override
  mk.PlatformPlayer get platform => _VoiceNative();
  @override
  mk.PlayerStream get stream => _VoiceStream(errors.stream);
  @override
  Future<void> open(mk.Playable playable, {bool play = true}) async {
    final media = playable as mk.Media;
    opens.add(media.uri);
    final gate = openGate;
    openGate = null;
    await gate?.future;
    state = state.copyWith(playlist: mk.Playlist([media]), playing: play, completed: false, position: Duration.zero);
  }

  @override
  Future<void> setVolume(double value) async {
    volumeWrites++;
    state = state.copyWith(volume: value);
  }

  @override
  Future<void> setRate(double value) async => state = state.copyWith(rate: value);
  @override
  Future<void> setPitch(double value) async => state = state.copyWith(pitch: value);
  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    state = state.copyWith(position: value, completed: false);
  }

  @override
  Future<void> pause() async => state = state.copyWith(playing: false);
  @override
  Future<void> play() async {
    played.add(state.playlist.medias.first.uri);
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> dispose() async => errors.close();
}
