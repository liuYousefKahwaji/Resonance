import 'dart:convert';

const int companionProtocolVersion = 1;
const String companionToggleMuteCommand = 'toggle_mute';
const String companionToggleDeafenCommand = 'toggle_deafen';

class CompanionPairingInfo {
  final String host;
  final int port;
  final String pairingToken;
  final String pcName;

  const CompanionPairingInfo({
    required this.host,
    required this.port,
    required this.pairingToken,
    required this.pcName,
  });

  String encode() => Uri(
    scheme: 'resonance',
    host: 'companion',
    queryParameters: {
      'v': '$companionProtocolVersion',
      'host': host,
      'port': '$port',
      'token': pairingToken,
      'name': pcName,
    },
  ).toString();

  static CompanionPairingInfo parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'resonance' || uri.host != 'companion') {
      throw const FormatException('This is not a Resonance PC Companion code.');
    }
    final version = int.tryParse(uri.queryParameters['v'] ?? '');
    final host = uri.queryParameters['host']?.trim() ?? '';
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    final token = uri.queryParameters['token']?.trim() ?? '';
    final name = uri.queryParameters['name']?.trim() ?? '';
    if (version != companionProtocolVersion) {
      throw const FormatException('This PC Companion code uses an unsupported protocol version.');
    }
    if (host.isEmpty || port == null || port < 1 || port > 65535 || token.length < 24) {
      throw const FormatException('This PC Companion code is incomplete or invalid.');
    }
    return CompanionPairingInfo(
      host: host,
      port: port,
      pairingToken: token,
      pcName: name.isEmpty ? 'Resonance PC' : name,
    );
  }
}

class CompanionTrack {
  final String id;
  final String title;
  final String artist;
  final bool current;

  const CompanionTrack({required this.id, required this.title, required this.artist, required this.current});

  factory CompanionTrack.fromJson(Map<String, dynamic> json) => CompanionTrack(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? 'Unknown track',
    artist: json['artist'] as String? ?? '',
    current: json['current'] == true,
  );
}

class CompanionPlaybackSnapshot {
  final String pcName;
  final bool playing;
  final bool loading;
  final String loopMode;
  final bool shuffle;
  final double volume;
  final int seekStepSeconds;
  final double speed;
  final double pitch;
  final double bass;
  final bool bassSupported;
  final bool equalizerEnabled;
  final String equalizerPreset;
  final List<double> equalizerGainsDb;
  final List<double>? equalizerCustomGainsDb;
  final bool equalizerSupported;
  final List<CompanionTrack> queue;

  const CompanionPlaybackSnapshot({
    this.pcName = 'Resonance PC',
    this.playing = false,
    this.loading = false,
    this.loopMode = 'all',
    this.shuffle = false,
    this.volume = 1,
    this.seekStepSeconds = 5,
    this.speed = 1,
    this.pitch = 1,
    this.bass = 0,
    this.bassSupported = false,
    this.equalizerEnabled = true,
    this.equalizerPreset = 'flat',
    this.equalizerGainsDb = const <double>[0, 0, 0, 0, 0],
    this.equalizerCustomGainsDb,
    this.equalizerSupported = false,
    this.queue = const [],
  });

  CompanionTrack? get currentTrack {
    for (final track in queue) {
      if (track.current) return track;
    }
    return null;
  }

  factory CompanionPlaybackSnapshot.fromJson(Map<String, dynamic> json) {
    final rawQueue = json['queue'];
    return CompanionPlaybackSnapshot(
      pcName: json['pcName'] as String? ?? 'Resonance PC',
      playing: json['playing'] == true,
      loading: json['loading'] == true,
      loopMode: json['loop'] as String? ?? 'all',
      shuffle: json['shuffle'] == true,
      volume: _number(json['volume'], 1).clamp(0.0, 2.0),
      seekStepSeconds: _integer(json['seekStepSeconds'], 5).clamp(1, 15).toInt(),
      speed: _number(json['speed'], 1).clamp(0.5, 2),
      pitch: _number(json['pitch'], 1).clamp(0.5, 2),
      bass: _number(json['bass'], 0).clamp(0, 1),
      bassSupported: json['bassSupported'] == true,
      equalizerEnabled: json['equalizerEnabled'] as bool? ?? true,
      equalizerPreset: json['equalizerPreset'] as String? ?? 'flat',
      equalizerGainsDb: _equalizerGains(json['equalizerGainsDb'], json['bass']),
      equalizerCustomGainsDb: _optionalEqualizerGains(json['equalizerCustomGainsDb']),
      equalizerSupported: json['equalizerSupported'] == true || json['bassSupported'] == true,
      queue: rawQueue is List
          ? rawQueue
                .whereType<Map>()
                .map((item) => CompanionTrack.fromJson(Map<String, dynamic>.from(item)))
                .where((item) => item.id.isNotEmpty)
                .toList(growable: false)
          : const [],
    );
  }
}

List<double>? _optionalEqualizerGains(Object? value) {
  if (value is! List || value.length != 5) return null;
  return value.map((gain) => _number(gain, 0).clamp(-10.0, 10.0)).toList(growable: false);
}

List<double> _equalizerGains(Object? value, Object? legacyBass) {
  final gains = _optionalEqualizerGains(value);
  if (gains != null) return gains;
  final bass = _number(legacyBass, 0).clamp(0.0, 1.0);
  return <double>[bass * 10, bass * 6, 0, 0, 0];
}

double _number(Object? value, double fallback) => value is num ? value.toDouble() : fallback;

int _integer(Object? value, int fallback) => value is num ? value.round() : fallback;

Map<String, dynamic> decodeCompanionMessage(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw const FormatException('Companion messages must be JSON objects.');
  return Map<String, dynamic>.from(decoded);
}
