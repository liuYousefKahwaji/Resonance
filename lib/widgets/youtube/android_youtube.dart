// lib/widgets/youtube/android_youtube.dart
//
// Android YouTube downloader — mirrors WindowsYoutube UI exactly.
// Instead of spawning yt-dlp.exe as a subprocess, calls into Kotlin via
// MethodChannel, which runs yt-dlp through Chaquopy (embedded Python).
//
// Channel protocol (defined in MainActivity.kt / ytdlp_bridge.py):
//   MethodChannel "resonance/android_youtube"
//     search(query)  → List<Map> [{title, uploader, url, duration_seconds}]
//     download(url, outputDir) → null  (progress via EventChannel)
//   EventChannel "resonance/android_youtube/events"
//     "progress:<percent>:<message>"
//     "track:<filepath>"
//     "done"
//     "error:<message>"

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/services/import_service.dart';

// ─── Models (same shape as YtSearchResult in windows_youtube.dart) ───────────

class YtSearchResult {
  final String title;
  final String uploader;
  final String url;
  final int? durationSeconds;

  const YtSearchResult({
    required this.title,
    required this.uploader,
    required this.url,
    this.durationSeconds,
  });

  String get formattedDuration {
    if (durationSeconds == null) return '';
    final m = durationSeconds! ~/ 60;
    final s = durationSeconds! % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  factory YtSearchResult.fromMap(Map map) {
    return YtSearchResult(
      title: map['title'] as String? ?? 'Unknown',
      uploader: map['uploader'] as String? ?? 'Unknown',
      url: map['url'] as String? ?? '',
      durationSeconds: map['duration_seconds'] as int?,
    );
  }
}

// ─── Bridge ───────────────────────────────────────────────────────────────────

class _AndroidYoutubeDownloader {
  static const _method = MethodChannel('resonance/android_youtube');
  static const _event  = EventChannel('resonance/android_youtube/events');

  Future<List<YtSearchResult>> search(String query) async {
    final raw = await _method.invokeMethod<List>('search', {'query': query});
    return (raw ?? [])
        .map((e) => YtSearchResult.fromMap(e as Map))
        .toList();
  }

  /// Starts download. Returns a stream of raw event strings.
  /// Caller parses "progress:...", "track:...", "done", "error:...".
  Stream<String> download(String url, String outputDir) {
    // Fire the download method call (returns immediately)
    _method.invokeMethod('download', {
      'url': url,
      'outputDir': outputDir,
    });
    // Listen on the event channel
    return _event
        .receiveBroadcastStream()
        .map((event) => event as String);
  }

  Future<String> _resolveOutputDir() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('download_directory');
    if (saved != null && saved != 'Default App Folder') return saved;
    // On Android, use the app's external Music directory
    final dir = await getExternalStorageDirectory();
    return dir?.path ?? (await getApplicationDocumentsDirectory()).path;
  }

  Future<String> get outputDir => _resolveOutputDir();
}

// ─── UI ───────────────────────────────────────────────────────────────────────

enum _DialogMode { input, searching, results, downloading }

class AndroidYoutube extends StatefulWidget {
  final Function(String newPath)? onFileAdded;
  const AndroidYoutube({super.key, this.onFileAdded});

  @override
  State<AndroidYoutube> createState() => _AndroidYoutubeState();
}

class _AndroidYoutubeState extends State<AndroidYoutube> {
  final _urlController    = TextEditingController();
  final _searchController = TextEditingController();
  final _downloader       = _AndroidYoutubeDownloader();

  _DialogMode _mode = _DialogMode.input;
  bool _isUrlMode = true;

  List<YtSearchResult> _searchResults = [];
  double _downloadPercentage = 0.0;
  String _statusMessage = '';

  StreamSubscription<String>? _downloadSub;

  @override
  void dispose() {
    _urlController.dispose();
    _searchController.dispose();
    _downloadSub?.cancel();
    super.dispose();
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _startDownload(String url) async {
    setState(() {
      _mode = _DialogMode.downloading;
      _downloadPercentage = 0.0;
      _statusMessage = 'Analyzing URL...';
    });

    final outputDir = await _downloader.outputDir;

    _downloadSub?.cancel();

    // Collect track paths during streaming; process them sequentially in
    // onDone so that every ImportService.importFiles() is fully awaited
    // before we pop — this fixes the last-track-not-added race condition.
    final pendingTracks = <String>[];

    _downloadSub = _downloader.download(url, outputDir).listen(
      (event) {
        if (event.startsWith('progress:')) {
          // "progress:<percent>:<message>"
          final parts = event.split(':');
          final pct = double.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0.0;
          final msg = parts.sublist(2).join(':');
          if (mounted) {
            setState(() {
              _downloadPercentage = pct;
              _statusMessage = msg;
            });
          }
        } else if (event.startsWith('track:')) {
          // Queue path — will be imported sequentially in onDone
          pendingTracks.add(event.substring('track:'.length));
        } else if (event == 'done') {
          // Cancelling the subscription closes the stream → triggers onDone
          _downloadSub?.cancel();
        } else if (event.startsWith('error:')) {
          final msg = event.substring('error:'.length);
          _downloadSub?.cancel();
          if (mounted) {
            setState(() => _mode = _DialogMode.input);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Error: $msg'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ));
          }
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() => _mode = _DialogMode.input);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ));
        }
      },
      onDone: () async {
        // Process all collected tracks sequentially — every await is
        // properly honoured so the last track is never skipped.
        for (final filePath in pendingTracks) {
          await ImportService.importFiles([filePath], (newPath) {
            widget.onFileAdded?.call(newPath);
          });
        }
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(children: [
                Icon(Icons.check_circle, color: Colors.greenAccent),
                SizedBox(width: 8),
                Text('Download & Import Complete!',
                    style: TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.w500)),
              ]),
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHigh,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      },
    );
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Search failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

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
              Row(children: [
                Icon(Icons.video_library_rounded,
                    color: theme.colorScheme.primary, size: 28),
                const SizedBox(width: 12),
                Text('YouTube Downloader',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 16),
              switch (_mode) {
                _DialogMode.input      => _buildInputBody(theme),
                _DialogMode.searching  => _buildSearchingBody(theme),
                _DialogMode.results    => _buildResultsBody(theme),
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
            ButtonSegment(value: true,  label: Text('URL'),    icon: Icon(Icons.link_rounded)),
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
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
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
          ]),
        ] else ...[
          TextField(
            controller: _searchController,
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
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
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
          ]),
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
            Text('Searching for "${_searchController.text}"...',
                style: theme.textTheme.bodyMedium),
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
        Row(children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _mode = _DialogMode.input),
            tooltip: 'Back',
          ),
          Expanded(
            child: Text(
              'Results for "${_searchController.text}"',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text('${i + 1}',
                      style: TextStyle(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold)),
                ),
                title: Text(result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                subtitle: Text(
                  [
                    result.uploader,
                    if (result.formattedDuration.isNotEmpty)
                      result.formattedDuration,
                  ].join(' · '),
                  style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                trailing: IconButton(
                  icon: Icon(Icons.download_rounded,
                      color: theme.colorScheme.primary),
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
          child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
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
          Text(_statusMessage,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500)),
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
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}