import 'dart:async';

import 'dart:convert';

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart' show rootBundle;

import 'package:path_provider/path_provider.dart';

import 'package:path/path.dart' as p;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonance/services/import_service.dart';

bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

// ─── Search result model ──────────────────────────────────────────────────────

class YtSearchResult {
  final String title;

  final String uploader;

  final String url;

  final int? durationSeconds;

  const YtSearchResult({required this.title, required this.uploader, required this.url, this.durationSeconds});

  String get formattedDuration {
    if (durationSeconds == null) return '';

    final m = durationSeconds! ~/ 60;

    final s = durationSeconds! % 60;

    return '$m:${s.toString().padLeft(2, '0')}';
  }

  factory YtSearchResult.fromJson(Map<String, dynamic> json) {
    return YtSearchResult(
      title: json['title'] as String? ?? 'Unknown',

      uploader: json['uploader'] as String? ?? json['channel'] as String? ?? 'Unknown',

      url: json['webpage_url'] as String? ?? json['url'] as String? ?? '',

      durationSeconds: (json['duration'] as num?)?.toInt(),
    );
  }
}

// ─── Binary / downloader logic ────────────────────────────────────────────────

class MediaDownloader {
  Future<String> get _binDirPath async {
    final supportDir = await getApplicationSupportDirectory();

    return p.join(supportDir.path, 'bin');
  }

  Future<void> initBinaries() async {
    final binDir = Directory(await _binDirPath);

    if (!await binDir.exists()) await binDir.create(recursive: true);

    for (final exe in ['yt-dlp.exe', 'ffmpeg.exe', 'ffprobe.exe', 'deno.exe']) {
      final exeFile = File(p.join(binDir.path, exe));

      if (!await exeFile.exists()) {
        final data = await rootBundle.load('assets/bin/$exe');

        await exeFile.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      }
    }
  }

  Future<List<YtSearchResult>> search(String query) async {
    final binDir = await _binDirPath;

    final ytDlpPath = p.join(binDir, 'yt-dlp.exe');

    final denoPath = p.join(binDir, 'deno.exe');

    final process = await Process.start(ytDlpPath, [
      '--js-runtimes',
      'deno:$denoPath',

      '--flat-playlist',

      '--dump-json',

      '--no-download',

      'ytsearch5:$query',
    ]);

    // Drain stderr to prevent pipe deadlock

    process.stderr.drain<List<int>>();

    // Collect all stdout lines then parse — avoids async-forEach gotcha

    final lines = await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).toList();

    await process.exitCode;

    final results = <YtSearchResult>[];

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;

