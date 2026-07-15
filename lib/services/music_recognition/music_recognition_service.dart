import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:resonance/services/music_recognition/shazam_fingerprint.dart';

enum MusicRecognitionSource { microphone, deviceOutput }

enum MusicRecognitionStage { requestingPermission, waitingForAudio, listening, fingerprinting, matching }

class MusicRecognitionResult {
  final String title;
  final String artist;
  final String? album;
  final String? artworkUrl;
  final String? shazamUrl;

  const MusicRecognitionResult({
    required this.title,
    required this.artist,
    this.album,
    this.artworkUrl,
    this.shazamUrl,
  });

  String get youtubeQuery => [artist, title].where((part) => part.trim().isNotEmpty).join(' ').trim();

  static MusicRecognitionResult? fromShazamResponse(Map<String, dynamic> response) {
    final rawTrack = response['track'];
    if (rawTrack is! Map) return null;
    final track = Map<String, dynamic>.from(rawTrack);
    final title = (track['title'] as String?)?.trim() ?? '';
    final artist = (track['subtitle'] as String?)?.trim() ?? '';
    if (title.isEmpty) return null;

    String? album;
    final sections = track['sections'];
    if (sections is List) {
      for (final rawSection in sections) {
        if (rawSection is! Map || rawSection['metadata'] is! List) continue;
        for (final rawMetadata in rawSection['metadata'] as List) {
          if (rawMetadata is Map && rawMetadata['title'] == 'Album') {
            album = (rawMetadata['text'] as String?)?.trim();
            break;
          }
        }
        if (album?.isNotEmpty == true) break;
      }
    }

    final images = track['images'];
    final artworkUrl = images is Map ? images['coverart'] as String? : null;
    return MusicRecognitionResult(
      title: title,
      artist: artist,
      album: album?.isEmpty == true ? null : album,
      artworkUrl: artworkUrl,
      shazamUrl: track['url'] as String?,
    );
  }
}

class MusicRecognitionException implements Exception {
  final String message;
  const MusicRecognitionException(this.message);

  @override
  String toString() => message;
}

abstract class PcmCapturePlatform {
  Future<Uint8List> capture({
    required MusicRecognitionSource source,
    required Duration captureDuration,
    required Duration waitTimeout,
  });

  Future<void> cancel();
}

class MethodChannelPcmCapture implements PcmCapturePlatform {
  static const MethodChannel _channel = MethodChannel('resonance/music_recognition');

  const MethodChannelPcmCapture();

  @override
  Future<Uint8List> capture({
    required MusicRecognitionSource source,
    required Duration captureDuration,
    required Duration waitTimeout,
  }) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('capturePcm', {
        'source': source == MusicRecognitionSource.microphone ? 'microphone' : 'deviceOutput',
        'captureDurationMs': captureDuration.inMilliseconds,
        'waitTimeoutMs': waitTimeout.inMilliseconds,
      });
      if (bytes == null || bytes.isEmpty) {
        throw const MusicRecognitionException('No audio was captured.');
      }
      return bytes;
    } on MissingPluginException {
      throw const MusicRecognitionException('Music recognition is not available on this platform.');
    } on PlatformException catch (error) {
      throw MusicRecognitionException(_platformErrorMessage(error));
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancelCapture');
    } on MissingPluginException {
      // There is no native capture to cancel in tests or unsupported builds.
    }
  }

  String _platformErrorMessage(PlatformException error) => switch (error.code) {
    'NO_AUDIO_TIMEOUT' => 'No device audio was heard within 20 seconds.',
    'PERMISSION_DENIED' => 'Microphone permission is required to identify music.',
    'PROJECTION_DENIED' => 'Device-audio capture was not approved.',
    'UNSUPPORTED' => error.message ?? 'This audio source is not supported on this device.',
    'BUSY' || 'CAPTURE_BUSY' => 'Another music scan is already running.',
    'CANCELLED' || 'CAPTURE_CANCELLED' => 'Music recognition was cancelled.',
    _ => error.message?.trim().isNotEmpty == true ? error.message!.trim() : 'Audio capture failed.',
  };
}

class ShazamCatalogClient {
  final HttpClient Function() _httpClientFactory;

