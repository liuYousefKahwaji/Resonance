import 'dart:async';

import 'dart:convert';

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:path_provider/path_provider.dart';

import 'package:path/path.dart' as p;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonance/services/import_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/download_history_repository.dart';
import 'package:resonance/core/youtube/windows_process_output.dart';

bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

// ─── Binary / downloader logic ────────────────────────────────────────────────

class MediaDownloader {
  static const _audioExtensions = {'mp3', 'wav', 'm4a', 'ogg', 'opus', 'webm', 'aac', 'flac'};

  Future<String> get binDirPath async {
    return p.join(p.dirname(Platform.resolvedExecutable), 'bin');
  }

  Future<void> initBinaries() async {
    final binDir = Directory(await binDirPath);

    for (final exe in ['yt-dlp.exe', 'ffmpeg.exe', 'deno.exe']) {
      final exeFile = File(p.join(binDir.path, exe));
      if (!await exeFile.exists()) {
        throw StateError('Missing Windows downloader tool: ${exeFile.path}');
      }
    }
  }

  Future<List<YoutubeTrack>> search(String query) async {
    final binDir = await binDirPath;

    final ytDlpPath = p.join(binDir, 'yt-dlp.exe');

    final denoPath = p.join(binDir, 'deno.exe');

    final process = await Process.start(
      ytDlpPath,
      [
        '--js-runtimes',
        'deno:$denoPath',

        '--force-ipv4',

        ...windowsYtDlpUtf8Arguments,

        '--flat-playlist',

        '--dump-json',

        '--no-download',

        'ytsearch10:$query',
      ],
      environment: windowsYtDlpUtf8Environment,
      includeParentEnvironment: true,
    );

    // Drain stderr to prevent pipe deadlock

    final stderrDone = process.stderr.drain<void>();

    // Collect all stdout lines then parse — avoids async-forEach gotcha

    final stdout = await collectWindowsProcessOutput(process.stdout);

    final lines = const LineSplitter().convert(stdout);

    await process.exitCode;

    await stderrDone;

    final results = <YoutubeTrack>[];

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;

      try {
        final json = jsonDecode(trimmed) as Map<String, dynamic>;

        results.add(YoutubeTrack.fromJson(json));
      } catch (_) {}
    }

