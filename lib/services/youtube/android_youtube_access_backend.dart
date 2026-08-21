import 'package:flutter/services.dart';
import 'package:resonance/services/youtube/youtube_access_backend.dart';

class AndroidYoutubeAccessBackend implements YoutubeAccessBackend {
  AndroidYoutubeAccessBackend({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('resonance/youtube_access');

  final MethodChannel _channel;

  @override
  Future<Map<String, Object?>> getStatus() => _map('getStatus');

  @override
  Future<Map<String, Object?>> importCookies(Uint8List bytes) => _map('importCookies', {'bytes': bytes});

  @override
  Future<Map<String, Object?>> clearCookies() => _map('clearCookies');

  @override
  Future<void> testCookies({String? sourceUrl}) async {
    await _channel.invokeMethod<Object?>('testCookies', {if (sourceUrl != null) 'url': sourceUrl});
  }

  @override
  Future<bool> isFirefoxInstalled() async => await _channel.invokeMethod<bool>('isFirefoxInstalled') ?? false;

  @override
  Future<bool> openFirefoxUrl(String url) async {
    final result = await _channel.invokeMapMethod<String, Object?>('openFirefoxUrl', {'url': url});
    return result?['launched'] == true;
  }

  @override
  Future<bool> openYoutubeAppSettings() async => await _channel.invokeMethod<bool>('openYoutubeAppSettings') ?? false;

  Future<Map<String, Object?>> _map(String method, [Map<String, Object?>? arguments]) async {
    final result = await _channel.invokeMapMethod<String, Object?>(method, arguments);
    return result ?? const {};
  }
}
