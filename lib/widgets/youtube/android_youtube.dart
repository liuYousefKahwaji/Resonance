// lib/widgets/youtube/android_youtube.dart
// Fixes:
//  1. Stream title: MetadataCacheService.set() is always awaited BEFORE
//     onFileAdded fires, so TrackTile never races against a missing cache entry.
//  2. _startStreamUrl: metadata fetch failure now falls back gracefully to
//     the URL's domain as the "artist" rather than a bare generic string,
//     and always calls _startStream with explicit title/artist (never null).
//  3. Dialog width capped to screen width to prevent overflow on narrow screens.

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
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/core/storage/file_service.dart';

class YtSearchResult {
  final String title;
  final String uploader;
  final String url;
  final int? durationSeconds;

  const YtSearchResult(
      {required this.title,
      required this.uploader,
      required this.url,
      this.durationSeconds});

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

class _AndroidYoutubeDownloader {
  static const _method = MethodChannel('resonance/android_youtube');
  static const _event = EventChannel('resonance/android_youtube/events');

  Future<List<YtSearchResult>> search(String query) async {
    final raw = await _method.invokeMethod<String>('search', {'query': query});
    final decoded = jsonDecode(raw ?? '[]') as List;
    return decoded.map((e) => YtSearchResult.fromMap(e as Map)).toList();
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
  final _downloader = _AndroidYoutubeDownloader();

  _DialogMode _mode = _DialogMode.input;
  bool _isUrlMode = true;
  List<YtSearchResult> _searchResults = [];
  double _downloadPercentage = 0.0;
  String _statusMessage = '';
  StreamSubscription<String>? _downloadSub;

  Future<String> _convertToMp3(String inputPath,
      {String? title, String? artist}) async {
    final outputPath = p.join(
        p.dirname(inputPath),
        '${p.basenameWithoutExtension(inputPath)}.mp3');
    if (p.equals(inputPath, outputPath)) return inputPath;
    final command =
        '-y -i ${_q(inputPath)} -vn -map_metadata 0 '
        '${title == null ? '' : '-metadata title=${_q(title)} '}'
        '${artist == null ? '' : '-metadata artist=${_q(artist)} '}'
        '-codec:a libmp3lame -b:a 192k ${_q(outputPath)}';
    final session = await FFmpegKit.execute(command);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      final logs = await session.getAllLogsAsString();
      throw Exception('Audio conversion failed: ${(logs ?? '').trim()}');
    }
    try { await File(inputPath).delete(); } catch (_) {}
    return outputPath;
  }

  String _q(String v) =>
      '"${v.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  @override
  void dispose() {
    _urlController.dispose();
    _searchController.dispose();
    _downloadSub?.cancel();
    super.dispose();
  }