    return results;
  }

  Future<YoutubeTrack> lookup(String url) async {
    final binDir = await binDirPath;
    final process = await Process.start(
      p.join(binDir, 'yt-dlp.exe'),
      [
        '--js-runtimes',
        'deno:${p.join(binDir, 'deno.exe')}',
        '--force-ipv4',
        ...windowsYtDlpUtf8Arguments,
        '--dump-single-json',
        '--no-download',
        '--no-playlist',
        url,
      ],
      environment: windowsYtDlpUtf8Environment,
      includeParentEnvironment: true,
    );
    final stderrFuture = collectWindowsProcessOutput(process.stderr);
    final stdoutFuture = collectWindowsProcessOutput(process.stdout);
    final exitCode = await process.exitCode;
    final stdout = await stdoutFuture;
    final stderr = await stderrFuture;
    if (exitCode != 0 || stdout.trim().isEmpty) {
      throw StateError(stderr.trim().isEmpty ? 'Could not read this link' : stderr.trim());
    }
    return YoutubeTrack.fromJson(jsonDecode(stdout) as Map<String, dynamic>);
  }

  /// Downloads audio for [url], reporting progress via callbacks.

  ///

  /// BUG FIX 1 — Progress stuck at 0%:

  ///   yt-dlp writes [download] XX.X% progress lines to STDERR, not stdout.

  ///   Previously stderr was drained silently so onProgress never fired.

  ///   Now stderr is read concurrently via a listen() for progress callbacks,

  ///   while stdout is read for --print filepath output.

  ///

  /// BUG FIX 2 — Last track not imported:

  ///   Stream.forEach(async callback) does NOT await the futures — it fires

  ///   and forgets each one. Fixed by collecting stdout into a List via

  ///   .toList(), then iterating sequentially with a plain for loop where

  ///   every await onTrackDownloaded() is properly awaited before the next.

  Future<void> downloadAudio({
    required String url,

    required Function(double percentage, String status) onProgress,

    required Function(String filePath, String? youtubeVideoId) onTrackDownloaded,
    String? historyTitle,
    String? historyArtist,
  }) async {
    final binDir = await binDirPath;

    final ytDlpPath = p.join(binDir, 'yt-dlp.exe');

    final ffmpegPath = p.join(binDir, 'ffmpeg.exe');

    final prefs = await SharedPreferences.getInstance();

    final savedPath = prefs.getString('download_directory');

    String targetDir;

    if (savedPath != null && savedPath != 'Default App Folder') {
      targetDir = savedPath;
    } else if (_isDesktop) {
      final downloadDir = await getDownloadsDirectory();

      targetDir = downloadDir?.path ?? (await getApplicationSupportDirectory()).path;
    } else {
      targetDir = (await getApplicationSupportDirectory()).path;
    }

    final outputTemplate = p.join(targetDir, '%(title)s.%(ext)s');
    final targetDirectory = Directory(targetDir);
    await targetDirectory.create(recursive: true);
    final downloadStartedAt = DateTime.now().subtract(const Duration(seconds: 2));

    const int maxAttempts = 3;

    int attempt = 0;

    while (attempt < maxAttempts) {
      attempt++;

      if (attempt > 1) {
        onProgress(0.0, 'Connection dropped. Retrying ($attempt/$maxAttempts)...');

        await Future.delayed(Duration(seconds: attempt * 2));
      }

      try {
        final process = await Process.start(
          ytDlpPath,
          [
            '--ffmpeg-location',
            ffmpegPath,

            '--js-runtimes',
            'deno:${p.join(binDir, 'deno.exe')}',

            '--force-ipv4',

            ...windowsYtDlpUtf8Arguments,

            '--format',
            'bestaudio[has_drm!=true]/best[has_drm!=true]',

            '--concurrent-fragments',
            '4',

            '--windows-filenames',
            '-x',

            '--audio-format',
            'mp3',

            '--embed-metadata',

            '--embed-thumbnail',

            '--convert-thumbnails',
            'jpg',

            // --progress forces progress output even when stderr is not a TTY
            // (i.e. when piped). Without this yt-dlp silently suppresses all
            // [download] XX.X% lines, leaving the bar stuck at 0%.
            '--progress',

            '--newline',

            '--no-colors',

            '--progress-delta',
            '0.2',

            '--progress-template',
            'download:resonance_progress:%(progress._percent_str)s',

            '--yes-playlist',

            '--print',
            'after_move:%(filepath)s|%(id)s',

            '-o',
            outputTemplate,

            url,
          ],
          environment: windowsYtDlpUtf8Environment,
          includeParentEnvironment: true,
        );

        final progressRegex = RegExp(r'\[download\]\s+(\d+(?:\.\d+)?)%');
        final templateProgressRegex = RegExp(r'resonance_progress:\s*(\d+(?:\.\d+)?)%');
        final fragRegex = RegExp(r'\(frag\s+(\d+)/(\d+)\)');
        final playlistItemRegex = RegExp(r'\[download\]\s+Downloading item\s+(\d+)\s+of\s+(\d+)');
        final alreadyDownloadedRegex = RegExp(r'\[download\]\s+(.+?)\s+has already been downloaded');

        int currentItem = 1;
        int totalItems = 1;
        final outputLines = <String>[];
        final printedPaths = <String>[];

        void handleLine(String line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return;
          outputLines.add(trimmed);

          final templateMatch = templateProgressRegex.firstMatch(trimmed);
          if (templateMatch != null) {
            final percent = double.tryParse(templateMatch.group(1) ?? '0') ?? 0.0;
            final prefix = totalItems > 1 ? '($currentItem/$totalItems) ' : '';
            onProgress(percent.clamp(0.0, 100.0), '${prefix}Downloading... ${percent.toStringAsFixed(1)}%');
            return;
          }

          final itemMatch = playlistItemRegex.firstMatch(trimmed);
          if (itemMatch != null) {
            currentItem = int.tryParse(itemMatch.group(1) ?? '1') ?? 1;
            totalItems = int.tryParse(itemMatch.group(2) ?? '1') ?? 1;
            return;
          }

          if (trimmed.contains('[download]') && trimmed.contains('%')) {
            double? percent;
            final fragMatch = fragRegex.firstMatch(trimmed);
            if (fragMatch != null) {
              final fragIdx = int.tryParse(fragMatch.group(1) ?? '0') ?? 0;
              final fragTotal = int.tryParse(fragMatch.group(2) ?? '0') ?? 0;
              if (fragTotal > 0) percent = (fragIdx / fragTotal) * 100.0;
            }

            if (percent == null || percent == 0.0) {
              final match = progressRegex.firstMatch(trimmed);
              if (match != null) {
                percent = double.tryParse(match.group(1) ?? '0');
              }
            }

            if (percent != null) {
              final prefix = totalItems > 1 ? '($currentItem/$totalItems) ' : '';
              onProgress(percent.clamp(0.0, 100.0), '${prefix}Downloading... ${percent.toStringAsFixed(1)}%');
            }
          } else if (trimmed.contains('[ExtractAudio]') ||
              trimmed.contains('[Merger]') ||
              trimmed.contains('[MoveFiles]')) {
            final prefix = totalItems > 1 ? '($currentItem/$totalItems) ' : '';
            onProgress(99.0, '${prefix}Processing audio...');
          }
        }

        final stdoutTextFuture = collectWindowsProcessOutput(process.stdout);
        final stderrDone = decodeWindowsProcessLines(process.stderr).listen(handleLine).asFuture<void>();

        // Keep stdout as raw bytes until the process exits. This avoids a
        // strict UTF-8 stream decoder aborting on a Windows code-page byte
        // before the filesystem fallback can recover the real Unicode path.
        final stdoutText = await stdoutTextFuture;
        for (final line in const LineSplitter().convert(stdoutText)) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          if (trimmed.contains('resonance_progress:') ||
              trimmed.contains('[download]') ||
              trimmed.contains('[ExtractAudio]') ||
              trimmed.contains('[Merger]') ||
              trimmed.contains('[MoveFiles]')) {
            handleLine(trimmed);
          } else {
            printedPaths.add(trimmed);
          }
        }

        // ── Collect ALL stdout lines first, then process sequentially ──

        // stdout carries only the --print after_move:%(filepath)s output.

        // Using .toList() ensures the stream is fully consumed before we

        // iterate, and the plain for loop below properly awaits each

        // onTrackDownloaded call — fixing the last-track race condition.

        await stderrDone;

        // ── Process filepath lines sequentially, fully awaited ──

        final processedPaths = <String>{};
        var importedCount = 0;

        Future<void> importPath(String path, {String? youtubeVideoId}) async {
          final normalized = p.normalize(path);
          if (processedPaths.add(normalized) && await File(normalized).exists()) {
            await onTrackDownloaded(normalized, youtubeVideoId);
            try {
              await const DownloadHistoryRepository().recordSuccess(
                source: youtubeVideoId ?? url,
                localPath: normalized,
                title: historyTitle,
                artist: historyArtist,
              );
            } catch (historyError) {
              debugPrint('Could not save download history: $historyError');
            }
            importedCount++;
          }
        }

        for (final line in [...printedPaths, ...outputLines]) {
          final trimmed = line.trim();

          if (trimmed.isEmpty) continue;

          if (trimmed.contains('has already been downloaded')) {
            final match = alreadyDownloadedRegex.firstMatch(trimmed);

            if (match != null) {
              final path = p.normalize(match.group(1)!);

              final inputVideoId = TrackSourceRepository.videoIdFromUrlOrId(url);
              await importPath(path, youtubeVideoId: inputVideoId);
              await importPath(p.setExtension(path, '.mp3'), youtubeVideoId: inputVideoId);
            }
          } else if (!trimmed.contains('[')) {
            // --print after_move:%(filepath)s line
            final separator = trimmed.lastIndexOf('|');
            final candidateId = separator < 0 ? null : trimmed.substring(separator + 1);
            final candidatePath = separator < 0 ? trimmed : trimmed.substring(0, separator);
            if (_looksLikeAudioPath(candidatePath)) {
              final cleanPath = p.normalize(candidatePath);
              await Future.delayed(const Duration(milliseconds: 150));
              await importPath(
                cleanPath,
                youtubeVideoId: candidateId != null && TrackSourceRepository.isValidYoutubeVideoId(candidateId)
                    ? candidateId
                    : TrackSourceRepository.videoIdFromUrlOrId(url),
              );
            }
          }
        }

        final exitCode = await process.exitCode;

        if (exitCode != 0) {
          throw Exception('yt-dlp exited with code $exitCode');
        }

        // The printed after_move path is authoritative and avoids scanning a
        // potentially huge Downloads folder twice. Only scan when the console
        // path could not be imported (for example due to a code-page mismatch).
        if (importedCount == 0) {
          await for (final entity in targetDirectory.list()) {
            if (entity is! File || !_looksLikeAudioPath(entity.path)) continue;
            final modified = await entity.lastModified();
            if (!modified.isBefore(downloadStartedAt)) {
              await importPath(entity.path, youtubeVideoId: TrackSourceRepository.videoIdFromUrlOrId(url));
            }
          }
        }
        if (importedCount == 0) {
          throw Exception('Download finished, but no audio file could be imported');
        }

        return;
      } catch (e) {
        debugPrint('Download failure on attempt $attempt: $e');

        if (attempt >= maxAttempts) {
          try {
            await const DownloadHistoryRepository().recordFailure(
              source: url,
              error: e,
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
  }

  bool _looksLikeAudioPath(String value) {
    final extension = p.extension(value).replaceFirst('.', '').toLowerCase();
    return _audioExtensions.contains(extension);
  }
}

// ─── UI ───────────────────────────────────────────────────────────────────────

enum _DialogMode { input, searching, results, downloading }

class WindowsYoutube extends StatefulWidget {
  final Function(String newPath)? onFileAdded;

  const WindowsYoutube({super.key, this.onFileAdded});

  @override
  State<WindowsYoutube> createState() => _WindowsYoutubeState();
}

class _WindowsYoutubeState extends State<WindowsYoutube> {
  final _urlController = TextEditingController();

  final _searchController = TextEditingController();

  final _downloader = MediaDownloader();

  _DialogMode _mode = _DialogMode.input;

  bool _isUrlMode = true;

  List<YoutubeTrack> _searchResults = [];

  double _downloadPercentage = 0.0;

  String _statusMessage = '';

  @override
  void initState() {
    super.initState();

    _downloader.initBinaries();
  }

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
      await _downloader.downloadAudio(
        url: url,
        historyTitle: track?.title,
        historyArtist: track?.artist,

        onProgress: (percent, status) {
          if (mounted) {
            setState(() {
              _downloadPercentage = percent;

              _statusMessage = status;
            });
          }
        },

        onTrackDownloaded: (filePath, youtubeVideoId) async {
          if (youtubeVideoId != null) {
            await const TrackSourceRepository().saveSource(
              localPath: filePath,
              youtubeVideoId: youtubeVideoId,
              method: TrackSourceMethod.downloadedByResonance,
              lastVerifiedAt: DateTime.now().toUtc(),
            );
          }
          await ImportService.importFiles([filePath], (newPath) {
            widget.onFileAdded?.call(newPath);
          });
        },
      );

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
    } catch (e) {
      if (mounted) {
        setState(() => _mode = _DialogMode.input);

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Theme.of(context).colorScheme.error));
      }
    }
  }

  Future<void> _startStream(String url, {String? title, String? artist}) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final snackBarBackground = Theme.of(context).colorScheme.surfaceContainerHigh;
    final targetTitle = title ?? 'Streaming Track';
    final targetArtist = artist ?? 'YouTube';

    await MetadataCacheService.set(url, targetTitle, targetArtist);
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

  Future<({String title, String artist})> _fetchMetadata(String url) async {
    try {
      final binDir = await _downloader.binDirPath;
      final ytDlpPath = p.join(binDir, 'yt-dlp.exe');
      final denoPath = p.join(binDir, 'deno.exe');

      final process = await Process.start(
        ytDlpPath,
        [
          '--js-runtimes',
          'deno:$denoPath',
          '--force-ipv4',
          ...windowsYtDlpUtf8Arguments,
          '--dump-json',
          '--no-download',
          url,
        ],
        environment: windowsYtDlpUtf8Environment,
        includeParentEnvironment: true,
      );

      final stderrDone = process.stderr.drain<void>();
      final stdout = await collectWindowsProcessOutput(process.stdout);
      final lines = const LineSplitter().convert(stdout);
      await process.exitCode;
      await stderrDone;

      if (lines.isNotEmpty) {
        final json = jsonDecode(lines.first) as Map<String, dynamic>;
        return (
          title: json['title'] as String? ?? 'Streaming Track',
          artist: json['uploader'] as String? ?? json['channel'] as String? ?? 'YouTube',
        );
      }
    } catch (_) {}
    return (title: 'Streaming Track', artist: 'YouTube');
  }

  Future<void> _startStreamUrl(String url) async {
    Tooltip.dismissAllToolTips();
    if (_mode == _DialogMode.searching || _mode == _DialogMode.downloading) {
      return;
    }
    setState(() {
      _mode = _DialogMode.searching;
      _statusMessage = 'Extracting Video Info...';
    });

    final meta = await _fetchMetadata(url);
    if (!mounted) return;
    await _startStream(url, title: meta.title, artist: meta.artist);
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
          SnackBar(
            content: Text('Search failed: ${e.toString()}'),

            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),

        curve: Curves.easeOut,

        child: Container(
          width: 480,

          padding: const EdgeInsets.all(24.0),

          child: Column(
            mainAxisSize: MainAxisSize.min,

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              Row(
                children: [
                  Icon(Icons.video_library_rounded, color: theme.colorScheme.primary, size: 28),

                  const SizedBox(width: 12),

                  Text(
                    'YouTube · Stream or Download',
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
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
    );
  }

  Widget _buildInputBody(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,

      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('URL'), icon: Icon(Icons.link_rounded)),

            ButtonSegment(value: false, label: Text('Search'), icon: Icon(Icons.search_rounded)),
          ],

          selected: {_isUrlMode},

          onSelectionChanged: (s) => setState(() => _isUrlMode = s.first),

          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ),

        const SizedBox(height: 16),

        if (_isUrlMode) ...[
          TextField(
            controller: _urlController,

            autofocus: true,

            decoration: InputDecoration(
              labelText: 'Video, Track, or Playlist URL',

              hintText: 'https://music.youtube.com/...',

              prefixIcon: const Icon(Icons.link_rounded),

              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),

              filled: true,
            ),

            onSubmitted: (_) {
              if (_urlController.text.trim().isNotEmpty) {
                _startDownload(_urlController.text.trim());
              }
            },
          ),

          const SizedBox(height: 20),

          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),

              const SizedBox(width: 8),

              // ── Stream button ──────────────────────────────────────
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  side: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)),
                  foregroundColor: Theme.of(context).colorScheme.primary,
                ),
                onPressed: () {
                  final url = _urlController.text.trim();
                  if (url.isNotEmpty) _startStreamUrl(url);
                },
                icon: const Icon(Icons.sensors_rounded, size: 18),
                label: const Text('Stream'),
              ),

              const SizedBox(width: 8),

              // ── Download button ────────────────────────────────────
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  final url = _urlController.text.trim();
                  if (url.isNotEmpty) _startDownload(url);
                },
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Download'),
              ),
            ],
          ),
        ] else ...[
          TextField(
            controller: _searchController,

            autofocus: true,

            decoration: InputDecoration(
              labelText: 'Search YouTube',

              hintText: 'Artist, song name, album...',

              prefixIcon: const Icon(Icons.search_rounded),

              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),

              filled: true,
            ),

            onSubmitted: (_) => _runSearch(),
          ),

          const SizedBox(height: 20),

          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),

              const SizedBox(width: 12),

              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),

                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),

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

            Text('Searching for "${_searchController.text}"...', style: theme.textTheme.bodyMedium),
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
            IconButton(
              icon: const Icon(Icons.arrow_back),

              onPressed: () => setState(() => _mode = _DialogMode.input),

              tooltip: 'Back',
            ),

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
          ListView.separated(
            shrinkWrap: true,

            physics: const NeverScrollableScrollPhysics(),

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
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Stream button ──────────────────────────────────
                    IconButton(
                      icon: Icon(Icons.sensors_rounded, color: theme.colorScheme.primary),
                      tooltip: 'Stream Now',
                      onPressed: () => _startStream(result.url, title: result.title, artist: result.artist),
                    ),
                    // ── Download button ────────────────────────────────
                    IconButton(
                      icon: Icon(Icons.download_rounded, color: theme.colorScheme.primary),
                      tooltip: 'Download',
                      onPressed: () => _startDownload(result.url, track: result),
                    ),
                  ],
                ),

                onTap: () => _startStream(result.url, title: result.title, artist: result.artist),
              );
            },
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
