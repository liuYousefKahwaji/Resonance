import 'dart:convert';
import 'dart:io';

/// Makes the embedded Windows yt-dlp process emit UTF-8 even when the user's
/// active Windows code page is a legacy single-byte encoding.
const Map<String, String> windowsYtDlpUtf8Environment = {'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'};

/// yt-dlp's explicit encoding flag complements the Python environment above.
const List<String> windowsYtDlpUtf8Arguments = ['--encoding', 'utf-8'];

/// Decodes a completed Windows child-process stream without allowing a legacy
/// console code page to abort an otherwise successful download.
///
/// New processes are forced to UTF-8, while the system/Latin-1 fallbacks keep
/// output from older cached yt-dlp builds readable enough for path recovery.
String decodeWindowsProcessOutput(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    try {
      return systemEncoding.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }
}

Future<String> collectWindowsProcessOutput(Stream<List<int>> source) async {
  final bytes = <int>[];
  await for (final chunk in source) {
    bytes.addAll(chunk);
  }
  return decodeWindowsProcessOutput(bytes);
}

/// Progress/error output must remain live. Malformed legacy bytes are replaced
/// here because authoritative completed file paths are recovered separately.
Stream<String> decodeWindowsProcessLines(Stream<List<int>> source) =>
    source.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());

/// Parses both Resonance's stdout progress template and yt-dlp's ordinary
/// stderr progress output. Fragment-only downloads are supported as a
/// fallback when no percentage is present.
double? parseWindowsYtDlpProgress(String line) {
  final template = RegExp(r'resonance_progress:\s*(\d+(?:\.\d+)?)%').firstMatch(line);
  if (template != null) return double.tryParse(template.group(1)!);
  final ordinary = RegExp(r'\[download\]\s+(\d+(?:\.\d+)?)%').firstMatch(line);
  if (ordinary != null) return double.tryParse(ordinary.group(1)!);
  final fragment = RegExp(r'\(frag\s+(\d+)/(\d+)\)').firstMatch(line);
  if (fragment == null) return null;
  final current = int.tryParse(fragment.group(1)!);
  final total = int.tryParse(fragment.group(2)!);
  return current == null || total == null || total == 0 ? null : current / total * 100;
}
