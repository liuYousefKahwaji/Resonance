import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:resonance/services/companion/companion_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CompanionConnectionStatus { unpaired, connecting, connected, disconnected, error }

class CompanionClientService extends ChangeNotifier {
  CompanionClientService._();

  static final CompanionClientService instance = CompanionClientService._();
  static const _connectionKey = 'companion_client_connection_v1';
  static const _deviceIdKey = 'companion_client_device_id_v1';

  WebSocket? _socket;
  Timer? _reconnectTimer;
  bool _initialized = false;
  int _connectionGeneration = 0;
  int _reconnectAttempt = 0;
  String? _host;
  int? _port;
  String? _credential;
  String? _pairingToken;
  String? _deviceId;
  String _pcName = 'Resonance PC';
  String? _error;
  CompanionConnectionStatus _status = CompanionConnectionStatus.unpaired;
  CompanionPlaybackSnapshot _snapshot = const CompanionPlaybackSnapshot();

  CompanionConnectionStatus get status => _status;
  CompanionPlaybackSnapshot get snapshot => _snapshot;
  String get pcName => _snapshot.pcName == 'Resonance PC' ? _pcName : _snapshot.pcName;
  String? get error => _error;
  bool get hasSavedPairing => _host != null && _port != null && _credential != null;
  bool get connected => _status == CompanionConnectionStatus.connected;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString(_deviceIdKey);
    if (_deviceId == null) {
      _deviceId = _randomId();
      await prefs.setString(_deviceIdKey, _deviceId!);
    }
    final raw = prefs.getString(_connectionKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          _host = json['host'] as String?;
          _port = json['port'] as int?;
          _credential = json['credential'] as String?;
          _pcName = json['pcName'] as String? ?? _pcName;
        }
      } catch (_) {}
    }
    if (hasSavedPairing && Platform.isAndroid) {
      unawaited(_connect());
    } else {
      _status = CompanionConnectionStatus.unpaired;
      notifyListeners();
    }
  }

  Future<void> pairFromPayload(String payload) async {
    await initialize();
    final info = CompanionPairingInfo.parse(payload);
    _host = info.host;
    _port = info.port;
    _pcName = info.pcName;
    _pairingToken = info.pairingToken;
    _credential = null;
    _snapshot = CompanionPlaybackSnapshot(pcName: info.pcName);
    await _connect();
  }

  Future<void> reconnectNow() async {
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    await _connect();
  }

  Future<void> forgetPairing() async {
    _connectionGeneration++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final socket = _socket;
    _socket = null;
    await socket?.close(WebSocketStatus.normalClosure, 'Pairing removed').catchError((_) {});
    _host = null;
    _port = null;
    _credential = null;
    _pairingToken = null;
    _pcName = 'Resonance PC';
    _snapshot = const CompanionPlaybackSnapshot();
    _status = CompanionConnectionStatus.unpaired;
    _error = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_connectionKey);
    notifyListeners();
  }

  void sendCommand(String command, {Object? value, String? id}) {
    final socket = _socket;
    if (socket == null || _status != CompanionConnectionStatus.connected) return;
    socket.add(
      jsonEncode({'type': 'command', 'command': command, if (value != null) 'value': value, if (id != null) 'id': id}),
    );
  }

  Future<void> _connect() async {
    final host = _host;
    final port = _port;
    if (host == null || port == null) return;
    final generation = ++_connectionGeneration;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final previous = _socket;
    _socket = null;
    await previous?.close().catchError((_) {});
    _status = CompanionConnectionStatus.connecting;
    _error = null;
    notifyListeners();
    try {
      final socket = await WebSocket.connect('ws://$host:$port/resonance').timeout(const Duration(seconds: 7));
      if (generation != _connectionGeneration) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.listen(
        (data) {
          if (data is String) unawaited(_handleMessage(generation, data));
        },
        onDone: () => _handleDisconnect(generation),
        onError: (Object error) => _handleDisconnect(generation, error: error),
        cancelOnError: true,
      );
      socket.add(
        jsonEncode({
          'type': 'authenticate',
          'protocol': companionProtocolVersion,
          'deviceId': _deviceId,
          'deviceName': Platform.localHostname,
          if (_credential != null) 'credential': _credential,
          if (_pairingToken != null) 'pairingToken': _pairingToken,
        }),
      );
    } catch (error) {
      if (generation != _connectionGeneration) return;
      _status = CompanionConnectionStatus.disconnected;
      _error = 'Could not reach $_pcName: $error';
      notifyListeners();
      _scheduleReconnect();
    }
  }

  Future<void> _handleMessage(int generation, String raw) async {
    if (generation != _connectionGeneration) return;
    try {
      final message = decodeCompanionMessage(raw);
      switch (message['type']) {
        case 'paired':
          final credential = message['credential'] as String?;
          if (credential == null || credential.length < 24) {
            throw const FormatException('The PC returned an invalid credential');
          }
          _credential = credential;
          _pairingToken = null;
          await _saveConnection();
        case 'state':
          _snapshot = CompanionPlaybackSnapshot.fromJson(message);
          _pcName = _snapshot.pcName;
          _status = CompanionConnectionStatus.connected;
          _error = null;
          _reconnectAttempt = 0;
          await _saveConnection();
          notifyListeners();
        case 'error':
          final code = message['code'] as String?;
          _error = message['message'] as String? ?? 'PC Companion error';
          if (code == 'authentication_failed') {
            _credential = null;
            _pairingToken = null;
            _status = CompanionConnectionStatus.error;
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(_connectionKey);
          }
          notifyListeners();
      }
    } catch (error) {
      _error = 'Invalid response from $_pcName: $error';
      notifyListeners();
    }
  }

  void _handleDisconnect(int generation, {Object? error}) {
    if (generation != _connectionGeneration) return;
    _socket = null;
    if (_status == CompanionConnectionStatus.error || _status == CompanionConnectionStatus.unpaired) return;
    _status = CompanionConnectionStatus.disconnected;
    _error = error == null ? 'Connection to $_pcName was lost.' : 'Connection to $_pcName was lost: $error';
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!hasSavedPairing || _reconnectTimer != null) return;
    final seconds = min(30, 2 << min(_reconnectAttempt, 4));
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      unawaited(_connect());
    });
  }

  Future<void> _saveConnection() async {
    if (_host == null || _port == null || _credential == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _connectionKey,
      jsonEncode({'host': _host, 'port': _port, 'credential': _credential, 'pcName': _pcName}),
    );
  }

  String _randomId() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(18, (_) => random.nextInt(256))).replaceAll('=', '');
  }
}
