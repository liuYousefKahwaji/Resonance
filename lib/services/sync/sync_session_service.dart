import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/equalizer_settings.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_source_repository.dart';

enum SyncRole { inactive, host, peer }

@visibleForTesting
int? reusableHostSyncPlaylist(Map<int, String> names) {
  final matches =
      names.entries
          .where((entry) => RegExp(r'^Sync(?: \(\d+\))?$', caseSensitive: false).hasMatch(entry.value.trim()))
          .toList()
        ..sort((first, second) {
          final firstExact = first.value.trim().toLowerCase() == 'sync';
          final secondExact = second.value.trim().toLowerCase() == 'sync';
          if (firstExact != secondExact) return firstExact ? -1 : 1;
          return first.key.compareTo(second.key);
        });
  return matches.firstOrNull?.key;
}

class SyncSessionService extends ChangeNotifier {
  SyncSessionService._();
  static final SyncSessionService instance = SyncSessionService._();

  PlayerHandler? _handler;
  SyncRole _role = SyncRole.inactive;
  HttpServer? _server;
  WebSocket? _peerSocket;
  final Set<WebSocket> _peers = {};
  StreamSubscription<MediaItem?>? _mediaSubscription;
  StreamSubscription<PlaylistMutation>? _playlistSubscription;
  Timer? _anchorTimer;
  Timer? _tokenTimer;
  String? _hostAddress;
  String? _token;
  String? _sessionId;
  int? _playlistNumber;
  String? _playlistName;
  String? _hostName;
  String? _error;
  bool _applyingState = false;
  Map<String, dynamic>? _pendingPeerState;

  SyncRole get role => _role;
  bool get active => _role != SyncRole.inactive;
  bool get isHost => _role == SyncRole.host;
  bool get isPeer => _role == SyncRole.peer;
  int get peerCount => _peers.length;
  int? get playlistNumber => _playlistNumber;
  String? get playlistName => _playlistName;
  String? get hostName => _hostName;
  String? get error => _error;

  String? get pairingPayload {
    if (!isHost || _hostAddress == null || _server == null || _token == null || _sessionId == null) return null;
    return Uri(
      scheme: 'resonance',
      host: 'sync',
      queryParameters: {
        'v': '1',
        'host': _hostAddress!,
        'port': '${_server!.port}',
        'session': _sessionId!,
        'token': _token!,
        'name': Platform.localHostname,
      },
    ).toString();
  }

  void initialize(PlayerHandler handler) => _handler ??= handler;

