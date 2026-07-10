import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_download_result.dart';
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

  Future<YoutubeDownloadResult> downloadVideo(
    String videoId, {
    required void Function(double percentage, String status) onProgress,
  }) async {
    if (!TrackSourceRepository.isValidYoutubeVideoId(videoId)) {
      throw ArgumentError.value(videoId, 'videoId', 'Invalid YouTube video ID');
    }
    final url = TrackSourceRepository.canonicalUrlFor(videoId);
    YoutubeDownloadResult result;
    if (Platform.isWindows) {
      final downloader = windows_youtube.MediaDownloader();
      await downloader.initBinaries();
      final downloaded = <YoutubeDownloadResult>[];
      await downloader.downloadAudio(
        url: url,
        onProgress: onProgress,
        onTrackDownloaded: (path, downloadedVideoId) async {
          downloaded.add(YoutubeDownloadResult(localPath: path, youtubeVideoId: downloadedVideoId ?? videoId));
        },
      );
      if (downloaded.isEmpty) throw Exception('The download finished without a local audio file.');
      result = downloaded.firstWhere((item) => item.youtubeVideoId == videoId, orElse: () => downloaded.first);
    } else if (Platform.isAndroid) {
      final downloaded = await android_youtube.AndroidYoutubeDownloader().downloadAudio(url, onProgress: onProgress);
      if (downloaded.isEmpty) throw Exception('The download finished without a local audio file.');
      result = downloaded.firstWhere((item) => item.youtubeVideoId == videoId, orElse: () => downloaded.first);
    } else {
      throw UnsupportedError('Playlist transfer downloads are supported on Windows and Android.');
    }
    await sourceRepository.saveSource(
      localPath: result.localPath,
      youtubeVideoId: videoId,
      method: TrackSourceMethod.importedFromQrTransfer,
      lastVerifiedAt: DateTime.now().toUtc(),
    );
    return YoutubeDownloadResult(
      localPath: result.localPath,
      youtubeVideoId: videoId,
      title: result.title,
      artist: result.artist,
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
}