      try {
        final json = jsonDecode(trimmed) as Map<String, dynamic>;

        results.add(YtSearchResult.fromJson(json));
      } catch (_) {}
    }

    return results;
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

    required Function(String filePath) onTrackDownloaded,
  }) async {
    final binDir = await _binDirPath;

    final ytDlpPath = p.join(binDir, 'yt-dlp.exe');

    final ffmpegPath = p.join(binDir, 'ffmpeg.exe');

    final denoPath = p.join(binDir, 'deno.exe');

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

    const int maxAttempts = 3;

    int attempt = 0;

    while (attempt < maxAttempts) {
      attempt++;

      if (attempt > 1) {
        onProgress(0.0, 'Connection dropped. Retrying ($attempt/$maxAttempts)...');

        await Future.delayed(Duration(seconds: attempt * 2));
      }

      try {
        final process = await Process.start(ytDlpPath, [
          '--ffmpeg-location',
          ffmpegPath,

          '--js-runtimes',
          'deno:$denoPath',

          '-x',

          '--audio-format',
          'mp3',

          '--embed-metadata',

          '--newline',

          '--yes-playlist',

          '--print',
          'after_move:%(filepath)s',

          '-o',
          outputTemplate,

          url,
        ]);

        final progressRegex = RegExp(r'\[download\]\s+(\d+\.\d+)%');

        final playlistItemRegex = RegExp(r'\[download\]\s+Downloading item\s+(\d+)\s+of\s+(\d+)');

        int currentItem = 1;

        int totalItems = 1;

        // ── Read STDERR for progress (yt-dlp writes progress there, not stdout) ──

        // Run concurrently with stdout reading — must NOT be awaited here.

        final stderrDone = process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
          final trimmed = line.trim();

          if (playlistItemRegex.hasMatch(trimmed)) {
            final match = playlistItemRegex.firstMatch(trimmed)!;

            currentItem = int.tryParse(match.group(1) ?? '1') ?? 1;

            totalItems = int.tryParse(match.group(2) ?? '1') ?? 1;
          } else if (trimmed.contains('[download]') && trimmed.contains('%')) {
            final match = progressRegex.firstMatch(trimmed);

            if (match != null) {
              final percent = double.tryParse(match.group(1) ?? '0') ?? 0.0;

              final prefix = totalItems > 1 ? '($currentItem/$totalItems) ' : '';

              onProgress(percent, '${prefix}Downloading... ${percent.toStringAsFixed(1)}%');
            }
          } else if (trimmed.contains('[ExtractAudio]')) {
            final prefix = totalItems > 1 ? '($currentItem/$totalItems) ' : '';

            onProgress(99.0, '${prefix}Processing audio...');
          }
        }).asFuture<void>();

        // ── Collect ALL stdout lines first, then process sequentially ──

        // stdout carries only the --print after_move:%(filepath)s output.

        // Using .toList() ensures the stream is fully consumed before we

        // iterate, and the plain for loop below properly awaits each

        // onTrackDownloaded call — fixing the last-track race condition.

        final stdoutLines = await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).toList();

        // Wait for stderr listener to drain fully before checking exit code

        await stderrDone;

        // ── Process filepath lines sequentially, fully awaited ──

        final processedPaths = <String>{};

        for (final line in stdoutLines) {
          final trimmed = line.trim();

          if (trimmed.isEmpty) continue;

          if (trimmed.contains('has already been downloaded')) {
            final match = RegExp(r'\[download\]\s+(.*\.mp3)\s+has already been downloaded').firstMatch(trimmed);

            if (match != null) {
              final path = p.normalize(match.group(1)!);

              if (!processedPaths.contains(path) && await File(path).exists()) {
                processedPaths.add(path);

                await onTrackDownloaded(path);
              }
            }
          } else if (trimmed.endsWith('.mp3') && !trimmed.contains('[')) {
            // --print after_move:%(filepath)s line

            final cleanPath = p.normalize(trimmed);

            if (!processedPaths.contains(cleanPath)) {
              processedPaths.add(cleanPath);

              await Future.delayed(const Duration(milliseconds: 300));

              if (await File(cleanPath).exists()) {
                await onTrackDownloaded(cleanPath);
              }
            }
          }
        }

        final exitCode = await process.exitCode;

        if (exitCode != 0) {
          throw Exception('yt-dlp exited with code $exitCode');
        }

        return;
      } catch (e) {
        debugPrint('Download failure on attempt $attempt: $e');

        if (attempt >= maxAttempts) rethrow;
      }
    }
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

  List<YtSearchResult> _searchResults = [];

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

  Future<void> _startDownload(String url) async {
    setState(() {
      _mode = _DialogMode.downloading;

      _downloadPercentage = 0.0;

      _statusMessage = 'Analyzing URL...';
    });

    try {
      await _downloader.downloadAudio(
        url: url,

        onProgress: (percent, status) {
          if (mounted)
            setState(() {
              _downloadPercentage = percent;

              _statusMessage = status;
            });
        },

        onTrackDownloaded: (filePath) async {
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

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
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

      if (mounted)
        setState(() {
          _searchResults = results;

          _mode = _DialogMode.results;
        });
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

                  Text('YouTube Downloader', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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

              const SizedBox(width: 12),

              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),

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
                  [result.uploader, if (result.formattedDuration.isNotEmpty) result.formattedDuration].join(' · '),

                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),

                trailing: IconButton(
                  icon: Icon(Icons.download_rounded, color: theme.colorScheme.primary),

                  tooltip: 'Download',

                  onPressed: () => _startDownload(result.url),
                ),

                onTap: () => _startDownload(result.url),
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
