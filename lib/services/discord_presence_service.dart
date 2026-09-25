// lib/core/services/discord_presence_service.dart
import 'dart:async';
import 'package:dart_discord_presence/dart_discord_presence.dart';

class DiscordPresenceService {
  static final DiscordPresenceService _instance = DiscordPresenceService._internal();
  factory DiscordPresenceService() => _instance;
  DiscordPresenceService._internal();

  DiscordRPC? _discordRPC;
  Timer? _reconnectTimer;
  bool isReady = false;
  bool _enabled = false;
  int _generation = 0;
  static const String _discordApplicationId = '1516141935763652618';

  // lib/core/services/discord_presence_service.dart
  Future<void> initialize() async {
    if (!_enabled || _discordRPC != null || !DiscordRPC.isAvailable) {
      return;
    }

    final generation = _generation;
    final rpc = DiscordRPC();
    _discordRPC = rpc;

    rpc.onReady.listen((event) {
      if (!_enabled || generation != _generation || !identical(_discordRPC, rpc)) return;
      isReady = true;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    });

    rpc.onError.listen((event) {
      if (!_enabled || generation != _generation || !identical(_discordRPC, rpc)) return;
      isReady = false;
      _attemptReconnection();
    });

    rpc.onDisconnected.listen((event) {
      if (!_enabled || generation != _generation || !identical(_discordRPC, rpc)) return;
      isReady = false;
      _attemptReconnection();
    });

    // Do NOT await – run in background
    unawaited(
      rpc.initialize(_discordApplicationId).catchError((e) {
        if (!identical(_discordRPC, rpc) || generation != _generation) return;
        isReady = false;
        _discordRPC = null;
        _attemptReconnection();
      }),
    );
  }

  void _attemptReconnection() {
    if (!_enabled) return;
    _reconnectTimer ??= Timer(const Duration(seconds: 5), () async {
      await dispose();
      if (_enabled) await initialize();
    });
  }

  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) {
      if (enabled && _discordRPC == null) await initialize();
      return;
    }
    _enabled = enabled;
    if (enabled) {
      await initialize();
    } else {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      try {
        await clearPresence();
      } finally {
        await dispose();
      }
    }
  }

  // Updated method using the new API
  Future<void> updatePresence(String title, String artist) async {
    if (!_enabled) return;
    if (!isReady && _discordRPC == null) {
      await initialize();
    }
    if (_enabled && _discordRPC != null && _discordRPC!.isConnected) {
      await _discordRPC!.setPresence(
        DiscordPresence(
          type: DiscordActivityType.listening,
          details: title, // Line 1: The song name
          state: artist, // Line 2: The artist name
          timestamps: DiscordTimestamps.started(DateTime.now()), // Starts a timer
        ),
      );
    }
  }

  // Add this method inside DiscordPresenceService
  Future<void> setIdle() async {
    if (!_enabled) return;
    if (_discordRPC != null && _discordRPC!.isConnected) {
      await _discordRPC!.setPresence(
        DiscordPresence(type: DiscordActivityType.listening, details: 'Idle', state: 'Nothing playing'),
      );
    }
  }

  // Call this to clear the presence when playback stops
  Future<void> clearPresence() async {
    if (_discordRPC != null && _discordRPC!.isConnected) {
      await _discordRPC!.clearPresence();
    }
  }

  Future<void> dispose() async {
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final rpc = _discordRPC;
    _discordRPC = null;
    isReady = false;
    if (rpc != null) await rpc.dispose();
  }
}