  ShazamCatalogClient({HttpClient Function()? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  Future<MusicRecognitionResult?> match(ShazamSignature signature) async {
    final localeParts = Platform.localeName.replaceAll('_', '-').split('-');
    final language = localeParts.length >= 2 ? '${localeParts.first}-${localeParts.last.toUpperCase()}' : 'en-US';
    final country = localeParts.length >= 2 && localeParts.last.length == 2 ? localeParts.last.toUpperCase() : 'US';
    final device = Platform.isAndroid ? 'android' : 'web';
    final firstId = _uuidV4();
    final secondId = _uuidV4();
    final uri = Uri.parse(
      'https://amp.shazam.com/discovery/v5/$language/$country/$device/-/tag/'
      '$firstId/$secondId?sync=true&webv3=true&sampling=true&connected=&shazamapiversion=v3&'
      'sharehub=true&hubv5minorversion=v5.1&hidelb=true&video=v3',
    );

    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'timezone': DateTime.now().timeZoneName,
      'signature': {'uri': signature.dataUri, 'samplems': signature.durationMilliseconds},
      'timestamp': now,
      'context': <String, dynamic>{},
      'geolocation': <String, dynamic>{},
    };

    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = true;
    try {
      final request = await client.postUrl(uri).timeout(const Duration(seconds: 12));
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.acceptHeader, '*/*')
        ..set(HttpHeaders.acceptLanguageHeader, language)
        ..set('X-Shazam-Platform', 'IPHONE')
        ..set('X-Shazam-AppVersion', '14.1.0')
        ..set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
        );
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(const Duration(seconds: 25));
      final body = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MusicRecognitionException('The music service returned HTTP ${response.statusCode}.');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const MusicRecognitionException('The music service returned an invalid response.');
      return MusicRecognitionResult.fromShazamResponse(Map<String, dynamic>.from(decoded));
    } on TimeoutException {
      throw const MusicRecognitionException('Music matching timed out. Check your internet connection and try again.');
    } on SocketException {
      throw const MusicRecognitionException('Could not reach the music matching service.');
    } on FormatException {
      throw const MusicRecognitionException('The music service returned an invalid response.');
    } finally {
      client.close(force: true);
    }
  }
}

class MusicRecognitionService {
  final PcmCapturePlatform capturePlatform;
  final ShazamCatalogClient catalogClient;
  bool _cancelled = false;

  MusicRecognitionService({PcmCapturePlatform? capturePlatform, ShazamCatalogClient? catalogClient})
    : capturePlatform = capturePlatform ?? const MethodChannelPcmCapture(),
      catalogClient = catalogClient ?? ShazamCatalogClient();

  Future<MusicRecognitionResult?> recognize(
    MusicRecognitionSource source, {
    required void Function(MusicRecognitionStage stage) onStage,
  }) async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      throw const MusicRecognitionException('Music recognition is supported on Android and Windows.');
    }
    _cancelled = false;

    if (Platform.isAndroid) {
      onStage(MusicRecognitionStage.requestingPermission);
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        throw const MusicRecognitionException('Microphone permission is required to identify music.');
      }
      if (source == MusicRecognitionSource.deviceOutput) {
        // The foreground capture still works when notification access is
        // declined, but asking here keeps the listening indicator visible in
        // the notification drawer after Resonance moves to the background.
        await Permission.notification.request();
      }
    }
    _throwIfCancelled();

    onStage(
      source == MusicRecognitionSource.deviceOutput
          ? MusicRecognitionStage.waitingForAudio
          : MusicRecognitionStage.listening,
    );
    final pcm = await capturePlatform.capture(
      source: source,
      captureDuration: const Duration(seconds: 8),
      waitTimeout: source == MusicRecognitionSource.deviceOutput ? const Duration(seconds: 20) : Duration.zero,
    );
    _throwIfCancelled();

    onStage(MusicRecognitionStage.fingerprinting);
    final signature = await Isolate.run(() => ShazamFingerprint.generate(pcm));
    _throwIfCancelled();

    onStage(MusicRecognitionStage.matching);
    return catalogClient.match(signature);
  }

  Future<void> cancel() async {
    _cancelled = true;
    await capturePlatform.cancel();
  }

  void _throwIfCancelled() {
    if (_cancelled) throw const MusicRecognitionException('Music recognition was cancelled.');
  }
}

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
