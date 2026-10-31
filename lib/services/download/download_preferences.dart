import 'package:shared_preferences/shared_preferences.dart';

enum AudioDownloadFormat { original, mp3 }

class DownloadPreferences {
  static const formatKey = 'audio_download_format';
  static Future<AudioDownloadFormat> format() async =>
      (await SharedPreferences.getInstance()).getString(formatKey) == 'mp3'
      ? AudioDownloadFormat.mp3
      : AudioDownloadFormat.original;
  static Future<void> setFormat(AudioDownloadFormat value) async {
    await (await SharedPreferences.getInstance()).setString(formatKey, value.name);
  }
}
