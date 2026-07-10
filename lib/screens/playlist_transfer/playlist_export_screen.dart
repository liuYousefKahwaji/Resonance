import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/services/playlist_qr_image_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/playlist_transfer_export_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/youtube_transfer_service.dart';

class PlaylistSourceResolutionScreen extends StatefulWidget {
  final PlaylistSourceScan scan;

  const PlaylistSourceResolutionScreen({super.key, required this.scan});

  @override
  State<PlaylistSourceResolutionScreen> createState() => _PlaylistSourceResolutionScreenState();
}

class _PlaylistSourceResolutionScreenState extends State<PlaylistSourceResolutionScreen> {
  final YoutubeTransferService _youtube = YoutubeTransferService();
  final TrackSourceRepository _sources = const TrackSourceRepository();
  final TextEditingController _queryController = TextEditingController();
  var _index = 0;
  var _loading = false;
  String? _error;
  List<YoutubeSearchCandidate> _results = const [];

  UnresolvedPlaylistTrack get _current => widget.scan.unresolved[_index];

  @override
  void initState() {
    super.initState();
    _prepareCurrent();
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _prepareCurrent() {
    if (_index >= widget.scan.unresolved.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
      return;
    }
    _queryController.text = _current.searchQuery;
    unawaited(_search());
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _results = const [];
    });
    try {
      final results = await _youtube.search(query);
      if (mounted) setState(() => _results = results);
    } catch (error) {
      if (mounted) setState(() => _error = 'Search failed: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _accept(YoutubeSearchCandidate candidate) async {
    await _sources.saveSource(
      localPath: _current.localPath,
      youtubeVideoId: candidate.videoId,
      method: TrackSourceMethod.manuallySelected,
    );
    widget.scan.resolvedByPath[_current.localPath] = candidate.videoId;
    _advance();
  }

  void _advance() {
    setState(() {
      _index++;
      _results = const [];
      _error = null;
    });
    _prepareCurrent();
  }

  @override
  Widget build(BuildContext context) {
    if (_index >= widget.scan.unresolved.length) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    final track = _current;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resolve Playlist Sources'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Cancel transfer',
          onPressed: () => Navigator.pop(context, false),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: _index / widget.scan.unresolved.length),
                  const SizedBox(height: 12),
                  Text(
                    'Track ${_index + 1} of ${widget.scan.unresolved.length} requiring a source',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 18),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.audio_file_rounded),
                      title: Text(track.title),
                      subtitle: Text(
                        '${track.artist}${track.occurrenceCount > 1 ? ' · appears ${track.occurrenceCount} times' : ''}\n${track.localPath}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _queryController,
                    decoration: InputDecoration(
                      labelText: 'YouTube search',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.refresh_rounded),
                        onPressed: _loading ? null : _search,
                      ),
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                  ),
                  const SizedBox(height: 12),
                  if (_loading) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                    ),
                  Expanded(
                    child: _loading
                        ? const Center(child: Text('Searching YouTube…'))
                        : _results.isEmpty
                        ? const Center(child: Text('No results. Edit the query, retry, or skip this track.'))
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final result = _results[index];
                              return ListTile(
                                leading: CircleAvatar(child: Text('${index + 1}')),
                                title: Text(result.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  [
                                    result.uploader,
                                    if (result.formattedDuration.isNotEmpty) result.formattedDuration,
                                  ].join(' · '),
                                ),
                                trailing: const Icon(Icons.check_circle_outline_rounded),
                                onTap: () => _accept(result),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () => Navigator.pop(context, false),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('Cancel export'),
                      ),
                      const Spacer(),
                      OutlinedButton.icon(
                        onPressed: _advance,
                        icon: const Icon(Icons.skip_next_rounded),
                        label: Text(track.occurrenceCount > 1 ? 'Skip ${track.occurrenceCount} entries' : 'Skip track'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PlaylistQrDisplayScreen extends StatefulWidget {
  final EncodedPlaylistTransfer transfer;

  const PlaylistQrDisplayScreen({super.key, required this.transfer});

  @override
  State<PlaylistQrDisplayScreen> createState() => _PlaylistQrDisplayScreenState();
}

class _PlaylistQrDisplayScreenState extends State<PlaylistQrDisplayScreen> {
  Timer? _timer;
  var _index = 0;
  var _autoCycle = true;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _configureTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _configureTimer() {
    _timer?.cancel();
    if (!_autoCycle || widget.transfer.qrPayloads.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) setState(() => _index = (_index + 1) % widget.transfer.qrPayloads.length);
    });
  }

  void _setIndex(int index) {
    setState(() => _index = index.clamp(0, widget.transfer.qrPayloads.length - 1));
    _configureTimer();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final location = await PlaylistQrImageService.saveQrCodes(
        playlistName: widget.transfer.manifest.playlistName,
        payloads: widget.transfer.qrPayloads,
      );
      if (mounted && location != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QR code${widget.transfer.qrPayloads.length == 1 ? '' : 's'} saved to $location')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save QR codes: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payloads = widget.transfer.qrPayloads;
    final multiple = payloads.length > 1;
    return Scaffold(
      appBar: AppBar(title: const Text('Transfer Playlist')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                children: [
                  Text(
                    widget.transfer.manifest.playlistName,
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text('${widget.transfer.manifest.youtubeVideoIds.length} transferred playlist entries'),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: QrImageView(
                        key: ValueKey(_index),
                        data: payloads[_index],
                        version: QrVersions.auto,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                        padding: EdgeInsets.zero,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('${_index + 1} of ${payloads.length}', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    multiple
                        ? 'Scan every code on the receiving device. Codes may be scanned in any order.'
                        : 'Scan this code on the receiving device.',
                    textAlign: TextAlign.center,
                  ),
                  if (multiple) ...[
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'Previous QR code',
                          onPressed: _index > 0 ? () => _setIndex(_index - 1) : null,
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () {
                            setState(() => _autoCycle = !_autoCycle);
                            _configureTimer();
                          },
                          icon: Icon(_autoCycle ? Icons.pause_rounded : Icons.play_arrow_rounded),
                          label: Text(_autoCycle ? 'Pause cycling' : 'Auto cycle'),
                        ),
                        IconButton(
                          tooltip: 'Next QR code',
                          onPressed: _index + 1 < payloads.length ? () => _setIndex(_index + 1) : null,
                          icon: const Icon(Icons.chevron_right_rounded),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_alt_rounded),
                    label: Text(_saving ? 'Saving…' : 'Save QR Codes'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
