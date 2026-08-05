// lib/widgets/youtube/android_youtube.dart
// Fixes:
//  1. Stream title: MetadataCacheService.set() is always awaited BEFORE
//     onFileAdded fires, so TrackTile never races against a missing cache entry.
//  2. _startStreamUrl: metadata fetch failure now falls back gracefully.
//  3. Dialog width capped to screen width to prevent overflow on narrow screens.
//  4. All button rows (URL mode AND search mode) use Wrap so they never
//     overflow on narrow screens — buttons stack cleanly instead of clipping.
//  5. Search-results trailing icons use a Column so they don't overflow.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_audio_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_audio_flutter/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/services/import_service.dart';
import 'package:resonance/services/lyrics_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_download_result.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/core/youtube/android_download_event.dart';
import 'package:resonance/services/download_history_repository.dart';

class AndroidYoutubeDownloader {
  static const _method = MethodChannel('resonance/android_youtube');
  static const _event = EventChannel('resonance/android_youtube/events');

  Future<List<YoutubeTrack>> search(String query, {int limit = 10}) async {
    final raw = await _method.invokeMethod<String>('search', {'query': query, 'limit': limit.clamp(1, 10)});
    final decoded = jsonDecode(raw ?? '[]') as List;
    return decoded.map((e) => YoutubeTrack.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<YoutubeTrack> lookup(String url) async {
    final raw = await _method.invokeMethod<String>('getMetadata', {'url': url});
    if (raw == null || raw.isEmpty) throw StateError('Could not read this link');
    final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    data['url'] ??= url;
    return YoutubeTrack.fromJson(data);
  }

  Stream<String> download(String url, String outputDir) {
    _method.invokeMethod('download', {'url': url, 'outputDir': outputDir});
    return _event.receiveBroadcastStream().map((e) => e as String);
  }

  Future<String> _resolveOutputDir() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('download_directory');
    if (saved != null && saved != 'Default App Folder') return saved;
    final dir = await getExternalStorageDirectory();
    return dir?.path ?? (await getApplicationDocumentsDirectory()).path;
  }

  Future<String> get outputDir => _resolveOutputDir();

  Future<List<YoutubeDownloadResult>> downloadAudio(
    String url, {
    required void Function(double percentage, String status) onProgress,
    String? historyTitle,
    String? historyArtist,
  }) async {
    final pendingTracks =
        <String, ({String path, String? title, String? artist, String? coverPath, String? videoId})>{};
    final done = Completer<void>();
    late final StreamSubscription<String> subscription;
    subscription = download(url, await outputDir).listen(
      (event) {
        if (event.startsWith('progress:')) {
          final parts = event.split(':');
          final percentage = double.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0.0;
          onProgress(percentage, parts.length > 2 ? parts.sublist(2).join(':') : 'Downloading...');
        } else if (event.startsWith('track-json:') || event.startsWith('track:')) {
          final trackEvent = parseAndroidDownloadTrackEvent(event);
          if (trackEvent == null) return;
          final path = p.normalize(trackEvent.path);
          final candidateId = trackEvent.videoId;
          pendingTracks[path] = (
            path: path,
            title: trackEvent.title,
            artist: trackEvent.artist,
            coverPath: trackEvent.coverPath,
            videoId: candidateId != null && TrackSourceRepository.isValidYoutubeVideoId(candidateId)
                ? candidateId
                : TrackSourceRepository.videoIdFromUrlOrId(url),
          );
        } else if (event == 'done') {
          if (!done.isCompleted) done.complete();
        } else if (event.startsWith('error:')) {
          if (!done.isCompleted) {
            // yt-dlp can report a later playlist-item/extractor failure after
            // already emitting one or more complete local tracks. Preserve the
            // successful files; console/error text must not invalidate them.
            if (pendingTracks.isNotEmpty) {
              done.complete();
            } else {
              done.completeError(Exception(event.substring('error:'.length)));
            }
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) done.completeError(error, stackTrace);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    try {
      try {
        await done.future;
      } finally {
        await subscription.cancel();
      }
      if (pendingTracks.isEmpty) throw Exception('The download completed without an audio file');
      final results = <YoutubeDownloadResult>[];
      for (final track in pendingTracks.values) {
        onProgress(99, 'Converting audio...');
        final converted = await convertAndroidYoutubeAudioToMp3(
          track.path,
          title: track.title,
          artist: track.artist,
          coverPath: track.coverPath,
        );
        final result = YoutubeDownloadResult(
          localPath: converted,
          youtubeVideoId: track.videoId,
          title: track.title,
          artist: track.artist,
        );
        results.add(result);
        try {
          await const DownloadHistoryRepository().recordSuccess(
            source: track.videoId ?? url,
            localPath: converted,
            title: track.title ?? historyTitle,
            artist: track.artist ?? historyArtist,
          );
        } catch (historyError) {
          debugPrint('Could not save download history: $historyError');
        }
      }
      return results;
    } catch (error) {
      try {
        await const DownloadHistoryRepository().recordFailure(
          source: url,
          error: error,
          title: historyTitle,
          artist: historyArtist,
        );
      } catch (historyError) {
        debugPrint('Could not save failed download history: $historyError');
      }
      rethrow;
    }
  }
}

Future<String> convertAndroidYoutubeAudioToMp3(
  String inputPath, {
  String? title,
  String? artist,
  String? coverPath,
}) async {
  final finalPath = p.join(p.dirname(inputPath), '${p.basenameWithoutExtension(inputPath)}.mp3');
  final outputPath = p.equals(inputPath, finalPath) ? '$finalPath.resonance.mp3' : finalPath;
  final hasCover = coverPath != null && coverPath.isNotEmpty && await File(coverPath).exists();
  final args = <String>['-y', '-i', inputPath];
  if (hasCover) {
    args.addAll(['-i', coverPath, '-map', '0:a:0', '-map', '1:v:0']);
  } else {
    args.add('-vn');
  }
  args.addAll(['-map_metadata', '0']);
  if (title != null && title.isNotEmpty) args.addAll(['-metadata', 'title=$title']);
  if (artist != null && artist.isNotEmpty) args.addAll(['-metadata', 'artist=$artist']);
  if (hasCover) {
    args.addAll([
      '-metadata:s:v',
      'title=Album cover',
      '-metadata:s:v',
      'comment=Cover (front)',
      '-codec:v',
      'mjpeg',
      '-id3v2_version',
      '3',
    ]);
  }
  args.addAll(['-codec:a', 'libmp3lame', '-b:a', '192k', outputPath]);
  final session = await FFmpegKit.executeWithArguments(args);
  final rc = await session.getReturnCode();
  if (!ReturnCode.isSuccess(rc)) {
    final logs = await session.getAllLogsAsString();
    throw Exception('Audio conversion failed: ${(logs ?? '').trim()}');
  }
  final output = File(outputPath);
  if (!await output.exists() || await output.length() == 0) {
    throw Exception('Audio conversion produced no output file');
  }
  try {
    await File(inputPath).delete();
  } catch (_) {}
  if (hasCover) {
    try {
      await File(coverPath).delete();
    } catch (_) {}
  }
  if (outputPath != finalPath) await File(outputPath).rename(finalPath);
  return finalPath;
}

enum _DialogMode { input, searching, results, downloading }

class AndroidYoutube extends StatefulWidget {
  final Function(String newPath)? onFileAdded;
  const AndroidYoutube({super.key, this.onFileAdded});

  @override
  State<AndroidYoutube> createState() => _AndroidYoutubeState();
}

class _AndroidYoutubeState extends State<AndroidYoutube> {
  final _urlController = TextEditingController();
  final _searchController = TextEditingController();
  final _downloader = AndroidYoutubeDownloader();

  _DialogMode _mode = _DialogMode.input;
  bool _isUrlMode = true;
  List<YoutubeTrack> _searchResults = [];
  double _downloadPercentage = 0.0;
  String _statusMessage = '';

  @override
  void dispose() {
    _urlController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _startDownload(String url, {YoutubeTrack? track}) async {
    setState(() {
      _mode = _DialogMode.downloading;
      _downloadPercentage = 0.0;
      _statusMessage = 'Analyzing URL...';
    });
    try {
      final tracks = await _downloader.downloadAudio(
        url,
        historyTitle: track?.title,
        historyArtist: track?.artist,
        onProgress: (percentage, status) {
          if (mounted) {
            setState(() {
              _downloadPercentage = percentage;
              _statusMessage = status;
            });
          }
        },
      );
      for (final download in tracks) {
        if (download.youtubeVideoId != null) {
          await const TrackSourceRepository().saveSource(
            localPath: download.localPath,
            youtubeVideoId: download.youtubeVideoId!,
            method: TrackSourceMethod.downloadedByResonance,
            lastVerifiedAt: DateTime.now().toUtc(),
          );
        }
        await ImportService.importFiles([download.localPath], (newPath) => widget.onFileAdded?.call(newPath));
        if (track != null) {
          unawaited(
            const LyricsService().prefetch(
              trackId: download.localPath,
              title: track.title,
              artist: track.artist,
              duration: track.durationSeconds == null ? null : Duration(seconds: track.durationSeconds!),
            ),
          );
        }
      }
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.greenAccent),
                SizedBox(width: 8),
                Text(
                  'Download & Import Complete!',
                  style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _mode = _DialogMode.input);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $error'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  Future<void> _startStream(String url, {required String title, required String artist, String? thumbnailUrl}) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final snackBarBackground = Theme.of(context).colorScheme.surfaceContainerHigh;

    await MetadataCacheService.set(url, title, artist, artworkUrl: thumbnailUrl);
    final youtubeVideoId = TrackSourceRepository.videoIdFromUrlOrId(url);
    if (youtubeVideoId != null) {
      await const TrackSourceRepository().saveSource(
        localPath: url,
        youtubeVideoId: youtubeVideoId,
        method: TrackSourceMethod.manuallySelected,
      );
    }

    final playlistContent = await FileService().readTextFromFile();
    final updatedContent = '${playlistContent.trim()}\n$url\n';
    await FileService().writeTextToFile(updatedContent, append: false);

    widget.onFileAdded?.call(url);

    if (mounted) {
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.sensors_rounded, color: Colors.greenAccent),
              SizedBox(width: 8),
              Text(
                'Stream URL Added to Playlist!',
                style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          backgroundColor: snackBarBackground,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _startStreamUrl(String url) async {
    Tooltip.dismissAllToolTips();
    if (_mode == _DialogMode.searching || _mode == _DialogMode.downloading) return;
    setState(() {
      _mode = _DialogMode.searching;
      _statusMessage = 'Extracting Video Info...';
    });

    String title;
    String artist;
    String? thumbnailUrl;

    try {
      const channel = MethodChannel('resonance/android_youtube');
      final raw = await channel.invokeMethod<String>('getMetadata', {'url': url});
      final data = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      title = (data['title'] as String?)?.trim().isNotEmpty == true ? data['title'] as String : _titleFromUrl(url);
      artist = (data['artist'] as String?)?.trim().isNotEmpty == true ? data['artist'] as String : 'YouTube';
      thumbnailUrl = data['thumbnail']?.toString();
    } catch (_) {
      title = _titleFromUrl(url);
      artist = 'YouTube';
    }

    if (!mounted) return;
    await _startStream(url, title: title, artist: artist, thumbnailUrl: thumbnailUrl);
  }

  String _titleFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host.contains('youtu.be')) {
        return uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'YouTube Stream';
      }
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
      if (uri.pathSegments.isNotEmpty) return uri.pathSegments.last;
    } catch (_) {}
    return 'YouTube Stream';
  }

  Future<void> _runSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _mode = _DialogMode.searching;
      _searchResults = [];
    });
    try {
      final results = await _downloader.search(query);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _mode = _DialogMode.results;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _mode = _DialogMode.input);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: $e'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final maxW = (screenWidth - 32).clamp(0.0, 480.0);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 48),
          child: SizedBox(
            width: maxW,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.video_library_rounded, color: theme.colorScheme.primary, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'YouTube · Stream or Download',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  switch (_mode) {
                    _DialogMode.input => _buildInputBody(theme),
                    _DialogMode.searching => _buildSearchingBody(theme),
                    _DialogMode.results => _buildResultsBody(theme),
                    _DialogMode.downloading => _buildDownloadingBody(theme),
                  },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputBody(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Mode toggle — shrink to fit narrow screens
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('URL'), icon: Icon(Icons.link_rounded)),
              ButtonSegment(value: false, label: Text('Search'), icon: Icon(Icons.search_rounded)),
            ],
            selected: {_isUrlMode},
            onSelectionChanged: (s) => setState(() => _isUrlMode = s.first),
            style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          ),
        ),
        const SizedBox(height: 14),
        if (_isUrlMode) ...[
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: 'Video / Playlist URL',
              hintText: 'https://youtu.be/...',
              prefixIcon: const Icon(Icons.link_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              filled: true,
            ),
            onSubmitted: (_) {
              final url = _urlController.text.trim();
              if (url.isNotEmpty) _startDownload(url);
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    side: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)),
                    foregroundColor: Theme.of(context).colorScheme.primary,
                  ),
                  onPressed: () {
                    final url = _urlController.text.trim();
                    if (url.isNotEmpty) _startStreamUrl(url);
                  },
                  icon: const Icon(Icons.sensors_rounded, size: 18),
                  label: const FittedBox(child: Text('Stream')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    final url = _urlController.text.trim();
                    if (url.isNotEmpty) _startDownload(url);
                  },
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const FittedBox(child: Text('Download')),
                ),
              ),
            ],
          ),
        ] else ...[
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              labelText: 'Search YouTube',
              hintText: 'Artist, song name...',
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              filled: true,
            ),
            onSubmitted: (_) => _runSearch(),
          ),
          const SizedBox(height: 16),
          // FIX: Search mode also uses Wrap (was a plain Row that could overflow).
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                onPressed: _runSearch,
                icon: const Icon(Icons.search_rounded, size: 18),
                label: const Text('Search'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSearchingBody(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _isUrlMode ? 'Extracting info...' : 'Searching for "${_searchController.text}"...',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsBody(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _mode = _DialogMode.input)),
            Expanded(
              child: Text(
                'Results for "${_searchController.text}"',
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_searchResults.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: Text('No results found.')),
          )
        else
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              itemCount: _searchResults.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final result = _searchResults[i];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  leading: CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(color: theme.colorScheme.onPrimaryContainer, fontWeight: FontWeight.bold),
                    ),
                  ),
                  title: Text(
                    result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(
                    [result.artist, if (result.formattedDuration.isNotEmpty) result.formattedDuration].join(' · '),
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                  ),
                  trailing: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.sensors_rounded, color: theme.colorScheme.primary, size: 20),
                          tooltip: 'Stream',
                          onPressed: () => _startStream(
                            result.url,
                            title: result.title,
                            artist: result.artist,
                            thumbnailUrl: result.thumbnailUrl,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.download_rounded, color: theme.colorScheme.primary, size: 20),
                          tooltip: 'Download',
                          onPressed: () => _startDownload(result.url, track: result),
                        ),
                      ),
                    ],
                  ),
                  onTap: () => _startStream(
                    result.url,
                    title: result.title,
                    artist: result.artist,
                    thumbnailUrl: result.thumbnailUrl,
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ),
      ],
    );
  }

  Widget _buildDownloadingBody(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_statusMessage, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _downloadPercentage / 100.0,
              minHeight: 10,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${_downloadPercentage.toStringAsFixed(1)}%',
              style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
