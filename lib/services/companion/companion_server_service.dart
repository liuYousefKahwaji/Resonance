import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/models/playback_queue_snapshot.dart';
import 'package:resonance/services/companion/companion_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CompanionApprovedDevice {
  final String id;
  final String name;
  final String credential;
  final DateTime pairedAt;

  const CompanionApprovedDevice({
    required this.id,
    required this.name,
    required this.credential,
    required this.pairedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'credential': credential,
    'pairedAt': pairedAt.toIso8601String(),
  };

  static CompanionApprovedDevice? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final id = json['id'] as String? ?? '';
    final credential = json['credential'] as String? ?? '';
    if (id.isEmpty || credential.length < 24) return null;
    return CompanionApprovedDevice(
      id: id,
      name: json['name'] as String? ?? 'Android device',
      credential: credential,
      pairedAt: DateTime.tryParse(json['pairedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

class CompanionServerService extends ChangeNotifier {
  CompanionServerService._();

  static final CompanionServerService instance = CompanionServerService._();
  static const _enabledKey = 'companion_server_enabled';
  static const _devicesKey = 'companion_approved_devices_v1';
  static const int defaultPort = 45873;

  PlayerHandler? _handler;
  HttpServer? _server;
  StreamSubscription<MediaItem?>? _mediaSubscription;
  final Map<WebSocket, String> _authenticatedClients = {};
  final Map<String, CompanionApprovedDevice> _approvedDevices = {};
  final Map<String, PlaybackQueueEntry> _queueEntries = {};
  Timer? _broadcastDebounce;
  String? _pairingToken;
  DateTime? _pairingExpiresAt;
  bool _initialized = false;
  bool _enabled = false;
  String? _address;
  String? _error;

  bool get enabled => _enabled;
  bool get running => _server != null;
  String? get address => _address;
  int? get port => _server?.port;
  String? get error => _error;
  int get connectedClientCount => _authenticatedClients.length;
  List<CompanionApprovedDevice> get approvedDevices {
    final devices = _approvedDevices.values.toList(growable: false);
    devices.sort((a, b) => b.pairedAt.compareTo(a.pairedAt));
    return devices;
  }

  String? get pairingPayload {
    final token = _pairingToken;
    final expires = _pairingExpiresAt;
    final currentAddress = _address;
    final currentPort = _server?.port;
    if (token == null ||
        expires == null ||
        DateTime.now().isAfter(expires) ||
        currentAddress == null ||
        currentPort == null) {
      return null;
    }
    return CompanionPairingInfo(
      host: currentAddress,
      port: currentPort,
      pairingToken: token,
      pcName: Platform.localHostname,
    ).encode();
  }

  Future<void> initialize(PlayerHandler handler) async {
    _handler = handler;
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? false;
    final rawDevices = prefs.getString(_devicesKey);
    if (rawDevices != null) {
      try {
        final decoded = jsonDecode(rawDevices);
        if (decoded is List) {
          for (final value in decoded) {
            final device = CompanionApprovedDevice.fromJson(value);
            if (device != null) _approvedDevices[device.id] = device;
          }
        }
      } catch (_) {}
    }
    if (_enabled && Platform.isWindows) await start();
    notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    if (enabled) {
      await start();
    } else {
      await stop();
    }
    notifyListeners();
  }

  Future<void> preparePairing() async {
    if (!_initialized || _handler == null) return;
    if (!_enabled) await setEnabled(true);
    if (!running) await start();
    rotatePairingCode();
  }

  void rotatePairingCode() {
    if (!running) return;
    _pairingToken = _randomToken();
    _pairingExpiresAt = DateTime.now().add(const Duration(minutes: 5));
    notifyListeners();
  }

  Future<void> start() async {
    if (!Platform.isWindows || _server != null || _handler == null) return;
    _error = null;
    try {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, defaultPort);
      } on SocketException {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      }
      _address = await _preferredLanAddress();
      _server!.listen(
        _handleRequest,
        onError: (Object error) {
          _error = 'PC Companion server error: $error';
          notifyListeners();
        },
      );
      _attachPlayerListeners();
      rotatePairingCode();
    } catch (error) {
      _server = null;
      _error = 'Could not start PC Companion: $error';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    _broadcastDebounce?.cancel();
    _broadcastDebounce = null;
    await _mediaSubscription?.cancel();
    _mediaSubscription = null;
    _detachNotifierListeners();
    for (final socket in _authenticatedClients.keys.toList(growable: false)) {
      await socket.close(WebSocketStatus.goingAway, 'PC Companion disabled').catchError((_) {});
    }
    _authenticatedClients.clear();
    await _server?.close(force: true);
    _server = null;
    _address = null;
    _pairingToken = null;
    _pairingExpiresAt = null;
    notifyListeners();
  }

  Future<void> forgetDevice(String id) async {
    if (_approvedDevices.remove(id) == null) return;
    for (final entry in _authenticatedClients.entries.where((entry) => entry.value == id).toList()) {
      _authenticatedClients.remove(entry.key);
      await entry.key.close(WebSocketStatus.policyViolation, 'Device approval removed').catchError((_) {});
    }
    await _saveDevices();
    notifyListeners();
  }

  void _attachPlayerListeners() {
    final handler = _handler!;
    _mediaSubscription ??= handler.mediaItem.listen((_) => _scheduleBroadcast());
    // playbackState includes position ticks. The companion does not display a
    // seek position, so observing it would rebuild and re-read the whole queue
    // several times per second. The visual notifier covers play/pause/loading.
    handler.playbackVisualNotifier.addListener(_scheduleBroadcast);
    handler.playbackModeRevision.addListener(_scheduleBroadcast);
    handler.volumeNotifier.addListener(_scheduleBroadcast);
    handler.seekStepNotifier.addListener(_scheduleBroadcast);
    handler.speedNotifier.addListener(_scheduleBroadcast);
    handler.pitchNotifier.addListener(_scheduleBroadcast);
    handler.bassBoostNotifier.addListener(_scheduleBroadcast);
    handler.bassBoostSupportedNotifier.addListener(_scheduleBroadcast);
  }

  void _detachNotifierListeners() {
    final handler = _handler;
    if (handler == null) return;
    handler.playbackVisualNotifier.removeListener(_scheduleBroadcast);
    handler.playbackModeRevision.removeListener(_scheduleBroadcast);
    handler.volumeNotifier.removeListener(_scheduleBroadcast);
    handler.seekStepNotifier.removeListener(_scheduleBroadcast);
    handler.speedNotifier.removeListener(_scheduleBroadcast);
    handler.pitchNotifier.removeListener(_scheduleBroadcast);
    handler.bassBoostNotifier.removeListener(_scheduleBroadcast);
    handler.bassBoostSupportedNotifier.removeListener(_scheduleBroadcast);
  }

  void _handleRequest(HttpRequest request) async {
    if (request.uri.path != '/resonance' || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Resonance PC Companion')
        ..close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (data) {
          if (data is! String || data.length > 65536) {
            unawaited(socket.close(WebSocketStatus.invalidFramePayloadData, 'Invalid companion message'));
            return;
          }
          unawaited(_handleSocketMessage(socket, data));
        },
        onDone: () => _removeClient(socket),
        onError: (_) => _removeClient(socket),
        cancelOnError: true,
      );
    } catch (error) {
      debugPrint('[CompanionServer] WebSocket upgrade failed: $error');
    }
  }

  Future<void> _handleSocketMessage(WebSocket socket, String raw) async {
    Map<String, dynamic> message;
    try {
      message = decodeCompanionMessage(raw);
    } catch (_) {
      _send(socket, {'type': 'error', 'code': 'invalid_message', 'message': 'Invalid companion message.'});
      return;
    }
    if (!_authenticatedClients.containsKey(socket)) {
      await _authenticate(socket, message);
      return;
    }
    if (message['type'] != 'command') return;
    try {
      await _runCommand(message);
      _scheduleBroadcast(immediate: true);
    } catch (error) {
      _send(socket, {'type': 'error', 'code': 'command_failed', 'message': '$error'});
    }
  }

  Future<void> _authenticate(WebSocket socket, Map<String, dynamic> message) async {
    if (message['type'] != 'authenticate' || message['protocol'] != companionProtocolVersion) {
      await socket.close(WebSocketStatus.policyViolation, 'Authentication required');
      return;
    }
    final deviceId = (message['deviceId'] as String? ?? '').trim();
    final deviceName = (message['deviceName'] as String? ?? 'Android device').trim();
    final suppliedCredential = message['credential'] as String?;
    final suppliedPairingToken = message['pairingToken'] as String?;
    if (deviceId.isEmpty) {
      await socket.close(WebSocketStatus.policyViolation, 'Missing device ID');
      return;
    }

    var approved = _approvedDevices[deviceId];
    if (approved == null || approved.credential != suppliedCredential) {
      final tokenValid =
          suppliedPairingToken != null &&
          suppliedPairingToken == _pairingToken &&
          _pairingExpiresAt != null &&
          DateTime.now().isBefore(_pairingExpiresAt!);
      if (!tokenValid) {
        _send(socket, {'type': 'error', 'code': 'authentication_failed', 'message': 'Pairing approval expired.'});
        await socket.close(WebSocketStatus.policyViolation, 'Pairing approval expired');
        return;
      }
      approved = CompanionApprovedDevice(
        id: deviceId,
        name: deviceName.isEmpty ? 'Android device' : deviceName,
        credential: _randomToken(),
        pairedAt: DateTime.now(),
      );
      _approvedDevices[deviceId] = approved;
      await _saveDevices();
      _send(socket, {'type': 'paired', 'protocol': companionProtocolVersion, 'credential': approved.credential});
      rotatePairingCode();
    }
    _authenticatedClients[socket] = deviceId;
    notifyListeners();
    await _sendState(socket);
  }

  Future<void> _runCommand(Map<String, dynamic> message) async {
    final handler = _handler!;
    switch (message['command']) {
      case 'playPause':
        await handler.playPause();
      case 'next':
        await handler.next();
      case 'previous':
        await handler.previous();
      case 'setLoop':
        final name = message['value'] as String? ?? '';
        final mode = LoopMode.values.where((mode) => mode.name == name).firstOrNull;
        if (mode == null) throw const FormatException('Invalid loop mode');
        await handler.setLoopMode(mode);
      case 'setShuffle':
        await handler.setShuffleEnabled(message['value'] == true);
      case 'setVolume':
        await handler.changeVolume(_commandNumber(message).clamp(0, 2));
      case 'seekBackward':
        await handler.seekBySeconds(-handler.seekStepNotifier.value);
      case 'seekForward':
        await handler.seekBySeconds(handler.seekStepNotifier.value);
      case 'setSpeed':
        await handler.setSpeed(_commandNumber(message).clamp(0.5, 2));
      case 'setPitch':
        await handler.setPitch(_commandNumber(message).clamp(0.5, 2));
      case 'setBass':
        await handler.setBassBoost(_commandNumber(message).clamp(0, 1));
      case 'playTrack':
        final id = message['id'] as String? ?? '';
        final entry = _queueEntries[id];
        if (entry == null) throw const FormatException('That queue item is no longer available');
        await handler.playPlaybackQueueEntry(entry);
      default:
        throw const FormatException('Unknown companion command');
    }
  }

  double _commandNumber(Map<String, dynamic> message) {
    final value = message['value'];
    if (value is! num) throw const FormatException('The command needs a numeric value');
    return value.toDouble();
  }

  void _scheduleBroadcast({bool immediate = false}) {
    if (_authenticatedClients.isEmpty) return;
    _broadcastDebounce?.cancel();
    _broadcastDebounce = Timer(immediate ? Duration.zero : const Duration(milliseconds: 100), () async {
      final message = await _stateMessage();
      for (final socket in _authenticatedClients.keys.toList(growable: false)) {
        _send(socket, message);
      }
    });
  }

  Future<void> _sendState(WebSocket socket) async => _send(socket, await _stateMessage());

  Future<Map<String, dynamic>> _stateMessage() async {
    final handler = _handler!;
    final snapshot = await handler.playbackQueueSnapshot();
    final queue = <PlaybackQueueEntry>[if (snapshot.current case final current?) current, ...snapshot.upcoming];
    _queueEntries
      ..clear()
      ..addEntries(queue.map((entry) => MapEntry(_stableTrackId(entry.id), entry)));
    return {
      'type': 'state',
      'protocol': companionProtocolVersion,
      'pcName': Platform.localHostname,
      'playing': handler.playbackVisualNotifier.value.playing,
      'loading': handler.playbackVisualNotifier.value.loading,
      'loop': handler.getLoopMode().name,
      'shuffle': handler.getShuffleMode(),
      'volume': handler.volumeNotifier.value,
      'seekStepSeconds': handler.seekStepNotifier.value,
      'speed': handler.speedNotifier.value,
      'pitch': handler.pitchNotifier.value,
      'bass': handler.bassBoostNotifier.value,
      'bassSupported': handler.bassBoostSupportedNotifier.value,
      'queue': [
        for (var index = 0; index < queue.length; index++)
          {
            'id': _stableTrackId(queue[index].id),
            'title': queue[index].title,
            'artist': queue[index].artist,
            'current': index == 0 && snapshot.current != null,
          },
      ],
    };
  }

  void _send(WebSocket socket, Map<String, dynamic> message) {
    try {
      socket.add(jsonEncode(message));
    } catch (_) {
      _removeClient(socket);
    }
  }

  void _removeClient(WebSocket socket) {
    if (_authenticatedClients.remove(socket) != null) notifyListeners();
  }

  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_devicesKey, jsonEncode(_approvedDevices.values.map((device) => device.toJson()).toList()));
  }

  String _stableTrackId(String path) => sha256.convert(utf8.encode(path)).toString().substring(0, 24);

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  Future<String> _preferredLanAddress() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final candidates = <({String address, int score})>[];
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      for (final address in interface.addresses) {
        final value = address.address;
        if (value.startsWith('169.254.')) continue;
        var score = 0;
        if (name.contains('wi-fi') || name.contains('wifi') || name.contains('wlan')) score += 30;
        if (name.contains('ethernet')) score += 20;
        if (name.contains('virtual') || name.contains('vethernet') || name.contains('vmware')) score -= 30;
        if (value.startsWith('192.168.')) score += 15;
        if (value.startsWith('10.')) score += 10;
        candidates.add((address: value, score: score));
      }
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.isEmpty ? InternetAddress.loopbackIPv4.address : candidates.first.address;
  }
}
