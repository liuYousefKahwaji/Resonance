import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/widgets/youtube/youtube_failure_dialog.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/playlist_qr_image_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/youtube_transfer_service.dart';

enum _ImportStage { receiving, reconstructing, preview, downloading, failures, creating, complete, error }

class PlaylistImportScreen extends StatefulWidget {
  const PlaylistImportScreen({super.key});

  @override
  State<PlaylistImportScreen> createState() => _PlaylistImportScreenState();
}

class _PlaylistImportScreenState extends State<PlaylistImportScreen> {
  final PlaylistTransferSession _session = PlaylistTransferSession();
  final TrackSourceRepository _sources = const TrackSourceRepository();
  final YoutubeTransferService _youtube = YoutubeTransferService();
  final List<String> _acceptedRawPayloads = [];
  final List<String> _notices = [];
  MobileScannerController? _scannerController;
  _ImportStage _stage = _ImportStage.receiving;
  PlaylistTransferManifest? _manifest;
  String? _fatalError;
  String? _downloadDestination;
  final Map<String, String> _resolvedById = {};
  final Map<String, String> _downloadFailures = {};
  List<String> _missingIds = const [];
  List<String> _operationIds = const [];
  var _processingInput = false;
  var _currentDownloadIndex = 0;
  var _downloadPercentage = 0.0;
  var _downloadStatus = '';
  String? _currentVideoId;
  var _downloadedCount = 0;
  var _streamedCount = 0;
  var _isStreaming = false;
  var _stopRequested = false;
  bool _cancelledDuringDownload = false;
  String? _createdPlaylistName;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _scannerController = MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    }
  }

  @override
  void dispose() {
    _session.clear();
    unawaited(_scannerController?.dispose());
    super.dispose();
  }

  Future<void> _onCameraDetect(BarcodeCapture capture) async {
    if (_stage != _ImportStage.receiving || _processingInput) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null) await _acceptRawPayload(value, sourceLabel: 'Camera');
      if (_stage != _ImportStage.receiving) break;
    }
  }

  Future<void> _acceptRawPayload(String raw, {required String sourceLabel}) async {
    if (_stage != _ImportStage.receiving) return;
    _processingInput = true;
    try {
      final acceptance = _session.acceptChunk(raw.trim());
      if (acceptance == ChunkAcceptance.accepted) {
        _acceptedRawPayloads.add(raw.trim());
        _addNotice('$sourceLabel: received QR ${_session.receivedChunkIndexes.last}.');
      } else {
        _addNotice('$sourceLabel: duplicate QR ignored.');
      }
      if (mounted) setState(() {});
      if (_session.isComplete) {
        await _scannerController?.stop();
        await _reconstruct();
      }
    } on PlaylistTransferException catch (error) {
      _addNotice('$sourceLabel: ${error.message}');
      if (mounted) setState(() {});
    } catch (error) {
      _addNotice('$sourceLabel: unreadable QR ($error).');
      if (mounted) setState(() {});
    } finally {
      _processingInput = false;
    }
  }

  void _addNotice(String message) {
    _notices.insert(0, message);
    if (_notices.length > 8) _notices.removeLast();
  }

  Future<void> _pickQrImages() async {
    if (_processingInput || _stage != _ImportStage.receiving) return;
    _processingInput = true;
    if (mounted) setState(() {});
    await _scannerController?.stop();
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Upload Resonance playlist QR images',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
      allowMultiple: true,
    );
    try {
      if (result == null) return;
      for (final file in result.files) {
        if (_stage != _ImportStage.receiving) break;
        final path = file.path;
        if (path == null) {
          _addNotice('${file.name}: no readable file path.');
          continue;
        }
        try {
          final raw = await PlaylistQrImageService.decodeFile(path);
          // _acceptRawPayload owns the guard while it validates a chunk. The
          // camera is stopped, so briefly releasing it cannot race a scan.
          _processingInput = false;
          await _acceptRawPayload(raw, sourceLabel: file.name);
          _processingInput = true;
        } catch (error) {
          _addNotice('${file.name}: no readable QR code ($error).');
        }
      }
    } finally {
      _processingInput = false;
      if (mounted) setState(() {});
      if (_stage == _ImportStage.receiving) await _scannerController?.start();
    }
  }

  Future<void> _reconstruct() async {
    setState(() => _stage = _ImportStage.reconstructing);
    try {
      final manifest = await compute(_reconstructManifest, List<String>.from(_acceptedRawPayloads));
      _manifest = manifest;
      await _preparePreview();
    } on PlaylistTransferException catch (error) {
      setState(() {
        _fatalError = error.message;
        _stage = _ImportStage.error;
      });
    } catch (error) {
      setState(() {
        _fatalError = 'Could not reconstruct this playlist transfer: $error';
        _stage = _ImportStage.error;
      });
    }
  }

  Future<void> _preparePreview() async {
    final manifest = _manifest!;
    final uniqueIds = manifest.youtubeVideoIds.toSet().toList(growable: false);
    _resolvedById.clear();
    for (final videoId in uniqueIds) {
      final localPath = await _sources.findLocalTrackByYoutubeId(videoId);
      if (localPath != null) _resolvedById[videoId] = localPath;
    }
    _missingIds = [
      for (final videoId in uniqueIds)
        if (!_resolvedById.containsKey(videoId)) videoId,
    ];
    _downloadDestination = await _youtube.downloadDestinationDescription();
    if (mounted) setState(() => _stage = _ImportStage.preview);
  }

  Future<void> _startImport({List<String>? onlyIds}) async {
    final ids = onlyIds ?? _missingIds;
    _operationIds = ids;
    _isStreaming = false;
    _downloadFailures.clear();
    _stopRequested = false;
    _cancelledDuringDownload = false;
    setState(() {
      _stage = _ImportStage.downloading;
      _currentDownloadIndex = 0;
      _downloadPercentage = 0;
    });
    YoutubeFailure? accessFailure;
    for (var index = 0; index < ids.length; index++) {
      if (_stopRequested) {
        _cancelledDuringDownload = true;
        break;
      }
      final videoId = ids[index];
      setState(() {
        _currentDownloadIndex = index + 1;
        _currentVideoId = videoId;
        _downloadPercentage = 0;
        _downloadStatus = 'Preparing download…';
      });
      try {
        final result = await _youtube.downloadVideo(
          videoId,
          onProgress: (percentage, status) {
            if (mounted) {
              setState(() {
                _downloadPercentage = percentage;
                _downloadStatus = status;
              });
            }
          },
        );
        _resolvedById[videoId] = result.localPath;
        _downloadedCount++;
      } catch (error) {
        _downloadFailures[videoId] = error is YoutubeFailure ? error.userMessage : error.toString();
        if (error is YoutubeFailure && error.isAccessFailure) {
          accessFailure = error;
          break;
        }
      }
    }
    if (!mounted) return;
    if (accessFailure != null) {
      unawaited(showYoutubeFailure(context, accessFailure));
    }
    if (_downloadFailures.isNotEmpty || _cancelledDuringDownload) {
      setState(() => _stage = _ImportStage.failures);
    } else {
      await _createPlaylist();
    }
  }

  Future<void> _startStreaming() async {
    final ids = _manifest!.youtubeVideoIds.toSet().toList(growable: false);
    _operationIds = ids;
    _isStreaming = true;
    _resolvedById.clear();
    _downloadFailures.clear();
    _stopRequested = false;
    _cancelledDuringDownload = false;
    _streamedCount = 0;
    setState(() {
      _stage = _ImportStage.downloading;
      _currentDownloadIndex = 0;
      _downloadPercentage = 0;
    });
    for (var index = 0; index < ids.length; index++) {
      if (_stopRequested) {
        _cancelledDuringDownload = true;
        break;
      }
      final videoId = ids[index];
      setState(() {
        _currentDownloadIndex = index + 1;
        _currentVideoId = videoId;
        _downloadPercentage = 0;
        _downloadStatus = 'Reading stream metadata…';
      });
      final url = TrackSourceRepository.canonicalUrlFor(videoId);
      try {
        final candidate = await _youtube.lookup(videoId);
        await _youtube.rememberStream(candidate);
      } catch (_) {
        // Metadata improves the display name but is not required for a valid
        // YouTube playlist entry.
      }
      _resolvedById[videoId] = url;
      _streamedCount++;
      if (mounted) {
        setState(() {
          _downloadPercentage = 100;
          _downloadStatus = 'Stream ready';
        });
      }
    }
    if (!mounted) return;
    if (_cancelledDuringDownload) {
      setState(() => _stage = _ImportStage.failures);
    } else {
      await _createPlaylist();
    }
  }

  Future<void> _retryFailures() async {
    final failed = _downloadFailures.keys.toList(growable: false);
    await _startImport(onlyIds: failed);
  }

  Future<void> _createPlaylist() async {
    final manifest = _manifest!;
    final orderedPaths = [
      for (final videoId in manifest.youtubeVideoIds)
        if (_resolvedById[videoId] case final String localPath) localPath,
    ];
    if (orderedPaths.isEmpty) {
      setState(() {
        _fatalError = 'No transferred tracks are available, so no playlist was created.';
        _stage = _ImportStage.error;
      });
      return;
    }
    setState(() => _stage = _ImportStage.creating);
    try {
      final created = await FileService().createImportedPlaylist(manifest.playlistName, orderedPaths);
      if (mounted) {
        setState(() {
          _createdPlaylistName = created.displayName;
          _stage = _ImportStage.complete;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _fatalError = 'Tracks were resolved, but Resonance could not create the playlist: $error';
          _stage = _ImportStage.error;
        });
      }
    }
  }

  void _clearReceived() {
    _session.clear();
    _acceptedRawPayloads.clear();
    _notices.clear();
    setState(() {});
    unawaited(_scannerController?.start());
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stage != _ImportStage.downloading && _stage != _ImportStage.creating,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Import Playlist'),
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _stage == _ImportStage.downloading || _stage == _ImportStage.creating
                ? null
                : () => Navigator.pop(context, _stage == _ImportStage.complete),
          ),
        ),
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() => switch (_stage) {
    _ImportStage.receiving => _buildReceiving(),
    _ImportStage.reconstructing => _centerProgress('Reconstructing and validating playlist…'),
    _ImportStage.preview => _buildPreview(),
    _ImportStage.downloading => _buildDownloading(),
    _ImportStage.failures => _buildFailures(),
    _ImportStage.creating => _centerProgress('Creating Resonance playlist…'),
    _ImportStage.complete => _buildComplete(),
    _ImportStage.error => _buildError(),
  };

  Widget _buildReceiving() {
    final total = _session.totalChunks;
    final progress = total == null ? null : _session.receivedChunkCount / total;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                Platform.isAndroid ? 'Scan Resonance playlist QR codes' : 'Upload Resonance playlist QR images',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Decoding is fully local. Downloads or stream lookups will not begin until you review the playlist.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (Platform.isAndroid)
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: MobileScanner(
                      controller: _scannerController,
                      onDetect: _onCameraDetect,
                      errorBuilder: (context, error) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text('Camera unavailable: ${error.errorDetails?.message ?? error.errorCode.name}'),
                        ),
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Center(
                    child: FilledButton.icon(
                      onPressed: _processingInput ? null : _pickQrImages,
                      icon: const Icon(Icons.upload_file_rounded),
                      label: Text(_processingInput ? 'Reading images…' : 'Upload QR Images'),
                    ),
                  ),
                ),
              if (Platform.isAndroid) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('android-upload-qr-images'),
                  onPressed: _processingInput ? null : _pickQrImages,
                  icon: const Icon(Icons.add_photo_alternate_rounded),
                  label: Text(_processingInput ? 'Reading images…' : 'Upload QR image(s)'),
                ),
              ],
              const SizedBox(height: 14),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Text(
                total == null
                    ? 'Waiting for the first Resonance QR code…'
                    : '${_session.receivedChunkCount} of $total codes received${_session.missingChunkIndexes.isEmpty ? '' : ' · missing ${_session.missingChunkIndexes.join(', ')}'}',
                textAlign: TextAlign.center,
              ),
              if (_notices.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_notices.first, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
              ],
              if (_session.receivedChunkCount > 0) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!Platform.isAndroid) ...[
                      OutlinedButton.icon(
                        onPressed: _processingInput ? null : _pickQrImages,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('Add more images'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    TextButton(onPressed: _clearReceived, child: const Text('Start over')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final manifest = _manifest!;
    final uniqueCount = manifest.youtubeVideoIds.toSet().length;
    return _scrollingCard(
      title: 'Import “${manifest.playlistName}”',
      children: [
        _metric('Playlist entries', manifest.youtubeVideoIds.length.toString()),
        _metric('Unique YouTube sources', uniqueCount.toString()),
        _metric('Already available locally', _resolvedById.length.toString()),
        _metric('Need downloading', _missingIds.length.toString()),
        _metric('Invalid sources', '0'),
        const Divider(height: 28),
        const Text('Download destination', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        SelectableText(_downloadDestination ?? 'Default download folder'),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _startImport,
          icon: const Icon(Icons.download_for_offline_rounded),
          label: Text(_missingIds.isEmpty ? 'Create With Local Tracks' : 'Download Tracks'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _startStreaming,
          icon: const Icon(Icons.sensors_rounded),
          label: const Text('Stream From Playlist'),
        ),
        const SizedBox(height: 8),
        Text(
          'Streaming adds YouTube links in the transferred order without downloading audio.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      ],
    );
  }

  Widget _buildDownloading() {
    return _scrollingCard(
      title: _isStreaming ? 'Preparing playlist streams' : 'Downloading missing tracks',
      children: [
        Text('Track $_currentDownloadIndex of ${_operationIds.length}', textAlign: TextAlign.center),
        const SizedBox(height: 6),
        SelectableText(_currentVideoId ?? '', textAlign: TextAlign.center),
        const SizedBox(height: 20),
        LinearProgressIndicator(value: _downloadPercentage > 0 ? _downloadPercentage / 100 : null),
        const SizedBox(height: 10),
        Text(_downloadStatus, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _stopRequested ? null : () => setState(() => _stopRequested = true),
          icon: const Icon(Icons.stop_circle_outlined),
          label: Text(_stopRequested ? 'Stopping after current track…' : 'Stop after current track'),
        ),
        const SizedBox(height: 8),
        Text(
          _isStreaming
              ? 'Prepared links stay in their original playlist order.'
              : 'Completed downloads are kept and their source records are saved.',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildFailures() {
    final failedIds = _downloadFailures.keys.toList(growable: false);
    return _scrollingCard(
      title: _cancelledDuringDownload ? 'Import stopped' : 'Some tracks could not be downloaded',
      children: [
        _metric('Downloaded', _downloadedCount.toString()),
        _metric('Streams added', _streamedCount.toString()),
        _metric(
          'Reused locally',
          (_resolvedById.length - _downloadedCount - _streamedCount).clamp(0, _resolvedById.length).toString(),
        ),
        _metric('Failed', failedIds.length.toString()),
        _metric(
          'Skipped if playlist is created now',
          (_manifest!.youtubeVideoIds.where((id) => !_resolvedById.containsKey(id)).length).toString(),
        ),
        if (failedIds.isNotEmpty) ...[
          const Divider(height: 28),
          for (final id in failedIds)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.error_outline_rounded),
              title: Text(id),
              subtitle: Text(_downloadFailures[id]!, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          if (!_isStreaming)
            FilledButton.icon(
              onPressed: _retryFailures,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry failed tracks'),
            ),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
          onPressed: _resolvedById.isEmpty ? null : _createPlaylist,
          icon: const Icon(Icons.skip_next_rounded),
          label: const Text('Skip unresolved and create playlist'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Close without creating playlist'),
        ),
      ],
    );
  }

  Widget _buildComplete() {
    final resolvedEntries = _manifest!.youtubeVideoIds.where(_resolvedById.containsKey).length;
    return _scrollingCard(
      title: 'Import complete',
      children: [
        const Icon(Icons.check_circle_rounded, size: 64, color: Colors.green),
        const SizedBox(height: 16),
        Text('“$_createdPlaylistName” was created with $resolvedEntries entries.', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        _metric('Downloaded', _downloadedCount.toString()),
        _metric('Streams added', _streamedCount.toString()),
        _metric(
          'Reused locally',
          (_resolvedById.length - _downloadedCount - _streamedCount).clamp(0, _resolvedById.length).toString(),
        ),
        _metric('Failed', _downloadFailures.length.toString()),
        _metric('Skipped entries', (_manifest!.youtubeVideoIds.length - resolvedEntries).toString()),
        const SizedBox(height: 18),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')),
      ],
    );
  }

  Widget _buildError() => _scrollingCard(
    title: 'Playlist import failed',
    children: [
      Icon(Icons.error_outline_rounded, size: 58, color: Theme.of(context).colorScheme.error),
      const SizedBox(height: 14),
      Text(_fatalError ?? 'Unknown transfer error', textAlign: TextAlign.center),
      const SizedBox(height: 18),
      FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
    ],
  );

  Widget _centerProgress(String text) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [const CircularProgressIndicator(), const SizedBox(height: 18), Text(text)],
    ),
  );

  Widget _scrollingCard({required String title, required List<Widget> children}) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                ...children,
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );
}

PlaylistTransferManifest _reconstructManifest(List<String> payloads) {
  final session = PlaylistTransferSession();
  for (final payload in payloads) {
    session.acceptChunk(payload);
  }
  return session.reconstructManifest();
}
