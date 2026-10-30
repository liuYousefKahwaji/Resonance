import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/youtube/windows_download_metadata.dart';

void main() {
  test('authoritative paths with brackets do not require scanning the Downloads folder', () {
    final result = parseWindowsDownloadedPath(r'C:\Music\أغنية [slowed].mp3|aaaaaaaaaaa');
    expect(result!.localPath, r'C:\Music\أغنية [slowed].mp3');
    expect(result.youtubeVideoId, 'aaaaaaaaaaa');
    expect(parseWindowsDownloadedPath('[download] Some diagnostic'), isNull);
  });
  test('download metadata preserves Unicode and punctuation without another extraction', () {
    final line =
        '$windowsDownloadMetadataPrefix${jsonEncode({'id': 'aaaaaaaaaaa', 'title': 'أغنية | [live] 🎵', 'artist': 'Artist', 'uploader': 'Uploader'})}';
    final track = parseWindowsDownloadMetadata(line)!;
    expect(track.title, 'أغنية | [live] 🎵');
    expect(track.artist, 'Artist');
    expect(track.videoId, 'aaaaaaaaaaa');
    expect(parseWindowsDownloadMetadata('some diagnostic line'), isNull);
    expect(parseWindowsDownloadMetadata('${windowsDownloadMetadataPrefix}not-json'), isNull);
    expect(parseWindowsDownloadMetadata('$windowsDownloadMetadataPrefix{"id":"invalid","title":"Title"}'), isNull);
  });
}
