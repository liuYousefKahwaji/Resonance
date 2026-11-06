import 'package:resonance/services/youtube/youtube_request.dart';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_download_result.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/widgets/youtube/android_youtube.dart' as android_youtube;
import 'package:resonance/widgets/youtube/windows_youtube.dart' as windows_youtube;
import 'package:shared_preferences/shared_preferences.dart';

class YoutubeSearchCandidate {
  final String title;
  final String uploader;
  final String url;
  final String videoId;
  final int? durationSeconds;
  final String? thumbnailUrl;

  const YoutubeSearchCandidate({
    required this.title,
    required this.uploader,
    required this.url,
    required this.videoId,
    this.durationSeconds,
    this.thumbnailUrl,
  });

  String get formattedDuration {
    if (durationSeconds == null) return '';
    final minutes = durationSeconds! ~/ 60;
    final seconds = durationSeconds! % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class YoutubeTransferService {
  final TrackSourceRepository sourceRepository;
  final windows_youtube.MediaDownloader? windowsDownloader;

  YoutubeTransferService({this.sourceRepository = const TrackSourceRepository(), this.windowsDownloader});
  bool get _usesWindows => windowsDownloader != null || Platform.isWindows;

  Future<Map<String, String>> prepareStreams(PlaylistTransferManifest manifest) async {
    PlaylistTransferCodec.validateManifest(manifest);
    await MetadataCacheService.setStreams({
      for (final entry in manifest.trackMetadata.entries)
        TrackSourceRepository.canonicalUrlFor(entry.key): CachedTrackMetadata(
          title: entry.value.title,
          artist: entry.value.artist,
          artworkUrl: TrackSourceRepository.thumbnailUrlFor(entry.key),
        ),
    });
    return {for (final id in manifest.youtubeVideoIds) id: TrackSourceRepository.canonicalUrlFor(id)};
  }

  Future<List<YoutubeSearchCandidate>> search(String query) async {
    if (_usesWindows) {
      final downloader = windowsDownloader ?? windows_youtube.MediaDownloader();
      await downloader.initBinaries();
      final results = await downloader.search(query);
      return [
        for (final result in results)
          if (TrackSourceRepository.videoIdFromUrlOrId(result.url) case final String videoId)
            YoutubeSearchCandidate(
              title: result.title,
              uploader: result.uploader,
              url: TrackSourceRepository.canonicalUrlFor(videoId),
              videoId: videoId,
              durationSeconds: result.durationSeconds,
              thumbnailUrl: result.thumbnailUrl,
            ),
      ];
    }
    if (Platform.isAndroid) {
      final results = await android_youtube.AndroidYoutubeDownloader().search(query);
      return [
        for (final result in results)
          if (TrackSourceRepository.videoIdFromUrlOrId(result.url) case final String videoId)
            YoutubeSearchCandidate(
              title: result.title,
              uploader: result.uploader,
              url: TrackSourceRepository.canonicalUrlFor(videoId),
              videoId: videoId,
              durationSeconds: result.durationSeconds,
              thumbnailUrl: result.thumbnailUrl,
            ),
      ];
    }
    throw UnsupportedError('Playlist transfer downloads are supported on Windows and Android.');
  }

  Future<YoutubeSearchCandidate> lookup(String urlOrVideoId) async {
    final videoId = TrackSourceRepository.videoIdFromUrlOrId(urlOrVideoId);
    if (videoId == null) throw ArgumentError.value(urlOrVideoId, 'urlOrVideoId', 'Invalid YouTube URL or video ID');
    final url = TrackSourceRepository.canonicalUrlFor(videoId);
    final track = _usesWindows
        ? await (() async {
            final downloader = windowsDownloader ?? windows_youtube.MediaDownloader();
            await downloader.initBinaries();
            return downloader.lookup(url);
          })()
        : Platform.isAndroid
        ? await android_youtube.AndroidYoutubeDownloader().lookup(url)
        : throw UnsupportedError('YouTube lookup is supported on Windows and Android.');
    return YoutubeSearchCandidate(
      title: track.title,
      uploader: track.artist,
      url: url,
      videoId: videoId,
      durationSeconds: track.durationSeconds,
      thumbnailUrl: track.thumbnailUrl,
    );
  }

  Future<String> rememberStream(YoutubeSearchCandidate candidate) async {
    final url = TrackSourceRepository.canonicalUrlFor(candidate.videoId);
    await MetadataCacheService.set(url, candidate.title, candidate.uploader, artworkUrl: candidate.thumbnailUrl);
    return url;
  }

  Future<YoutubeDownloadResult> downloadVideo(
    String videoId, {
    required void Function(double percentage, String status) onProgress,
    YoutubeRequest? request,
    TrackSourceMethod sourceMethod = TrackSourceMethod.importedFromQrTransfer,
    String? historyTitle,
    String? historyArtist,
  }) async {
    if (!TrackSourceRepository.isValidYoutubeVideoId(videoId)) {
      throw ArgumentError.value(videoId, 'videoId', 'Invalid YouTube video ID');
    }
    request?.check();
    final url = TrackSourceRepository.canonicalUrlFor(videoId);
    var resolvedTitle = _nonEmpty(historyTitle);
    var resolvedArtist = _nonEmpty(historyArtist);
    final cached = await MetadataCacheService.get(url);
    resolvedTitle ??= _nonEmpty(cached?.title);
    resolvedArtist ??= _nonEmpty(cached?.artist);
    YoutubeDownloadResult result;
    if (_usesWindows) {
      final downloader = windowsDownloader ?? windows_youtube.MediaDownloader();
      await downloader.initBinaries();
      final downloaded = <YoutubeDownloadResult>[];
      final details = <String, YoutubeDownloadResult>{};
      await downloader.downloadAudio(
        url: url,
        onProgress: onProgress,
        request: request,
        historyTitle: resolvedTitle,
        historyArtist: resolvedArtist,
        onTrackPrepared: (track) {
          details[track.localPath] = track;
        },
        onTrackDownloaded: (path, downloadedVideoId) async {
          final track = details[path];
          downloaded.add(
            YoutubeDownloadResult(
              localPath: path,
              youtubeVideoId: downloadedVideoId ?? videoId,
              title: track?.title ?? resolvedTitle,
              artist: track?.artist ?? resolvedArtist,
            ),
          );
        },
      );
      if (downloaded.isEmpty) throw Exception('The download finished without a local audio file.');
      result = downloaded.firstWhere(
        (item) => item.youtubeVideoId == videoId,
        orElse: () => throw StateError('The downloaded audio did not match the requested song.'),
      );
    } else if (Platform.isAndroid) {
      final downloaded = await android_youtube.AndroidYoutubeDownloader().downloadAudio(
        url,
        onProgress: onProgress,
        request: request,
        historyTitle: resolvedTitle,
        historyArtist: resolvedArtist,
      );
      if (downloaded.isEmpty) throw Exception('The download finished without a local audio file.');
      result = downloaded.firstWhere(
        (item) => item.youtubeVideoId == videoId,
        orElse: () => throw StateError('The downloaded audio did not match the requested song.'),
      );
    } else {
      throw UnsupportedError('Playlist transfer downloads are supported on Windows and Android.');
    }
    request?.check();
    await sourceRepository.saveSource(
      localPath: result.localPath,
      youtubeVideoId: videoId,
      method: sourceMethod,
      lastVerifiedAt: DateTime.now().toUtc(),
    );
    if (_nonEmpty(result.title) != null && _nonEmpty(result.artist) != null) {
      await MetadataCacheService.set(result.localPath, result.title!, result.artist!);
      await MetadataCacheService.set(
        url,
        result.title!,
        result.artist!,
        artworkUrl: TrackSourceRepository.thumbnailUrlFor(videoId),
      );
    }
    return YoutubeDownloadResult(
      localPath: result.localPath,
      youtubeVideoId: videoId,
      title: result.title ?? resolvedTitle,
      artist: result.artist ?? resolvedArtist,
    );
  }

  Future<String> downloadDestinationDescription() async {
    final prefs = await SharedPreferences.getInstance();
    final configured = prefs.getString('download_directory');
    if (configured != null && configured != 'Default App Folder' && configured.trim().isNotEmpty) {
      return configured;
    }
    if (Platform.isWindows) {
      return (await getDownloadsDirectory())?.path ?? (await getApplicationSupportDirectory()).path;
    }
    if (Platform.isAndroid) {
      return (await getExternalStorageDirectory())?.path ?? (await getApplicationDocumentsDirectory()).path;
    }
    return (await getApplicationSupportDirectory()).path;
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
