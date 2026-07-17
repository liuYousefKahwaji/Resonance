import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_download_result.dart';
import 'package:resonance/services/metadata_cache_service.dart';
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

  const YoutubeSearchCandidate({
    required this.title,
    required this.uploader,
    required this.url,
    required this.videoId,
    this.durationSeconds,
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

  YoutubeTransferService({this.sourceRepository = const TrackSourceRepository()});

  Future<List<YoutubeSearchCandidate>> search(String query) async {
    if (Platform.isWindows) {
      final downloader = windows_youtube.MediaDownloader();
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
            ),
      ];
    }
    throw UnsupportedError('Playlist transfer downloads are supported on Windows and Android.');
  }

  Future<YoutubeSearchCandidate> lookup(String urlOrVideoId) async {
    final videoId = TrackSourceRepository.videoIdFromUrlOrId(urlOrVideoId);
    if (videoId == null) throw ArgumentError.value(urlOrVideoId, 'urlOrVideoId', 'Invalid YouTube URL or video ID');
    final url = TrackSourceRepository.canonicalUrlFor(videoId);
    final track = Platform.isWindows
        ? await (() async {
            final downloader = windows_youtube.MediaDownloader();
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
    );
  }

  Future<String> rememberStream(YoutubeSearchCandidate candidate) async {
    final url = TrackSourceRepository.canonicalUrlFor(candidate.videoId);
    await MetadataCacheService.set(url, candidate.title, candidate.uploader);
    return url;
  }

  Future<YoutubeDownloadResult> downloadVideo(
    String videoId, {
    required void Function(double percentage, String status) onProgress,
    TrackSourceMethod sourceMethod = TrackSourceMethod.importedFromQrTransfer,
    String? historyTitle,
    String? historyArtist,
  }) async {
    if (!TrackSourceRepository.isValidYoutubeVideoId(videoId)) {
      throw ArgumentError.value(videoId, 'videoId', 'Invalid YouTube video ID');
    }
    final url = TrackSourceRepository.canonicalUrlFor(videoId);
    var resolvedTitle = _nonEmpty(historyTitle);
    var resolvedArtist = _nonEmpty(historyArtist);
    YoutubeDownloadResult result;
    if (Platform.isWindows) {
      final downloader = windows_youtube.MediaDownloader();
      await downloader.initBinaries();
      if (resolvedTitle == null || resolvedArtist == null) {
        try {
          final metadata = await downloader.lookup(url);
          resolvedTitle ??= _nonEmpty(metadata.title);
          resolvedArtist ??= _nonEmpty(metadata.artist);
        } catch (_) {
          // Metadata improves download history, but must not make the actual
          // transfer fail when yt-dlp can still download the source.
        }
      }
      final downloaded = <YoutubeDownloadResult>[];
      await downloader.downloadAudio(
        url: url,
        onProgress: onProgress,
        historyTitle: resolvedTitle,
        historyArtist: resolvedArtist,
        onTrackDownloaded: (path, downloadedVideoId) async {
          downloaded.add(YoutubeDownloadResult(localPath: path, youtubeVideoId: downloadedVideoId ?? videoId));
        },
      );
      if (downloaded.isEmpty) throw Exception('The download finished without a local audio file.');
      result = downloaded.firstWhere((item) => item.youtubeVideoId == videoId, orElse: () => downloaded.first);
    } else if (Platform.isAndroid) {
      final downloaded = await android_youtube.AndroidYoutubeDownloader().downloadAudio(
        url,
        onProgress: onProgress,
        historyTitle: resolvedTitle,
        historyArtist: resolvedArtist,
      );
      if (downloaded.isEmpty) throw Exception('The download finished without a local audio file.');
      result = downloaded.firstWhere((item) => item.youtubeVideoId == videoId, orElse: () => downloaded.first);
    } else {
      throw UnsupportedError('Playlist transfer downloads are supported on Windows and Android.');
    }
    await sourceRepository.saveSource(
      localPath: result.localPath,
      youtubeVideoId: videoId,
      method: sourceMethod,
      lastVerifiedAt: DateTime.now().toUtc(),
    );
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