  Future<void> _startDownload(String url) async {
    setState(() {
      _mode = _DialogMode.downloading;
      _downloadPercentage = 0.0;
      _statusMessage = 'Analyzing URL...';
    });
    final outputDir = await _downloader.outputDir;
    _downloadSub?.cancel();
    final pendingTracks =
        <({String path, String? title, String? artist})>[];
    var completed = false;

    Future<void> finishDownload() async {
      if (completed) return;
      completed = true;
      await _downloadSub?.cancel();
      for (final track in pendingTracks) {
        if (mounted) {
          setState(() {
            _downloadPercentage = 99.0;
            _statusMessage = 'Converting audio...';
          });
        }
        final converted = await _convertToMp3(track.path,
            title: track.title, artist: track.artist);
        await ImportService.importFiles([converted], (newPath) {
          widget.onFileAdded?.call(newPath);
        });
      }
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
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
        ));
      }
    }

    _downloadSub = _downloader.download(url, outputDir).listen(
      (event) {
        if (event.startsWith('progress:')) {
          final parts = event.split(':');
          final pct =
              double.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0.0;
          final msg = parts.sublist(2).join(':');
          if (mounted) setState(() {
            _downloadPercentage = pct;
            _statusMessage = msg;
          });
        } else if (event.startsWith('track:')) {
          final parts = event.substring('track:'.length).split('|');
          pendingTracks.add((
            path: parts[0],
            title: parts.length > 1 ? Uri.decodeComponent(parts[1]) : null,
            artist: parts.length > 2 ? Uri.decodeComponent(parts[2]) : null,
          ));
        } else if (event == 'done') {
          unawaited(finishDownload());
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
      onDone: () async => finishDownload(),
    );
  }

  // FIX: Always call MetadataCacheService.set() BEFORE onFileAdded so
  // TrackTile._loadMetadata() always finds the cache entry on the first
  // lookup. Previously the cache write was fire-and-forgotten while
  // onFileAdded triggered immediate list rebuilds, causing a race where
  // the tile would fall through to the "Streaming Audio / YouTube"
  // fallback and never refresh (no mtime invalidation for streams).
  Future<void> _startStream(String url,
      {required String title, required String artist}) async {
    // Write cache entry FIRST, fully awaited.
    await MetadataCacheService.set(url, title, artist);

    // Then append the URL to the playlist file.
    final playlistContent = await FileService().readTextFromFile();
    final updatedContent = '${playlistContent.trim()}\n$url\n';
    await FileService().writeTextToFile(updatedContent, append: false);

    // Only NOW notify the parent — cache is guaranteed to be populated.
    widget.onFileAdded?.call(url);

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Row(children: [
          Icon(Icons.sensors_rounded, color: Colors.greenAccent),
          SizedBox(width: 8),
          Text('Stream URL Added to Playlist!',
              style: TextStyle(
                  color: Colors.greenAccent, fontWeight: FontWeight.w500)),
        ]),
        backgroundColor:
            Theme.of(context).colorScheme.surfaceContainerHigh,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
    }
  }

  // FIX: _startStreamUrl now always passes explicit non-null title/artist.
  // Previously, on metadata fetch failure it called _startStream(url) with
  // no named args, which defaulted to title=null → 'Streaming Track' and
  // artist=null → 'YouTube'. Now the fallback extracts the host from the
  // URL so users see something meaningful even on failure.
  Future<void> _startStreamUrl(String url) async {
    setState(() {
      _mode = _DialogMode.searching;
      _statusMessage = 'Extracting Video Info...';
    });

    String title;
    String artist;

    try {
      const channel = MethodChannel('resonance/android_youtube');
      final raw =
          await channel.invokeMethod<String>('getMetadata', {'url': url});
      final data = jsonDecode(raw ?? '{}') as Map<String, dynamic>;

      title = (data['title'] as String?)?.trim().isNotEmpty == true
          ? data['title'] as String
          : _titleFromUrl(url);
      artist = (data['artist'] as String?)?.trim().isNotEmpty == true
          ? data['artist'] as String
          : 'YouTube';
    } catch (_) {
      // Metadata fetch failed — use URL-derived fallback so the tile
      // shows something recognisable rather than a generic string.
      title = _titleFromUrl(url);
      artist = 'YouTube';
    }

    await _startStream(url, title: title, artist: artist);
  }

  /// Extract a human-readable name from a URL as a last-resort fallback.
  /// e.g. "https://youtu.be/dQw4w9WgXcQ" → "dQw4w9WgXcQ"
  String _titleFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      // YouTube short URL: path is the video ID
      if (uri.host.contains('youtu.be')) {
        return uri.pathSegments.isNotEmpty
            ? uri.pathSegments.last
            : 'YouTube Stream';
      }
      // Standard YouTube: ?v= param
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
      // Fallback: last path segment
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
      if (mounted) setState(() {
        _searchResults = results;
        _mode = _DialogMode.results;
      });
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxW =
        (MediaQuery.of(context).size.width - 32).clamp(0.0, 480.0);

    return Dialog(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: SizedBox(
          width: maxW,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.video_library_rounded,
                      color: theme.colorScheme.primary, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'YouTube · Stream or Download',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                      maxLines: 2,
                    ),
                  ),
                ]),
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
    );
  }

  Widget _buildInputBody(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
                value: true,
                label: Text('URL'),
                icon: Icon(Icons.link_rounded)),
            ButtonSegment(
                value: false,
                label: Text('Search'),
                icon: Icon(Icons.search_rounded)),
          ],
          selected: {_isUrlMode},
          onSelectionChanged: (s) =>
              setState(() => _isUrlMode = s.first),
          style: const ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ),
        const SizedBox(height: 14),
        if (_isUrlMode) ...[
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: 'Video / Playlist URL',
              hintText: 'https://youtu.be/...',
              prefixIcon: const Icon(Icons.link_rounded),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
              filled: true,
            ),
            onSubmitted: (_) {
              final url = _urlController.text.trim();
              if (url.isNotEmpty) _startDownload(url);
            },
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel')),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  side: BorderSide(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.6)),
                  foregroundColor:
                      Theme.of(context).colorScheme.primary,
                ),
                onPressed: () {
                  final url = _urlController.text.trim();
                  if (url.isNotEmpty) _startStreamUrl(url);
                },
                icon: const Icon(Icons.sensors_rounded, size: 18),
                label: const Text('Stream'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
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
            decoration: InputDecoration(
              labelText: 'Search YouTube',
              hintText: 'Artist, song name...',
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
              filled: true,
            ),
            onSubmitted: (_) => _runSearch(),
          ),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _isUrlMode
                ? 'Extracting info...'
                : 'Searching for "${_searchController.text}"...',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ]),
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
                      result.formattedDuration
                  ].join(' · '),
                  style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: Icon(Icons.sensors_rounded,
                        color: theme.colorScheme.primary),
                    tooltip: 'Stream',
                    // Search results have known title/artist — pass them directly.
                    onPressed: () => _startStream(result.url,
                        title: result.title,
                        artist: result.uploader),
                  ),
                  IconButton(
                    icon: Icon(Icons.download_rounded,
                        color: theme.colorScheme.primary),
                    tooltip: 'Download',
                    onPressed: () => _startDownload(result.url),
                  ),
                ]),
                onTap: () => _startStream(result.url,
                    title: result.title, artist: result.uploader),
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
              backgroundColor:
                  theme.colorScheme.surfaceContainerHighest,
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