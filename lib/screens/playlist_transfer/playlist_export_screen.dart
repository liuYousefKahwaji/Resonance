import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:resonance/services/playlist_qr_image_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/playlist_transfer_export_service.dart';
import 'package:resonance/services/youtube_transfer_service.dart';

class PlaylistSourceResolutionScreen extends StatefulWidget {
  final PlaylistSourceScan scan;
  final Future<void> Function(List<PlaylistSourceMatch> matches)? onConfirmed;
  final String matchingTitle;
  final String reviewTitle;
  final String cancelLabel;
  final String finishLabel;

  const PlaylistSourceResolutionScreen({
    super.key,
    required this.scan,
    this.onConfirmed,
    this.matchingTitle = 'Finding Playlist Sources',
    this.reviewTitle = 'Review Source Matches',
    this.cancelLabel = 'Cancel export',
    this.finishLabel = 'Finish matching',
  });

  @override
  State<PlaylistSourceResolutionScreen> createState() => _PlaylistSourceResolutionScreenState();
}

class _PlaylistSourceResolutionScreenState extends State<PlaylistSourceResolutionScreen> {
  final YoutubeTransferService _youtube = YoutubeTransferService();
  final PlaylistTransferExportService _export = const PlaylistTransferExportService();
  List<PlaylistSourceMatch> _matches = const [];
  var _matching = true;
  var _saving = false;
  var _cancelled = false;
  var _completed = 0;
  String _currentTrack = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_findMatches());
  }

  Future<void> _findMatches() async {
    try {
      final matches = await _export.findAutomaticMatches(
        widget.scan,
        _youtube.search,
        isCancelled: () => _cancelled,
        onProgress: (completed, total, track) {
          if (!mounted) return;
          setState(() {
            _completed = completed;
            _currentTrack = '${track.artist} — ${track.title}';
          });
        },
      );
      if (mounted) {
        setState(() {
          _matches = matches;
          _matching = false;
        });
      }
    } on PlaylistSourceMatchingCancelled {
      return;
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Source matching failed: $error';
          _matching = false;
        });
      }
    }
  }

  void _cancel() {
    _cancelled = true;
    Navigator.pop(context, false);
  }

  Future<void> _editMatch(PlaylistSourceMatch match) async {
    final result = await showDialog<_SourceEditorResult>(
      context: context,
      builder: (_) => _SourceMatchEditorDialog(
        youtube: _youtube,
        track: match.track,
        initialQuery: match.query,
        initialCandidates: match.candidates,
        selectedVideoId: match.selected?.videoId,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      match.query = result.query;
      match.candidates = result.candidates;
      match.selected = result.selected;
      match.error = null;
      match.skipped = false;
      match.manuallyChanged = true;
    });
  }

  Future<void> _finish() async {
    setState(() => _saving = true);
    try {
      final onConfirmed = widget.onConfirmed;
      if (onConfirmed == null) {
        await _export.commitMatches(widget.scan, _matches);
      } else {
        await onConfirmed(List.unmodifiable(_matches));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not confirm source matches: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_matching ? widget.matchingTitle : widget.reviewTitle),
        leading: IconButton(icon: const Icon(Icons.close_rounded), tooltip: widget.cancelLabel, onPressed: _cancel),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _matching
                  ? _buildMatchingProgress(theme)
                  : _error != null
                  ? _buildFatalError(theme)
                  : _buildReview(theme),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMatchingProgress(ThemeData theme) {
    final total = widget.scan.unresolved.length;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.manage_search_rounded, size: 64),
        const SizedBox(height: 20),
        Text(
          'Automatically selecting the top YouTube result',
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Text('$_completed of $total tracks checked', textAlign: TextAlign.center),
        const SizedBox(height: 16),
        LinearProgressIndicator(value: total == 0 ? 1 : _completed / total),
        const SizedBox(height: 14),
        Text(_currentTrack, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 24),
        TextButton.icon(onPressed: _cancel, icon: const Icon(Icons.close_rounded), label: Text(widget.cancelLabel)),
      ],
    );
  }

  Widget _buildFatalError(ThemeData theme) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(Icons.error_outline_rounded, size: 58, color: theme.colorScheme.error),
      const SizedBox(height: 16),
      Text(_error!, textAlign: TextAlign.center),
      const SizedBox(height: 18),
      FilledButton(onPressed: _cancel, child: const Text('Close')),
    ],
  );

  Widget _buildReview(ThemeData theme) {
    final selectedCount = _matches.where((match) => !match.skipped && match.selected != null).length;
    final unresolvedCount = _matches.length - selectedCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'The top result was selected automatically for $selectedCount track${selectedCount == 1 ? '' : 's'}. Review only the matches you want to replace.',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.builder(
            itemCount: _matches.length,
            itemBuilder: (context, index) => _buildMatchCard(theme, _matches[index], index),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton(onPressed: _saving ? null : _cancel, child: Text(widget.cancelLabel)),
            Text('$unresolvedCount unresolved'),
            FilledButton.icon(
              onPressed: _saving ? null : _finish,
              icon: _saving
                  ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check_rounded),
              label: Text(_saving ? 'Saving…' : widget.finishLabel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMatchCard(ThemeData theme, PlaylistSourceMatch match, int index) {
    final selected = match.selected;
    final status = match.skipped
        ? 'Skipped'
        : selected == null
        ? 'Unresolved'
        : match.manuallyChanged
        ? 'Replaced'
        : 'Top result';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(radius: 16, child: Text('${index + 1}', style: const TextStyle(fontSize: 12))),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${match.track.artist} — ${match.track.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (match.track.formattedDuration.isNotEmpty)
                        Text('Source duration ${match.track.formattedDuration}', style: theme.textTheme.bodySmall),
                      if (match.track.occurrenceCount > 1)
                        Text(
                          'Appears ${match.track.occurrenceCount} times in the playlist',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Chip(label: Text(status)),
              ],
            ),
            const Divider(height: 20),
            if (selected != null && !match.skipped) ...[
              Text(selected.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Text(
                [selected.uploader, if (selected.formattedDuration.isNotEmpty) selected.formattedDuration].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
            ] else
              Text(match.skipped ? 'This track will not be transferred.' : match.error ?? 'No source selected.'),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => _editMatch(match),
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: Text(selected == null ? 'Find a match' : 'Replace'),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => match.skipped = !match.skipped),
                  icon: Icon(match.skipped ? Icons.undo_rounded : Icons.skip_next_rounded),
                  label: Text(match.skipped ? 'Restore' : 'Skip'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceEditorResult {
  final String query;
  final List<YoutubeSearchCandidate> candidates;
  final YoutubeSearchCandidate selected;

  const _SourceEditorResult({required this.query, required this.candidates, required this.selected});
}

class _SourceMatchEditorDialog extends StatefulWidget {
  final YoutubeTransferService youtube;
  final UnresolvedPlaylistTrack track;
  final String initialQuery;
  final List<YoutubeSearchCandidate> initialCandidates;
  final String? selectedVideoId;

  const _SourceMatchEditorDialog({
    required this.youtube,
    required this.track,
    required this.initialQuery,
    required this.initialCandidates,
    required this.selectedVideoId,
  });

  @override
  State<_SourceMatchEditorDialog> createState() => _SourceMatchEditorDialogState();
}

class _SourceMatchEditorDialogState extends State<_SourceMatchEditorDialog> {
  late final TextEditingController _queryController;
  late List<YoutubeSearchCandidate> _results;
  var _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    _results = widget.initialCandidates;
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.youtube.search(query);
      if (mounted) setState(() => _results = results);
    } catch (error) {
      if (mounted) setState(() => _error = 'Search failed: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _select(YoutubeSearchCandidate candidate) {
    Navigator.pop(
      context,
      _SourceEditorResult(
        query: _queryController.text.trim(),
        candidates: List.unmodifiable(_results),
        selected: candidate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Replace “${widget.track.title}”', maxLines: 2, overflow: TextOverflow.ellipsis),
    content: SizedBox(
      width: 620,
      height: (MediaQuery.sizeOf(context).height * 0.62).clamp(280, 440),
      child: Column(
        children: [
          TextField(
            controller: _queryController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: 'YouTube search',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(onPressed: _loading ? null : _search, icon: const Icon(Icons.refresh_rounded)),
            ),
          ),
          const SizedBox(height: 10),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: _results.isEmpty && !_loading
                ? const Center(child: Text('No results. Edit the query and search again.'))
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final result = _results[index];
                      final selected = result.videoId == widget.selectedVideoId;
                      return ListTile(
                        leading: CircleAvatar(child: Text('${index + 1}')),
                        title: Text(result.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            result.uploader,
                            if (result.formattedDuration.isNotEmpty) result.formattedDuration,
                          ].join(' · '),
                        ),
                        trailing: Icon(selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded),
                        onTap: () => _select(result),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
  );
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
