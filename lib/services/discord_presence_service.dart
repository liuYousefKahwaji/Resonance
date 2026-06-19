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
  static const String _discordApplicationId = '1516141935763652618';

  // lib/core/services/discord_presence_service.dart
  Future<void> initialize() async {
    if (!DiscordRPC.isAvailable) {
      return;
    }

    _discordRPC = DiscordRPC();

    _discordRPC!.onReady.listen((event) {
      isReady = true;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    });

    _discordRPC!.onError.listen((event) {
      isReady = false;
      _attemptReconnection();
    });

    _discordRPC!.onDisconnected.listen((event) {
      isReady = false;
      _attemptReconnection();
    });

    // Do NOT await – run in background
    unawaited(
      _discordRPC!.initialize(_discordApplicationId).catchError((e) {
        isReady = false;
        _discordRPC = null;
      }),
    );
  }

  void _attemptReconnection() {
    _reconnectTimer ??= Timer(const Duration(seconds: 5), () async {
      await dispose();
      await initialize();
    });
  }

  // Updated method using the new API
  Future<void> updatePresence(String title, String artist) async {
    if (!isReady && _discordRPC == null) {
      await initialize();
    }
    if (_discordRPC != null && _discordRPC!.isConnected) {
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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_discordRPC != null && _discordRPC!.isConnected) {
      await _discordRPC!.dispose();
      _discordRPC = null;
    }
    isReady = false;
  }
}