  Future<int> startHosting({
    required int currentPlaylistNumber,
    required String currentPlaylistName,
    required List<String> currentTracks,
  }) async {
    if (!Platform.isAndroid) throw UnsupportedError('Resonance Sync hosting currently requires Android');
    await leave();
    final streams = currentTracks.where(_isStream).toList(growable: false);
    if (streams.length == currentTracks.length && currentTracks.isNotEmpty) {
      _playlistNumber = currentPlaylistNumber;
      _playlistName = currentPlaylistName;
    } else {
      final files = FileService();
      final names = await files.getPlaylistNames();
      final reusableNumber = reusableHostSyncPlaylist(names);
      if (reusableNumber != null) {
        _playlistNumber = reusableNumber;
        _playlistName = names[reusableNumber];
        await files.setActivePlaylistNumber(reusableNumber);
        final existingTracks = await files.readPlaylistTracks(reusableNumber);
        final existingStreams = existingTracks.where(_isStream).toList(growable: false);
        if (existingStreams.length != existingTracks.length) {
          await files.replacePlaylistTracks(reusableNumber, existingStreams);
        }
      } else {
        final created = await files.createImportedPlaylist('Sync', streams);
        _playlistNumber = created.number;
        _playlistName = created.displayName;
      }
    }
    _token = _randomToken(24);
    _sessionId = _randomToken(9);
    _hostName = Platform.localHostname;
    _error = null;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _hostAddress = await _preferredLanAddress();
      _server!.listen(_handleHostRequest, onError: _sessionError);
      _role = SyncRole.host;
      _handler?.setSyncSessionMode(active: true, peerControlled: false);
      _mediaSubscription = _handler?.mediaItem.listen((_) => unawaited(_broadcastState()));
      _playlistSubscription = FileService.mutations.listen((mutation) {
        if (mutation.playlistNumber == _playlistNumber) unawaited(_broadcastQueue());
      });
      _anchorTimer = Timer.periodic(const Duration(milliseconds: 350), (_) => unawaited(_broadcastState()));
      // Joining is intentionally short-lived. Existing sockets remain valid.
      _tokenTimer = Timer(const Duration(minutes: 5), () {
        _token = null;
        notifyListeners();
      });
      notifyListeners();
      return _playlistNumber!;
    } catch (error) {
      await leave();
      rethrow;
    }
  }

  Future<void> join(String payload) async {
    if (!Platform.isAndroid) throw UnsupportedError('Resonance Sync joining currently requires Android');
    final uri = Uri.tryParse(payload.trim());
    if (uri == null || uri.scheme != 'resonance' || uri.host != 'sync' || uri.queryParameters['v'] != '1') {
      throw const FormatException('This is not a Resonance Sync code');
    }
    final host = uri.queryParameters['host'];
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    final token = uri.queryParameters['token'];
    if (host == null || port == null || token == null) throw const FormatException('Incomplete Resonance Sync code');
    await leave();
    _hostName = uri.queryParameters['name'] ?? 'Host';
    _error = null;
    final socket = await WebSocket.connect(
      Uri(scheme: 'ws', host: host, port: port, path: '/sync', queryParameters: {'token': token}).toString(),
    ).timeout(const Duration(seconds: 8));
    _peerSocket = socket;
    _role = SyncRole.peer;
    _handler?.setSyncSessionMode(active: true, peerControlled: true);
    socket.listen(
      (data) {
        if (data is String && data.length <= 262144) unawaited(_handlePeerMessage(data));
      },
      onDone: () => unawaited(_peerDisconnected()),
      onError: (Object error) {
        _error = 'Sync connection lost: $error';
        unawaited(_peerDisconnected());
      },
      cancelOnError: true,
    );
    notifyListeners();
  }

  Future<void> leave() async {
    final wasPeer = isPeer;
    _anchorTimer?.cancel();
    _tokenTimer?.cancel();
    await _mediaSubscription?.cancel();
    await _playlistSubscription?.cancel();
    _anchorTimer = null;
    _tokenTimer = null;
    _mediaSubscription = null;
    _playlistSubscription = null;
    final peer = _peerSocket;
    _peerSocket = null;
    if (peer != null) await peer.close(WebSocketStatus.normalClosure, 'Left Resonance Sync').catchError((_) {});
    for (final socket in _peers.toList(growable: false)) {
      await socket.close(WebSocketStatus.goingAway, 'Host ended Resonance Sync').catchError((_) {});
    }
    _peers.clear();
    await _server?.close(force: true);
    _server = null;
    _handler?.setSyncSessionMode(active: false, peerControlled: false);
    if (wasPeer) _handler?.setStandalonePresentation(false);
    _role = SyncRole.inactive;
    _hostAddress = null;
    _token = null;
    _sessionId = null;
    _playlistNumber = null;
    _playlistName = null;
    notifyListeners();
  }

  void _handleHostRequest(HttpRequest request) async {
    if (request.uri.path != '/sync' || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Resonance Sync')
        ..close();
      return;
    }
    if (_token == null || request.uri.queryParameters['token'] != _token || _peers.length >= 8) {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _peers.add(socket);
    socket.listen((_) {}, onDone: () => _removePeer(socket), onError: (_) => _removePeer(socket), cancelOnError: true);
    await _sendQueue(socket);
    await _sendState(socket);
    notifyListeners();
  }

  void _removePeer(WebSocket socket) {
    _peers.remove(socket);
    notifyListeners();
  }

  Future<void> _broadcastQueue() async {
    for (final socket in _peers.toList(growable: false)) {
      await _sendQueue(socket);
    }
  }

  Future<void> _sendQueue(WebSocket socket) async {
    final number = _playlistNumber;
    if (number == null) return;
    final tracks = await FileService().readPlaylistTracks(number);
    final items = <Map<String, dynamic>>[];
    for (final url in tracks.where(_isStream)) {
      final metadata = await MetadataCacheService.get(url);
      items.add({
        'url': url,
        'title': metadata?.title ?? 'YouTube stream',
        'artist': metadata?.artist ?? 'Unknown Artist',
        'artwork': _streamArtwork(url, metadata?.artworkUrl),
      });
    }
    _send(socket, {'type': 'queue', 'host': Platform.localHostname, 'items': items});
  }

  Future<void> _broadcastState() async {
    if (!isHost || _peers.isEmpty) return;
    for (final socket in _peers.toList(growable: false)) {
      await _sendState(socket);
    }
  }

  Future<void> _sendState(WebSocket socket) async {
    final handler = _handler;
    final item = handler?.mediaItem.value;
    if (handler == null || item == null || !_isStream(item.id)) return;
    final metadata = await MetadataCacheService.get(item.id);
    final artwork = _streamArtwork(item.id, item.artUri?.toString() ?? metadata?.artworkUrl);
    _send(socket, {
      'type': 'state',
      'url': item.id,
      'title': item.title,
      'artist': item.artist,
      'artwork': artwork,
      'playing': await handler.isPlaying(),
      'speed': handler.speedNotifier.value,
      'pitch': handler.pitchNotifier.value,
      'equalizer': handler.equalizerNotifier.value.toJson(),
      'loop': handler.currentLoopMode.name,
      'shuffle': handler.isShuffle,
      'positionMs': handler.currentPosition.inMilliseconds,
      'sentAtMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _handlePeerMessage(String raw) async {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);
    switch (message['type']) {
      case 'queue':
        await _applyQueue(message);
        return;
      case 'state':
        await _applyState(message);
        return;
    }
  }

  Future<void> _applyQueue(Map<String, dynamic> message) async {
    final rawItems = message['items'];
    if (rawItems is! List) return;
    final tracks = <String>[];
    for (final raw in rawItems.whereType<Map>()) {
      final item = Map<String, dynamic>.from(raw);
      final url = item['url']?.toString();
      if (url == null || !_isStream(url)) continue;
      tracks.add(url);
      final artwork = _streamArtwork(url, item['artwork']?.toString());
      await MetadataCacheService.set(
        url,
        item['title']?.toString() ?? 'YouTube stream',
        item['artist']?.toString() ?? 'Unknown Artist',
        artworkUrl: artwork,
      );
    }
    if (_playlistNumber == null) {
      final files = FileService();
      final requestedName = 'Sync - ${_hostName ?? 'Host'}';
      final names = await files.getPlaylistNames();
      final reusable = names.entries
          .where((entry) => entry.value.trim().toLowerCase() == requestedName.toLowerCase())
          .firstOrNull;
      if (reusable != null) {
        _playlistNumber = reusable.key;
        _playlistName = reusable.value;
        await files.setActivePlaylistNumber(reusable.key);
        await files.replacePlaylistTracks(reusable.key, tracks);
      } else {
        final created = await files.createImportedPlaylist(requestedName, tracks);
        _playlistNumber = created.number;
        _playlistName = created.displayName;
      }
    } else {
      await FileService().replacePlaylistTracks(_playlistNumber!, tracks);
    }
    notifyListeners();
  }

  Future<void> _applyState(Map<String, dynamic> message) async {
    if (_applyingState) {
      // Stream resolution can take seconds on a peer. Keep only the newest
      // anchor so it catches up immediately after preparation instead of
      // briefly starting from the stale state that initiated the load.
      _pendingPeerState = message;
      return;
    }
    final url = message['url']?.toString();
    final handler = _handler;
    if (url == null || handler == null || !_isStream(url)) return;
    _applyingState = true;
    try {
      await handler.runSynchronizedCommand(() async {
        final sentAt = (message['sentAtMs'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
        final transit = (DateTime.now().millisecondsSinceEpoch - sentAt).clamp(0, 250);
        final playing = message['playing'] == true;
        final basePosition = (message['positionMs'] as num?)?.toInt() ?? 0;
        final target = Duration(milliseconds: basePosition + (playing ? transit : 0));
        final speed = (message['speed'] as num?)?.toDouble();
        final pitch = (message['pitch'] as num?)?.toDouble();
        final equalizer = EqualizerSettings.fromJson(message['equalizer']);
        final loopName = message['loop']?.toString();
        final loop = LoopMode.values.where((value) => value.name == loopName).firstOrNull;
        final shuffle = message['shuffle'] as bool?;
        if (speed != null && (handler.speedNotifier.value - speed).abs() > .001) await handler.setSpeed(speed);
        if (pitch != null && (handler.pitchNotifier.value - pitch).abs() > .001) await handler.setPitch(pitch);
        if (handler.equalizerNotifier.value != equalizer) await handler.setEqualizer(equalizer);
        if (loop != null && handler.currentLoopMode != loop) await handler.setLoopMode(loop);
        if (shuffle != null && handler.isShuffle != shuffle) await handler.setShuffleEnabled(shuffle);
        if (handler.mediaItem.value?.id != url) {
          final cachedMetadata = await MetadataCacheService.get(url);
          final artworkUrl = _streamArtwork(url, message['artwork']?.toString() ?? cachedMetadata?.artworkUrl);
          final artwork = Uri.tryParse(artworkUrl ?? '');
          final playlistNumber = _playlistNumber;
          final tracks = playlistNumber == null
              ? const <String>[]
              : await FileService().readPlaylistTracks(playlistNumber);
          final playlistIndex = tracks.indexOf(url);
          await handler.loadTrack(
            url,
            message['title']?.toString() ?? 'YouTube stream',
            message['artist']?.toString() ?? 'Unknown Artist',
            artworkUri: artwork?.hasScheme == true ? artwork : null,
            standalone: true,
            standalonePlaylistNumber: playlistNumber,
            standalonePlaylistIndex: playlistIndex < 0 ? null : playlistIndex,
          );
          await handler.seek(target);
        } else if ((handler.currentPosition - target).abs() > const Duration(milliseconds: 280)) {
          await handler.seek(target);
        }
        if (playing && !(await handler.isPlaying())) {
          await handler.play();
        } else if (!playing && await handler.isPlaying()) {
          await handler.pause();
        }
      });
    } finally {
      _applyingState = false;
      final pending = _pendingPeerState;
      _pendingPeerState = null;
      if (pending != null && isPeer) unawaited(_applyState(pending));
    }
  }

  Future<void> _peerDisconnected() async {
    if (!isPeer) return;
    _handler?.setSyncSessionMode(active: false, peerControlled: false);
    _handler?.setStandalonePresentation(false);
    _peerSocket = null;
    _role = SyncRole.inactive;
    notifyListeners();
  }

  void _send(WebSocket socket, Map<String, dynamic> message) {
    try {
      socket.add(jsonEncode(message));
    } catch (_) {
      _removePeer(socket);
    }
  }

  void _sessionError(Object error) {
    _error = 'Resonance Sync error: $error';
    notifyListeners();
  }

  static bool _isStream(String path) => path.startsWith('http://') || path.startsWith('https://');

  static String? _streamArtwork(String url, String? candidate) {
    final parsed = Uri.tryParse(candidate ?? '');
    if (parsed?.hasScheme == true) return parsed.toString();
    final videoId = TrackSourceRepository.videoIdFromUrlOrId(url);
    return videoId == null ? null : TrackSourceRepository.thumbnailUrlFor(videoId);
  }

  String _randomToken(int bytes) {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(bytes, (_) => random.nextInt(256))).replaceAll('=', '');
  }

  Future<String> _preferredLanAddress() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final addresses = interfaces.expand((interface) => interface.addresses).where((address) => !address.isLoopback);
    return addresses
        .firstWhere(
          (address) => address.address.startsWith('192.168.') || address.address.startsWith('10.'),
          orElse: () => addresses.first,
        )
        .address;
  }
}
