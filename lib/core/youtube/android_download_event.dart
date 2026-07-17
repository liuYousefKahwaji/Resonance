import 'dart:convert';

class AndroidDownloadTrackEvent {
  final String path;
  final String? title;
  final String? artist;
  final String? coverPath;
  final String? videoId;

  const AndroidDownloadTrackEvent({required this.path, this.title, this.artist, this.coverPath, this.videoId});
}

/// Decodes the ASCII-only transport emitted by the Android Python bridge.
///
/// JSON is encoded as UTF-8 and then base64 so neither Chaquopy, Kotlin's
/// platform channel, nor URI percent decoding can reinterpret metadata bytes.
/// The legacy `track:` form remains readable for in-flight events after an app
/// upgrade and deliberately never throws on malformed percent escapes.
AndroidDownloadTrackEvent? parseAndroidDownloadTrackEvent(String event) {
  if (event.startsWith('track-json:')) {
    try {
      final encoded = event.substring('track-json:'.length);
      final json = jsonDecode(utf8.decode(base64Decode(encoded))) as Map<String, dynamic>;
      final path = json['path']?.toString() ?? '';
      if (path.trim().isEmpty) return null;
      return AndroidDownloadTrackEvent(
        path: path,
        title: _optional(json['title']),
        artist: _optional(json['artist']),
        coverPath: _optional(json['coverPath']),
        videoId: _optional(json['videoId']),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  if (!event.startsWith('track:')) return null;
  final parts = event.substring('track:'.length).split('|');
  if (parts.isEmpty || parts.first.trim().isEmpty) return null;
  return AndroidDownloadTrackEvent(
    path: parts.first,
    title: parts.length > 1 ? _optional(_decodeLegacy(parts[1])) : null,
    artist: parts.length > 2 ? _optional(_decodeLegacy(parts[2])) : null,
    coverPath: parts.length > 3 ? _optional(_decodeLegacy(parts[3])) : null,
    videoId: parts.length > 4 ? _optional(_decodeLegacy(parts[4])) : null,
  );
}

String? _optional(Object? value) {
  final text = value?.toString();
  return text == null || text.isEmpty ? null : text;
}

String _decodeLegacy(String value) {
  if (value.isEmpty) return value;
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    // Older bridge builds could percent-encode bytes in a device code page.
    // Recover those bytes losslessly instead of allowing the download stream
    // to fail with Invalid UTF-8/Missing extension byte.
    final bytes = <int>[];
    for (var index = 0; index < value.length;) {
      if (value.codeUnitAt(index) == 0x25 && index + 2 < value.length) {
        final byte = int.tryParse(value.substring(index + 1, index + 3), radix: 16);
        if (byte != null) {
          bytes.add(byte);
          index += 3;
          continue;
        }
      }
      bytes.addAll(utf8.encode(value[index]));
      index++;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }
}
