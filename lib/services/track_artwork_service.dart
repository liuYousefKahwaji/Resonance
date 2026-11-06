import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'metadata_cache_service.dart';
import 'track_source_repository.dart';

enum CoverRepairResult { updated, unchanged, notFound }

/// One artwork policy for rows, mosaics, players and system media controls.
/// Content-addressed files give Flutter a new image key after a cover edit.
class TrackArtworkService {
  const TrackArtworkService({this.directory, this.readEmbedded});
  final Directory? directory;
  final Future<Uint8List?> Function(String)? readEmbedded;
  static final _changes = StreamController<String>.broadcast(sync: true);
  static Stream<String> get changes => _changes.stream;
  static final _writes = <String, Future<File>>{};
  static final _embedded = <String, ({String stamp, Uri? uri})>{};
  static final _revisions = <String, int>{};

  String _key(String path) {
    final normalized = p.normalize(p.absolute(path));
    return sha256.convert(utf8.encode(Platform.isWindows ? normalized.toLowerCase() : normalized)).toString();
  }

  String _preference(String path) => 'track_artwork_override_${_key(path)}';
  String _originalPreference(String path) => 'track_artwork_original_${_key(path)}';

  static void notifyChanged(String path) {
    _embedded.remove(path);
    _revisions[path] = (_revisions[path] ?? 0) + 1;
    _changes.add(path);
  }

  Future<Uri?> resolve(String path, {bool allowRemote = true}) async {
    try {
      return await _resolve(path, allowRemote: allowRemote);
    } catch (_) {
      return null; // Optional artwork must never fail playback or browsing.
    }
  }

  Future<bool> hasOverride(String path) async {
    final value = (await SharedPreferences.getInstance()).getString(_preference(path));
    return value != null && value != 'original';
  }

  /// Capture once, before native tag writes can add/replace an embedded picture.
  Future<void> rememberOriginal(String path) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_originalPreference(path))) return;
    final original = await resolveOriginal(path);
    await prefs.setString(_originalPreference(path), original?.toString() ?? 'none');
  }

  /// Preview the original without changing the saved choice until Save is pressed.
  Future<Uri?> resolveOriginal(String path, {bool allowRemote = true}) async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(_originalPreference(path));
      if (stored == 'none') return null;
      if (stored != null) {
        final uri = Uri.tryParse(stored);
        if (uri?.scheme == 'file') return await File.fromUri(uri!).exists() ? uri : null;
        return allowRemote && (uri?.scheme == 'http' || uri?.scheme == 'https') ? uri : null;
      }
      return await _resolve(path, allowRemote: allowRemote, ignoreOverride: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> restoreOriginal(String path) async {
    await (await SharedPreferences.getInstance()).setString(_preference(path), 'original');
    notifyChanged(path);
  }

  Future<Uri?> _resolve(String path, {required bool allowRemote, bool ignoreOverride = false}) async {
    final revision = _revisions[path] ?? 0;
    if (path.startsWith('https://') || path.startsWith('http://')) {
      final url = (await MetadataCacheService.get(path))?.artworkUrl;
      return allowRemote && url?.isNotEmpty == true ? Uri.tryParse(url!) : null;
    }
    final source = File(path);
    if (!await source.exists()) return null;
    final prefs = await SharedPreferences.getInstance();
    final override = ignoreOverride ? null : prefs.getString(_preference(path));
    if (override == 'none') return null;
    if (override == 'original') return resolveOriginal(path, allowRemote: allowRemote);
    if (override != null) {
      final uri = Uri.tryParse(override);
      if (uri?.scheme == 'file' && await File.fromUri(uri!).exists()) return uri;
    }
    final stat = await source.stat();
    final stamp = '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    final entry = _embedded[path];
    Uri? embedded = entry?.stamp == stamp ? entry!.uri : null;
    if (entry?.stamp != stamp) {
      try {
        final bytes = await (readEmbedded?.call(path) ?? _readEmbedded(path));
        if (bytes != null && bytes.isNotEmpty) embedded = (await _store(bytes)).uri;
      } catch (_) {
        /* Some original containers have no supported tag reader. */
      }
      if (revision != (_revisions[path] ?? 0)) {
        return ignoreOverride
            ? resolveOriginal(path, allowRemote: allowRemote)
            : resolve(path, allowRemote: allowRemote);
      }
      if (_embedded.length >= 80) _embedded.remove(_embedded.keys.first);
      _embedded[path] = (stamp: stamp, uri: embedded);
    }
    if (embedded != null || !allowRemote) return embedded;
    final cached = await MetadataCacheService.get(path);
    if (cached?.artworkUrl?.isNotEmpty == true) return Uri.tryParse(cached!.artworkUrl!);
    final sourceRecord = await const TrackSourceRepository().getSourceForTrack(path);
    return sourceRecord == null ? null : Uri.parse(TrackSourceRepository.thumbnailUrlFor(sourceRecord.youtubeVideoId));
  }

  Future<Uint8List?> _readEmbedded(String path) async {
    final bytes = (await MetadataGod.readMetadata(file: path)).picture?.data;
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  Future<File> _store(Uint8List bytes) async {
    final folder = directory ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'track_artwork'));
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, '${sha256.convert(bytes)}.png'));
    // Image decoders detect JPEG/PNG/WebP from bytes, irrespective of the suffix.
    return _writes.putIfAbsent(file.path, () async {
      try {
        if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
        return file;
      } finally {
        _writes.remove(file.path);
      }
    });
  }

  Future<void> saveCover(String path, Uint8List bytes) async {
    if (bytes.isEmpty) throw ArgumentError('Empty cover image');
    final file = await _store(bytes);
    await (await SharedPreferences.getInstance()).setString(_preference(path), file.uri.toString());
    notifyChanged(path);
  }

  Future<CoverRepairResult> fillMissingCover(
    String path, {
    required Future<Uint8List> Function(String) download,
    required Future<String?> Function() lookup,
  }) async {
    if (await resolve(path, allowRemote: false) != null) return CoverRepairResult.unchanged;
    final cached = await MetadataCacheService.get(path);
    final source = await const TrackSourceRepository().getSourceForTrack(path);
    final tried = <String>{};
    Future<bool> attempt(String? url) async {
      if (url == null || url.isEmpty || !tried.add(url)) return false;
      try {
        final bytes = await download(url);
        if (bytes.isEmpty) return false;
        // A 200 HTML error page or corrupt thumbnail is not a repaired cover.
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 512, allowUpscaling: false);
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
        await saveCover(path, bytes);
        return true;
      } catch (_) {
        return false;
      }
    }

    if (await attempt(cached?.artworkUrl)) return CoverRepairResult.updated;
    if (source != null && await attempt(TrackSourceRepository.thumbnailUrlFor(source.youtubeVideoId))) {
      return CoverRepairResult.updated;
    }
    return await attempt(await lookup()) ? CoverRepairResult.updated : CoverRepairResult.notFound;
  }

  /// Called only after a successful tag edit. A deliberate removal must not
  /// silently restore the downloaded YouTube thumbnail.
  Future<void> embeddedChanged(String path, {bool removed = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (removed) {
      await prefs.setString(_preference(path), 'none');
    } else {
      await prefs.remove(_preference(path));
    }
    notifyChanged(path);
  }
}
