import 'dart:convert';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/models/youtube_download_result.dart';
import 'package:resonance/services/track_source_repository.dart';

const windowsDownloadMetadataPrefix = 'resonance_metadata:';
const windowsDownloadMetadataTemplate =
    'before_dl:resonance_metadata:%(.{id,title,artist,uploader,channel,thumbnail})j';

/// after_move output is a path plus exact ID, even when a filename contains
/// brackets. Brackets in music filenames must not be mistaken for log tags.
YoutubeDownloadResult? parseWindowsDownloadedPath(String line) {
  final separator = line.lastIndexOf('|');
  if (separator <= 0) return null;
  final id = line.substring(separator + 1).trim();
  if (!TrackSourceRepository.isValidYoutubeVideoId(id)) return null;
  return YoutubeDownloadResult(localPath: line.substring(0, separator), youtubeVideoId: id);
}

YoutubeTrack? parseWindowsDownloadMetadata(String line) {
  if (!line.startsWith(windowsDownloadMetadataPrefix)) return null;
  try {
    final data = jsonDecode(line.substring(windowsDownloadMetadataPrefix.length));
    if (data is! Map || data['id'] is! String || !TrackSourceRepository.isValidYoutubeVideoId(data['id'] as String)) {
      return null;
    }
    String? text(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;
    final title = text(data['title']);
    if (title == null) return null;
    return YoutubeTrack(
      title: title,
      artist: text(data['artist']) ?? text(data['uploader']) ?? text(data['channel']) ?? 'Unknown Artist',
      url: TrackSourceRepository.canonicalUrlFor(data['id'] as String),
      thumbnailUrl: text(data['thumbnail']),
    );
  } catch (_) {
    return null;
  }
}
