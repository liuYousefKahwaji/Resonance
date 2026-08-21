import 'dart:async';

import 'package:flutter/material.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/widgets/youtube/youtube_failure_dialog.dart';
import 'package:resonance/models/external_playlist.dart';
import 'package:resonance/screens/playlist_transfer/playlist_export_screen.dart';
import 'package:resonance/services/external_playlist_service.dart';
import 'package:resonance/services/playlist_transfer_export_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/youtube_playlist_import_service.dart';
import 'package:resonance/services/youtube_transfer_service.dart';

enum _ExternalImportStage { input, fetching, choosing, importing, complete, error }

class ExternalPlaylistImportScreen extends StatefulWidget {
  final ExternalPlaylistService? playlistService;
  final YoutubePlaylistImportService? importService;
  final String? initialUrl;
  final bool autoFetch;

  const ExternalPlaylistImportScreen({
    super.key,
    this.playlistService,
    this.importService,
    this.initialUrl,
    this.autoFetch = false,
  });

  @override
  State<ExternalPlaylistImportScreen> createState() => _ExternalPlaylistImportScreenState();
}

class _ExternalPlaylistImportScreenState extends State<ExternalPlaylistImportScreen> {
  late final ExternalPlaylistService _playlists;
  late final YoutubePlaylistImportService _importer;
  final TextEditingController _urlController = TextEditingController();
  _ExternalImportStage _stage = _ExternalImportStage.input;
  ExternalPlaylist? _playlist;
  List<PlaylistSourceMatch> _matches = const [];
  YoutubePlaylistImportResult? _result;
  String? _error;
  String _progressTrack = '';
  String _progressStatus = '';
  int _progressCompleted = 0;
  int _progressTotal = 0;
  double _progressPercentage = 0;
  bool _stopRequested = false;

