import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/services/import_service.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class MediaDownloader {
  Future<void> initBinaries() async {
    final supportDir = await getApplicationSupportDirectory();
    final binDir = Directory(p.join(supportDir.path, 'bin'));
    
    if (!await binDir.exists()) {
      await binDir.create(recursive: true);
    }

    final executables = ['yt-dlp.exe', 'ffmpeg.exe', 'ffprobe.exe', 'deno.exe'];

    for (var exe in executables) {
      final exeFile = File(p.join(binDir.path, exe));
      if (!await exeFile.exists()) {
        final data = await rootBundle.load('assets/bin/$exe');
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        await exeFile.writeAsBytes(bytes);
      }
    }
  }

  /// Downloads single videos or entire playlists, firing [onTrackDownloaded] as each file finishes.
  Future<void> downloadAudio({
    required String url,
    required Function(double percentage, String status) onProgress,
    required Function(String filePath) onTrackDownloaded,
  }) async {
    final supportDir = await getApplicationSupportDirectory();
    final binDirPath = p.join(supportDir.path, 'bin');

    final ytDlpPath = p.join(binDirPath, 'yt-dlp.exe');
    final ffmpegPath = p.join(binDirPath, 'ffmpeg.exe');
    final denoPath = p.join(binDirPath, 'deno.exe');

    final prefs = await SharedPreferences.getInstance();
    String? savedPath = prefs.getString('download_directory');
    
    String targetDir;
    if (savedPath != null && savedPath != 'Default App Folder') {
      targetDir = savedPath;
    } else {
      if (_isDesktop) {
        final downloadDir = await getDownloadsDirectory();
        targetDir = downloadDir?.path ?? supportDir.path;
      } else {
        targetDir = supportDir.path;
      }
    }

    final outputTemplate = p.join(targetDir, '%(title)s.%(ext)s');

    int attempt = 0;
    const int maxAttempts = 3;
    final processedPaths = <String>{};

    while (attempt < maxAttempts) {
      try {
        attempt++;
        if (attempt > 1) {
          onProgress(0.0, 'Connection dropped. Retrying ($attempt/$maxAttempts)...');
          await Future.delayed(Duration(seconds: attempt * 2));
        }

        final process = await Process.start(
          ytDlpPath,
          [
            '--ffmpeg-location', ffmpegPath,
            '--js-runtimes', 'deno:$denoPath',
            '-x', 
            '--audio-format', 'mp3',
            '--embed-metadata', 
            '--newline',
            '--yes-playlist', 
            '--print', 'after_move:%(filepath)s', 
            '-o', outputTemplate,
            url
          ],
        );

        final progressRegex = RegExp(r'\[download\]\s+(\d+\.\d+)%');
        final playlistItemRegex = RegExp(r'\[download\]\s+Downloading item\s+(\d+)\s+of\s+(\d+)');

        int currentItem = 1;
        int totalItems = 1;

        final streamDone = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) async {
          final trimmedLine = line.trim();

          if (playlistItemRegex.hasMatch(trimmedLine)) {
            final match = playlistItemRegex.firstMatch(trimmedLine);
            if (match != null) {
              currentItem = int.tryParse(match.group(1) ?? '1') ?? 1;
              totalItems = int.tryParse(match.group(2) ?? '1') ?? 1;
            }
          }

          if (trimmedLine.contains('[download]') && trimmedLine.contains('%')) {
            final match = progressRegex.firstMatch(trimmedLine);
            if (match != null) {
              final percent = double.tryParse(match.group(1) ?? '0') ?? 0.0;
              final prefix = totalItems > 1 ? '($currentItem/$totalItems) ' : '';
              onProgress(percent, '${prefix}Downloading... ${percent.toStringAsFixed(1)}%');
            }
          } 
          else if (trimmedLine.contains('[ExtractAudio]')) {
            final prefix = totalItems > 1 ? '($currentItem/$totalItems) ' : '';
            onProgress(100.0, '${prefix}Processing audio tracks...');
          }
          else if (trimmedLine.contains('has already been downloaded')) {
            final match = RegExp(r'\[download\]\s+(.*\.mp3)\s+has already been downloaded').firstMatch(trimmedLine);
            if (match != null) {
              final path = p.normalize(match.group(1)!);
              if (!processedPaths.contains(path)) {
                processedPaths.add(path);
                if (await File(path).exists()) {
                  onTrackDownloaded(path);
                }
              }
            }
          }
          else if (trimmedLine.endsWith('.mp3') && !trimmedLine.contains('[')) {
            final verifiedCleanPath = p.normalize(trimmedLine);

            if (!processedPaths.contains(verifiedCleanPath)) {
              processedPaths.add(verifiedCleanPath);
              
              await Future.delayed(const Duration(milliseconds: 300));
              
              if (await File(verifiedCleanPath).exists()) {
                onTrackDownloaded(verifiedCleanPath);
              }
            }
          }
        }).asFuture();

        final exitCode = await process.exitCode;
        await streamDone;

        if (exitCode != 0) {
          throw Exception('yt-dlp exited with error code $exitCode');
        }

        return; 
        
      } catch (e) {
        debugPrint('Download failure on attempt $attempt: $e');
        if (attempt >= maxAttempts) {
          rethrow;
        }
      }
    }
  }
}

class WindowsYoutube extends StatefulWidget {
  final Function(String newPath)? onFileAdded;
  
  const WindowsYoutube({super.key, this.onFileAdded});

  @override
  State<WindowsYoutube> createState() => _WindowsYoutubeState();
}

class _WindowsYoutubeState extends State<WindowsYoutube> {
  final _urlController = TextEditingController();
  final _downloader = MediaDownloader();
  
  bool _isDownloading = false;
  double _downloadPercentage = 0.0;
  String _statusMessage = 'Ready to download';

  @override
  void initState() {
    super.initState();
    _downloader.initBinaries();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 450, 
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
                  'YouTube Downloader',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (!_isDownloading) ...[
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
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () async {
                      final url = _urlController.text.trim();
                      if (url.isEmpty) return;

                      setState(() {
                        _isDownloading = true;
                        _downloadPercentage = 0.0;
                        _statusMessage = 'Analyzing URL pipeline...';
                      });

                      try {
                        await _downloader.downloadAudio(
                          url: url,
                          onProgress: (percent, status) {
                            if (mounted) {
                              setState(() {
                                _downloadPercentage = percent;
                                _statusMessage = status;
                              });
                            }
                          },
                          onTrackDownloaded: (filePath) async {
                            await ImportService.importFiles([filePath], (newlyAddedTrack) {
                              if (widget.onFileAdded != null) {
                                widget.onFileAdded!(newlyAddedTrack);
                              }
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
                              backgroundColor: theme.colorScheme.surfaceContainerHigh,
                              behavior: SnackBarBehavior.floating,
                              duration: const Duration(seconds: 3),
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          setState(() {
                            _isDownloading = false;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Error processing task: ${e.toString()}'),
                              backgroundColor: theme.colorScheme.error,
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Download'),
                  ),
                ],
              ),
            ] else ...[
              Text(
                _statusMessage,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
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
          ],
        ),
      ),
    );
  }
}