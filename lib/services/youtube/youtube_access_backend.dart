import 'dart:typed_data';

abstract class YoutubeAccessBackend {
  Future<Map<String, Object?>> getStatus();

  Future<Map<String, Object?>> importCookies(Uint8List bytes);

  Future<Map<String, Object?>> clearCookies();

  Future<void> testCookies({String? sourceUrl});

  Future<bool> isFirefoxInstalled();

  Future<bool> openFirefoxUrl(String url);

  Future<bool> openYoutubeAppSettings();
}

class MemoryYoutubeAccessBackend implements YoutubeAccessBackend {
  bool configured;
  DateTime? updatedAt;
  Object? testError;
  String? lastTestSourceUrl;

  MemoryYoutubeAccessBackend({this.configured = false, this.updatedAt, this.testError});

  @override
  Future<Map<String, Object?>> getStatus() async => {
    'configured': configured,
    'updatedAt': updatedAt?.millisecondsSinceEpoch,
  };

  @override
  Future<Map<String, Object?>> importCookies(Uint8List bytes) async {
    configured = true;
    updatedAt = DateTime.now();
    return getStatus();
  }

  @override
  Future<Map<String, Object?>> clearCookies() async {
    configured = false;
    updatedAt = null;
    return getStatus();
  }

  @override
  Future<void> testCookies({String? sourceUrl}) async {
    lastTestSourceUrl = sourceUrl;
    if (testError != null) throw testError!;
  }

  @override
  Future<bool> isFirefoxInstalled() async => false;

  @override
  Future<bool> openFirefoxUrl(String url) async => false;

  @override
  Future<bool> openYoutubeAppSettings() async => false;
}