  @override
  void initState() {
    super.initState();
    _playlists = widget.playlistService ?? ExternalPlaylistService();
    _importer = widget.importService ?? YoutubePlaylistImportService();
    _urlController.text = widget.initialUrl?.trim() ?? '';
    if (widget.autoFetch && _urlController.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchAndReview();
      });
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _fetchAndReview() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _stage = _ExternalImportStage.fetching;
      _error = null;
      _playlist = null;
      _matches = const [];
    });
    try {
      final playlist = await _playlists.fetch(_urlController.text);
      if (!mounted) return;
      _playlist = playlist;
      final identifiers = List<String>.generate(
        playlist.tracks.length,
        (index) => 'external:${playlist.kind.name}:$index',
        growable: false,
      );
      final scan = PlaylistSourceScan(
        playlistName: playlist.name,
        playlistTracks: identifiers,
        resolvedByPath: <String, String>{},
        unresolved: [
          for (var index = 0; index < playlist.tracks.length; index++)
            UnresolvedPlaylistTrack(
              localPath: identifiers[index],
              title: playlist.tracks[index].title,
              artist: playlist.tracks[index].artistLabel,
              occurrenceCount: 1,
              durationSeconds: playlist.tracks[index].duration?.inSeconds,
            ),
        ],
      );

      if (playlist.kind == ExternalPlaylistKind.youtube) {
        final matches = <PlaylistSourceMatch>[];
        for (var index = 0; index < playlist.tracks.length; index++) {
          final track = playlist.tracks[index];
          final videoId = track.sourceId;
          if (videoId == null || !TrackSourceRepository.isValidYoutubeVideoId(videoId)) continue;
          final unresolvedTrack = scan.unresolved[index];
          final candidate = YoutubeSearchCandidate(
            title: track.title,
            uploader: track.artistLabel,
            url: TrackSourceRepository.canonicalUrlFor(videoId),
            videoId: videoId,
            durationSeconds: track.duration?.inSeconds,
            thumbnailUrl: TrackSourceRepository.thumbnailUrlFor(videoId),
          );
          matches.add(
            PlaylistSourceMatch(
              track: unresolvedTrack,
              query: unresolvedTrack.searchQuery,
              candidates: [candidate],
              selected: candidate,
            ),
          );
        }
        if (matches.isEmpty) {
          throw const ExternalPlaylistException('This YouTube playlist has no importable public videos.');
        }
        setState(() {
          _matches = List.unmodifiable(matches);
          _stage = _ExternalImportStage.choosing;
        });
        return;
      }

      List<PlaylistSourceMatch>? confirmedMatches;
      final confirmed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => PlaylistSourceResolutionScreen(
            scan: scan,
            matchingTitle: 'Matching ${playlist.kind.label} Playlist',
            reviewTitle: 'Review ${playlist.kind.label} Matches',
            cancelLabel: 'Cancel import',
            finishLabel: 'Confirm selection',
            onConfirmed: (matches) async {
              if (!matches.any((match) => !match.skipped && match.selected != null)) {
                throw StateError('Select at least one YouTube result before importing.');
              }
              confirmedMatches = List<PlaylistSourceMatch>.from(matches);
            },
          ),
        ),
      );
      if (!mounted) return;
      if (confirmed == true && confirmedMatches != null) {
        setState(() {
          _matches = confirmedMatches!;
          _stage = _ExternalImportStage.choosing;
        });
      } else {
        setState(() => _stage = _ExternalImportStage.input);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is YoutubeFailure ? error.userMessage : error.toString();
        _stage = _ExternalImportStage.error;
      });
      if (error is YoutubeFailure && error.isAccessFailure) {
        unawaited(showYoutubeFailure(context, error, sourceUrl: _urlController.text.trim()));
      }
    }
  }

  Future<void> _startImport(YoutubePlaylistImportMode mode) async {
    final playlist = _playlist!;
    final entries = <YoutubePlaylistImportEntry>[
      for (final match in _matches)
        if (!match.skipped && match.selected != null)
          YoutubePlaylistImportEntry(
            videoId: match.selected!.videoId,
            title: match.selected!.title,
            artist: match.selected!.uploader,
            thumbnailUrl: match.selected!.thumbnailUrl,
          ),
    ];
    setState(() {
      _stage = _ExternalImportStage.importing;
      _stopRequested = false;
      _progressCompleted = 0;
      _progressTotal = entries.map((entry) => entry.videoId).toSet().length;
      _progressPercentage = 0;
      _progressStatus = mode == YoutubePlaylistImportMode.download ? 'Preparing downloads…' : 'Preparing streams…';
    });
    try {
      final result = await _importer.importPlaylist(
        playlistName: playlist.name,
        entries: entries,
        mode: mode,
        isCancelled: () => _stopRequested,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _progressCompleted = progress.completed;
            _progressTotal = progress.total;
            _progressTrack = '${progress.entry.artist} — ${progress.entry.title}';
            _progressStatus = progress.status;
            _progressPercentage = progress.percentage;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _ExternalImportStage.complete;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is YoutubeFailure ? error.userMessage : error.toString();
        _stage = _ExternalImportStage.error;
      });
      if (error is YoutubeFailure && error.isAccessFailure) {
        unawaited(showYoutubeFailure(context, error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _ExternalImportStage.fetching || _stage == _ExternalImportStage.importing;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Cross-Website Playlist Import'),
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: busy ? null : () => Navigator.pop(context, _stage == _ExternalImportStage.complete),
          ),
        ),
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() => switch (_stage) {
    _ExternalImportStage.input => _buildInput(),
    _ExternalImportStage.fetching => _progressCard(
      icon: Icons.cloud_download_outlined,
      title: 'Reading playlist metadata',
      status: 'Connecting to the playlist website…',
    ),
    _ExternalImportStage.choosing => _buildChoice(),
    _ExternalImportStage.importing => _buildImportProgress(),
    _ExternalImportStage.complete => _buildComplete(),
    _ExternalImportStage.error => _buildError(),
  };

  Widget _buildInput() => _card(
    title: 'YouTube, Spotify, or Audiomack',
    children: [
      const Icon(Icons.library_music_rounded, size: 62),
      const SizedBox(height: 16),
      const Text(
        'Paste a public playlist link. YouTube and YouTube Music playlists keep their exact videos and order. Spotify and Audiomack tracks are matched on YouTube for your review.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _urlController,
        autofocus: true,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _fetchAndReview(),
        decoration: const InputDecoration(
          labelText: 'Playlist link',
          hintText: 'https://music.youtube.com/playlist?list=…',
          prefixIcon: Icon(Icons.link_rounded),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _fetchAndReview,
        icon: const Icon(Icons.manage_search_rounded),
        label: const Text('Find Tracks'),
      ),
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
    ],
  );

  Widget _buildChoice() {
    final playlist = _playlist!;
    final selected = _matches.where((match) => !match.skipped && match.selected != null).length;
    return _card(
      title: 'Import “${playlist.name}”',
      children: [
        _metric('Source', playlist.kind.label),
        _metric('Playlist entries', playlist.tracks.length.toString()),
        _metric('Confirmed YouTube matches', selected.toString()),
        _metric('Skipped or unresolved', (playlist.tracks.length - selected).toString()),
        const Divider(height: 30),
        FilledButton.icon(
          onPressed: () => _startImport(YoutubePlaylistImportMode.download),
          icon: const Icon(Icons.download_for_offline_rounded),
          label: const Text('Download Tracks'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _startImport(YoutubePlaylistImportMode.stream),
          icon: const Icon(Icons.sensors_rounded),
          label: const Text('Stream From Playlist'),
        ),
        const SizedBox(height: 8),
        Text(
          'Downloads reuse matching local files when possible. Streaming adds YouTube URLs without downloading audio.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildImportProgress() {
    final overall = _progressTotal == 0 ? null : _progressCompleted / _progressTotal;
    return _progressCard(
      icon: Icons.sync_rounded,
      title: 'Creating Resonance playlist',
      status: _progressStatus,
      detail: _progressTrack,
      overall: overall,
      itemProgress: _progressPercentage > 0 && _progressPercentage < 100 ? _progressPercentage / 100 : null,
      action: OutlinedButton.icon(
        onPressed: _stopRequested ? null : () => setState(() => _stopRequested = true),
        icon: const Icon(Icons.stop_circle_outlined),
        label: Text(_stopRequested ? 'Stopping after current track…' : 'Stop after current track'),
      ),
    );
  }

  Widget _buildComplete() {
    final result = _result!;
    return _card(
      title: 'Import complete',
      children: [
        Icon(
          result.cancelled ? Icons.stop_circle_rounded : Icons.check_circle_rounded,
          size: 66,
          color: result.cancelled ? Colors.orange : Colors.green,
        ),
        const SizedBox(height: 14),
        Text(
          result.cancelled
              ? 'Import stopped; “${result.playlistName}” was created with the tracks already prepared.'
              : '“${result.playlistName}” was created.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        _metric('Playlist entries', result.playlistEntries.toString()),
        _metric('Downloaded', result.downloaded.toString()),
        _metric('Reused locally', result.reusedLocally.toString()),
        _metric('Streams added', result.streamed.toString()),
        _metric('Skipped after failures', result.skippedEntries.toString()),
        if (result.failures.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            '${result.failures.length} unique track${result.failures.length == 1 ? '' : 's'} failed; the rest were imported.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          for (final failure in result.failures.entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.error_outline_rounded),
              title: Text(failure.key),
              subtitle: Text(failure.value, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
        ],
        const SizedBox(height: 18),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')),
      ],
    );
  }

  Widget _buildError() => _card(
    title: 'Import could not continue',
    children: [
      Icon(Icons.error_outline_rounded, size: 58, color: Theme.of(context).colorScheme.error),
      const SizedBox(height: 14),
      Text(_error ?? 'Unknown import error', textAlign: TextAlign.center),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: () =>
            setState(() => _stage = _playlist == null ? _ExternalImportStage.input : _ExternalImportStage.choosing),
        child: const Text('Try Again'),
      ),
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
    ],
  );

  Widget _progressCard({
    required IconData icon,
    required String title,
    required String status,
    String detail = '',
    double? overall,
    double? itemProgress,
    Widget? action,
  }) => _card(
    title: title,
    children: [
      Icon(icon, size: 58),
      const SizedBox(height: 18),
      LinearProgressIndicator(value: overall),
      if (itemProgress != null) ...[const SizedBox(height: 8), LinearProgressIndicator(value: itemProgress)],
      const SizedBox(height: 14),
      Text(status, textAlign: TextAlign.center),
      if (detail.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(detail, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
      ],
      if (action != null) ...[const SizedBox(height: 18), action],
    ],
  );

  Widget _card({required String title, required List<Widget> children}) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
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
        Flexible(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    ),
  );
}
