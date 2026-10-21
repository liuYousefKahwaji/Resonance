import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class VoiceChatDevice {
  const VoiceChatDevice(this.id, this.name);
  final String id;
  final String name;
  bool get isVirtual => RegExp(r'cable|voicemeeter', caseSensitive: false).hasMatch(name);
  // mpv's WASAPI backend uses the Windows endpoint ID with a driver prefix.
  String get mpvName => 'wasapi/${id.substring(id.lastIndexOf('{').clamp(0, id.length))}';
}

@immutable
class VoiceChatFrame {
  const VoiceChatFrame({
    required this.media,
    required this.generation,
    required this.position,
    required this.playing,
    required this.rate,
    required this.pitch,
    required this.filter,
    required this.gain,
    this.listeningDevice = 'auto',
    this.seekRevision = 0,
  });
  final mk.Media media;
  final int generation;
  final Duration position;
  final bool playing;
  final double rate, pitch, gain;
  final String filter;
  final String listeningDevice;
  final int seekRevision;
  Duration get targetPosition {
    final start = media.start ?? Duration.zero;
    if (position < start) return start;
    final end = media.end;
    return end != null && position > end ? end : position;
  }

  String get sourceKey => '$generation:${media.uri}:${media.start}:${media.end}';
}

/// The private music decoder renders only to the chosen virtual cable. Windows
/// mixes that output with the native microphone route. No desktop loopback is
/// used: call audio and preview playback cannot leak into the transmitted mix.
/// The resolved Media (including HTTP headers and local cuts) comes from the
/// handler; this controller never selects tracks or resolves YouTube links.
class VoiceChatController extends ChangeNotifier {
  VoiceChatController({required this.frame, MethodChannel? channel, mk.Player Function()? createMusicPlayer})
    : _channel = channel ?? const MethodChannel('resonance/voice_chat'),
      _createMusicPlayer =
          createMusicPlayer ?? (() => mk.Player(configuration: const mk.PlayerConfiguration(pitch: true)));
  final VoiceChatFrame? Function() frame;
  final MethodChannel _channel;
  final mk.Player Function() _createMusicPlayer;
  List<VoiceChatDevice> microphones = [], outputs = [];
  String microphoneId = '', outputId = '', headphonesId = '';
  String _defaultOutputId = '';
  double musicLevel = 0.35, microphoneLevel = 1, microphonePeak = 0;
  bool enabled = false, busy = false, hearMyself = false, musicLoading = false;
  String? error;
  mk.Player? _music;
  Timer? _timer, _saveTimer, _levelTimer;
  StreamSubscription<String>? _errorSubscription;
  Future<void>? _initializing;
  int _epoch = 0;
  bool _syncing = false, _disposed = false;
  String? _sourceKey, _filter;
  int? _seekRevision;
  double? _writtenVolume;
  String? _failedMusicSource;
  int _musicRetries = 0;
  DateTime? _musicRetryAfter;

  VoiceChatDevice? get cable => outputs.where((d) => d.id == outputId && d.isVirtual).firstOrNull;
  bool get canRetryMusic => enabled && _failedMusicSource != null;
  void retryMusic() {
    if (!canRetryMusic) return;
    _failedMusicSource = null;
    _musicRetryAfter = null;
    _musicRetries = 0;
    _sourceKey = null;
    error = null;
    _publish();
    unawaited(_tick());
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    microphoneId = prefs.getString('voice_chat_microphone') ?? '';
    outputId = prefs.getString('voice_chat_output') ?? '';
    headphonesId = prefs.getString('voice_chat_headphones') ?? '';
    musicLevel = (prefs.getDouble('voice_chat_music') ?? 0.35).clamp(0, 1);
    microphoneLevel = (prefs.getDouble('voice_chat_mic') ?? 1).clamp(0, 2);
    // Deliberately never persist activation or mic monitoring.
    await refreshDevices();
  }

  Future<void> refreshDevices() async {
    final restart = enabled;
    if (restart) await setEnabled(false);
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>('devices');
      List<VoiceChatDevice> read(String key) => (data?[key] as List? ?? []).map((raw) {
        final map = raw as Map;
        return VoiceChatDevice(map['id'] as String, map['name'] as String);
      }).toList();
      microphones = read('microphones').where((d) => !d.isVirtual).toList();
      outputs = read('outputs');
      _defaultOutputId = data?['defaultOutput'] as String? ?? '';
      final defaultMicrophone = data?['defaultMicrophone'] as String?;
      if (!microphones.any((d) => d.id == microphoneId)) {
        microphoneId =
            microphones.where((d) => d.id == defaultMicrophone).firstOrNull?.id ?? microphones.firstOrNull?.id ?? '';
      }
      if (!outputs.any((d) => d.id == outputId && d.isVirtual)) {
        outputId = outputs.where((d) => d.isVirtual).firstOrNull?.id ?? '';
      }
      if (!outputs.any((d) => d.id == headphonesId && !d.isVirtual)) headphonesId = '';
      if (headphonesId.isEmpty && _defaultOutputId == outputId) {
        headphonesId = outputs.where((d) => !d.isVirtual).firstOrNull?.id ?? '';
      }
      error = null;
    } catch (e) {
      error = 'Could not read Windows audio devices: $e';
    }
    _publish();
    if (restart && cable != null && microphones.isNotEmpty && !_disposed) await setEnabled(true);
  }

  void setLevels({double? music, double? microphone, bool? monitor}) {
    if (music != null) musicLevel = music.clamp(0, 1);
    if (microphone != null) microphoneLevel = microphone.clamp(0, 2);
    if (monitor != null) hearMyself = monitor;
    _levelTimer?.cancel();
    _levelTimer = Timer(const Duration(milliseconds: 40), () async {
      if (!enabled) return;
      try {
        await _channel.invokeMethod<void>('levels', {'gain': microphoneLevel, 'monitor': hearMyself});
      } catch (e) {
        await _fail('Microphone routing stopped: $e');
      }
    });
    _save();
    _publish();
  }

  Future<void> selectDevices({String? microphone, String? output, String? headphones}) async {
    final resume = enabled;
    await setEnabled(false);
    if (microphone != null) microphoneId = microphone;
    if (output != null) outputId = output;
    if (headphones != null) headphonesId = headphones;
    _save();
    _publish();
    if (resume) await setEnabled(true);
  }

  void _save() {
    _saveTimer?.cancel();
    final mic = microphoneId, output = outputId, headphones = headphonesId;
    final music = musicLevel, gain = microphoneLevel;
    _saveTimer = Timer(const Duration(milliseconds: 250), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('voice_chat_microphone', mic);
      await prefs.setString('voice_chat_output', output);
      await prefs.setString('voice_chat_headphones', headphones);
      await prefs.setDouble('voice_chat_music', music);
      await prefs.setDouble('voice_chat_mic', gain);
    });
  }

  Future<void> setEnabled(bool value) async {
    if (busy) return;
    busy = true;
    error = null;
    _publish();
    final epoch = ++_epoch;
    try {
      enabled = false;
      _timer?.cancel();
      await _errorSubscription?.cancel();
      _errorSubscription = null;
      final old = _music;
      _music = null;
      await old?.dispose();
      await _channel.invokeMethod<void>('stop');
      _sourceKey = null;
      _filter = null;
      _seekRevision = null;
      _writtenVolume = null;
      _failedMusicSource = null;
      _musicRetries = 0;
      _musicRetryAfter = null;
      musicLoading = false;
      microphonePeak = 0;
      if (!value || _disposed) return;
      await initialize();
      final target = cable;
      if (target == null) throw StateError('Install a virtual cable, then refresh devices.');
      if (microphones.isEmpty) throw StateError('Connect a microphone first.');
      _checkListeningRoute(frame(), target);
      await _channel.invokeMethod<void>('start', {
        'microphone': microphoneId,
        'output': outputId,
        'headphones': headphonesId,
        'gain': microphoneLevel,
        'monitor': hearMyself,
      });
      // Native initialization runs on its WASAPI worker, never the UI thread.
      var ready = false;
      for (var i = 0; i < 100 && !_disposed && epoch == _epoch; i++) {
        final status = await _channel.invokeMapMethod<String, dynamic>('status');
        final problem = status?['error'] as String? ?? '';
        if (problem.isNotEmpty) throw StateError(problem);
        if (status?['running'] == true) {
          ready = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!ready || _disposed || epoch != _epoch) throw StateError('Microphone routing did not start.');
      final player = _createMusicPlayer();
      _music = player;
      // Setting the route before opening a source prevents even a brief burst
      // through the system speakers. Native error means fail closed.
      final native = player.platform;
      if (native is! mk.NativePlayer) throw StateError('Native Windows playback is unavailable.');
      await native.setProperty('ao', 'wasapi');
      await native.setProperty('audio-fallback-to-null', 'no');
      await native.setProperty('audio-device', target.mpvName);
      _errorSubscription = player.stream.error.listen((message) {
        if (enabled && epoch == _epoch) unawaited(_musicFailed('Voice chat music stopped: $message'));
      });
      enabled = true;
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => unawaited(_tick()));
      unawaited(_tick());
    } catch (e) {
      enabled = false;
      error = '$e';
      _timer?.cancel();
      final player = _music;
      _music = null;
      await player?.dispose();
      await _channel.invokeMethod<void>('stop').catchError((Object _) {});
    } finally {
      busy = false;
      _publish();
    }
  }

  Future<void> _fail(String message) async {
    if (!enabled || _disposed) return;
    await setEnabled(false);
    error = message;
    _publish();
  }

  void _checkListeningRoute(VoiceChatFrame? snapshot, VoiceChatDevice target) {
    if (snapshot != null &&
        (snapshot.listeningDevice == target.mpvName ||
            snapshot.listeningDevice == 'auto' && _defaultOutputId == target.id)) {
      throw StateError('Choose headphones as Resonance’s output device before sharing.');
    }
    if (headphonesId == target.id || headphonesId.isEmpty && _defaultOutputId == target.id) {
      throw StateError('Choose headphones for microphone monitoring.');
    }
  }

  /// Invalidate immediately, before the handler awaits a new stream source.
  void suspendMusic() {
    _sourceKey = null;
    final player = _music;
    if (player != null) unawaited(player.pause().catchError((Object _) {}));
  }

  Future<void> _musicFailed(String message) async {
    if (!enabled || _disposed) return;
    final key = frame()?.sourceKey;
    if (_failedMusicSource != key) _musicRetries = 0;
    _failedMusicSource = key;
    _sourceKey = null;
    _musicRetryAfter = DateTime.now().add(Duration(seconds: 1 << _musicRetries.clamp(0, 2)));
    _musicRetries++;
    error = message;
    musicLoading = false;
    await _music?.pause().catchError((Object _) {});
    _publish();
  }

  Future<void> _tick() async {
    if (_syncing || !enabled || _disposed) return;
    _syncing = true;
    final epoch = _epoch, player = _music!;
    try {
      Map<String, dynamic>? status;
      try {
        status = await _channel.invokeMapMethod<String, dynamic>('status');
      } catch (e) {
        await _fail('Microphone routing stopped: $e');
        return;
      }
      if (!enabled || epoch != _epoch) return;
      final problem = status?['error'] as String? ?? '';
      if (status?['running'] != true) {
        await _fail(problem.isEmpty ? 'Microphone disconnected.' : problem);
        return;
      }
      microphonePeak = ((status?['peak'] as num?)?.toDouble() ?? 0).clamp(0, 1);
      final monitorError = status?['monitorError'] as String? ?? '';
      if (monitorError.isNotEmpty) {
        hearMyself = false;
        error = monitorError;
      }
      final snapshot = frame();
      if (snapshot == null) {
        if (player.state.playing) await player.pause();
        musicLoading = false;
        _publish();
        return;
      }
      if (_sourceKey == snapshot.sourceKey &&
          _failedMusicSource == snapshot.sourceKey &&
          player.state.playing &&
          !player.state.buffering) {
        _failedMusicSource = null;
        _musicRetryAfter = null;
        _musicRetries = 0;
      }
      _checkListeningRoute(snapshot, cable!);
      var positioned = false;
      if (_failedMusicSource == snapshot.sourceKey &&
          (_musicRetries > 3 || DateTime.now().isBefore(_musicRetryAfter!))) {
        _publish();
        return;
      }
      if (_failedMusicSource != snapshot.sourceKey) {
        _musicRetries = 0;
        _failedMusicSource = null;
        _musicRetryAfter = null;
      }
      if (_sourceKey != snapshot.sourceKey) {
        musicLoading = true;
        _publish();
        await player.pause();
        await player.setVolume(0);
        final native = player.platform as mk.NativePlayer;
        await native.setProperty('start', '${(snapshot.media.start ?? Duration.zero).inMicroseconds / 1000000}');
        await native.setProperty(
          'end',
          snapshot.media.end == null ? 'none' : '${snapshot.media.end!.inMicroseconds / 1000000}',
        );
        await player.open(snapshot.media, play: false).timeout(const Duration(seconds: 10));
        if (!enabled || epoch != _epoch || frame()?.sourceKey != snapshot.sourceKey) {
          if (enabled && epoch == _epoch) await player.pause();
          return;
        }
        _sourceKey = snapshot.sourceKey;
        // Opening a stream can take time; seek to the current music position.
        final fresh = frame()!;
        final sourceStart = fresh.media.start ?? Duration.zero;
        if (fresh.targetPosition - sourceStart > const Duration(seconds: 1) ||
            fresh.seekRevision != snapshot.seekRevision) {
          await player.seek(fresh.targetPosition);
        }
        _seekRevision = fresh.seekRevision;
        positioned = true;
        _writtenVolume = null;
      }
      final current = frame();
      if (current == null || current.sourceKey != _sourceKey || !enabled || epoch != _epoch) {
        if (enabled && epoch == _epoch) await player.pause();
        return;
      }
      if (player.state.rate != current.rate) await player.setRate(current.rate);
      if (player.state.pitch != current.pitch) await player.setPitch(current.pitch);
      if (_filter != current.filter) {
        await (player.platform as mk.NativePlayer).setProperty('af', current.filter);
        _filter = current.filter;
      }
      final volume = musicLevel * current.gain * 100;
      if (_writtenVolume != volume) {
        await player.setVolume(volume);
        _writtenVolume = volume;
      }
      // Separate WASAPI endpoints have different latency and clock positions.
      // Repeatedly seeking that latency away makes streams rebuffer forever.
      // Only an actual handler seek/repeat command can reposition this decoder.
      if (_seekRevision != current.seekRevision) {
        await player.seek(current.targetPosition);
        _seekRevision = current.seekRevision;
        positioned = true;
      }
      final latest = frame();
      if (!enabled || epoch != _epoch) return;
      if (latest == null || latest.sourceKey != _sourceKey) {
        await player.pause();
        return;
      }
      final shouldPlay = latest.playing && (!player.state.completed || positioned);
      if (player.state.playing != shouldPlay) {
        if (shouldPlay) {
          await player.play();
        } else {
          await player.pause();
        }
      }
      if (enabled && epoch == _epoch && frame()?.sourceKey != _sourceKey) await player.pause();
      musicLoading = player.state.buffering;
      if (!musicLoading && player.state.playing && _failedMusicSource == null && monitorError.isEmpty) error = null;
      _publish();
    } catch (e) {
      if (enabled && epoch == _epoch) await _musicFailed('$e');
    } finally {
      _syncing = false;
    }
  }

  Future<void> shutdown() async {
    _disposed = true;
    ++_epoch;
    enabled = false;
    _timer?.cancel();
    _saveTimer?.cancel();
    _levelTimer?.cancel();
    await _errorSubscription?.cancel();
    final player = _music;
    _music = null;
    await _channel.invokeMethod<void>('stop').catchError((Object _) {});
    await player?.dispose();
    super.dispose();
  }
}
