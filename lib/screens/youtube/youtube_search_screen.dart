import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/screens/external_playlist/external_playlist_import_screen.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/services/external_playlist_service.dart';
import 'package:resonance/services/import_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/suggested_music_service.dart';
import 'package:resonance/widgets/youtube/android_youtube.dart';
import 'package:resonance/widgets/youtube/windows_youtube.dart';

class YoutubeSearchScreen extends StatefulWidget {
  final int playlistNumber;
  final String playlistName;
  final String? initialQuery;
  final String? recognitionLabel;

  const YoutubeSearchScreen({
    super.key,
    required this.playlistNumber,
    required this.playlistName,
    this.initialQuery,
    this.recognitionLabel,
  });

  @override
  State<YoutubeSearchScreen> createState() => _YoutubeSearchScreenState();
}

class _YoutubeSearchScreenState extends State<YoutubeSearchScreen> {
  final _controller = TextEditingController();
  final MediaDownloader _windows = MediaDownloader();
  final AndroidYoutubeDownloader _android = AndroidYoutubeDownloader();
  final SuggestedMusicService _suggestions = const SuggestedMusicService();
  final PlaylistProfileBuilder _profileBuilder = PlaylistProfileBuilder();
  List<YoutubeTrack> _results = const [];
  bool _loading = false;
  String? _error;
  String? _busyUrl;
  String? _downloadingUrl;
  double _progress = 0;
  PlaylistProfile? _suggestionProfile;
  List<YoutubeTrack> _suggestionTracks = const [];
  bool _suggestionLoading = false;
  String? _suggestionError;
  int _refreshGeneration = 0;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    final initialQuery = widget.initialQuery?.trim() ?? '';
    if (initialQuery.isNotEmpty) {
      _controller.text = initialQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadSuggestions();
      });
    }
  }

  @override
  void dispose() {
    _requestGeneration++;
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    final empty = _controller.text.trim().isEmpty;
    if (!empty) {
      _requestGeneration++;
      if (mounted) setState(() {});
      return;
    }
    if (mounted) setState(() {});
    if (!_suggestionLoading && _suggestionProfile == null) _loadSuggestions();
  }

  Future<void> _loadSuggestions({bool refresh = false}) async {
    if (_controller.text.trim().isNotEmpty) return;
    if (refresh) _refreshGeneration++;
    final generation = ++_requestGeneration;
    setState(() {
      _suggestionLoading = true;
      _suggestionError = null;
      if (refresh) _suggestionTracks = const [];
    });
    try {
      final currentTrackId = context.read<PlayerHandler>().mediaItem.value?.id;
      final profile = await _profileBuilder.build(
        playlistNumber: widget.playlistNumber,
        playlistName: widget.playlistName,
        currentTrackId: currentTrackId,
      );
      if (!mounted || generation != _requestGeneration || _controller.text.trim().isNotEmpty) return;
      if (profile.isEmpty) {
        setState(() {
          _suggestionProfile = profile;
          _suggestionTracks = const [];
          _suggestionLoading = false;
        });
        return;
      }
      if (Platform.isWindows) await _windows.initBinaries();
      final result = await _suggestions.generate(
        profile: profile,
        refreshGeneration: _refreshGeneration,
        search: Platform.isWindows ? _windows.search : _android.search,
        isCancelled: () => !mounted || generation != _requestGeneration || _controller.text.trim().isNotEmpty,
      );
      if (!mounted || generation != _requestGeneration || _controller.text.trim().isNotEmpty) return;
      setState(() {
        _suggestionProfile = result.profile;
        _suggestionTracks = result.tracks;
        _suggestionLoading = false;
      });
    } on SuggestedMusicCancelled {
      return;
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      debugPrint('Suggested Music failed: $error');
      setState(() {
        _suggestionLoading = false;
        _suggestionError = 'Could not build suggestions right now. Check the connection and try again.';
      });
    }
  }

  bool _isLink(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
  }

  Future<void> _submit() async {
    final input = _controller.text.trim();
    if (input.isEmpty || _loading) return;
    _requestGeneration++;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _results = const [];
    });
    try {
      final uri = Uri.tryParse(input);
      if (uri != null && YoutubePlaylistProvider.isPlaylistUri(uri)) {
        final imported = await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => ExternalPlaylistImportScreen(initialUrl: input, autoFetch: true)),
        );
        if (imported == true && mounted) Navigator.pop(context);
        return;
      }
      if (Platform.isWindows) await _windows.initBinaries();
      final results = _isLink(input)
          ? [await (Platform.isWindows ? _windows.lookup(input) : _android.lookup(input))]
          : await (Platform.isWindows ? _windows.search(input) : _android.search(input));
      if (mounted) setState(() => _results = results.take(10).toList(growable: false));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _rememberSource(YoutubeTrack track, TrackSourceMethod method, {String? localPath}) async {
    final id = TrackSourceRepository.videoIdFromUrlOrId(track.url);
    if (id == null) return;
    await const TrackSourceRepository().saveSource(
      localPath: localPath ?? track.url,
      youtubeVideoId: id,
      method: method,
      lastVerifiedAt: DateTime.now().toUtc(),
    );
  }

  Future<void> _play(YoutubeTrack track) async {
    if (_busyUrl != null) return;
    setState(() => _busyUrl = track.url);
    try {
      await _rememberSource(track, TrackSourceMethod.manuallySelected);
      if (!mounted) return;
      await context.read<PlayerHandler>().playStandaloneStream(
        url: track.url,
        title: track.title,
        artist: track.artist,
        thumbnailUrl: track.thumbnailUrl,
      );
      if (!mounted) return;
      await Navigator.push<String?>(
        context,
        PageRouteBuilder<String?>(
          pageBuilder: (_, __, ___) => const StandalonePlayerScreen(),
          transitionDuration: const Duration(milliseconds: 420),
          reverseTransitionDuration: const Duration(milliseconds: 420),
          transitionsBuilder: (_, animation, __, child) => FadeTransition(opacity: animation, child: child),
        ),
      );
    } catch (error) {
      if (mounted) _showError('Could not play stream: $error');
    } finally {
      if (mounted) setState(() => _busyUrl = null);
    }
  }

  Future<void> _stream(YoutubeTrack track) async {
    if (_busyUrl != null) return;
    setState(() => _busyUrl = track.url);
    try {
      await MetadataCacheService.set(track.url, track.title, track.artist, artworkUrl: track.thumbnailUrl);
      await _rememberSource(track, TrackSourceMethod.manuallySelected);
      await FileService().addToPlaylist(widget.playlistNumber, track.url);
      if (mounted) Navigator.pop(context, track.url);
    } catch (error) {
      if (mounted) _showError('Could not add stream: $error');
    } finally {
      if (mounted) setState(() => _busyUrl = null);
    }
  }

  Future<void> _download(YoutubeTrack track) async {
    if (_busyUrl != null) return;
    setState(() {
      _busyUrl = track.url;
      _downloadingUrl = track.url;
      _progress = 0;
    });
    String? addedTrack;
    try {
      if (Platform.isWindows) {
        await _windows.initBinaries();
        await _windows.downloadAudio(
          url: track.url,
          historyTitle: track.title,
          historyArtist: track.artist,
          onProgress: (value, _) {
            if (mounted) setState(() => _progress = value);
          },
          onTrackDownloaded: (path, videoId) async {
            await ImportService.importFiles([path], (_) {}, playlistNumber: widget.playlistNumber);
            addedTrack ??= path;
            if (videoId != null) {
              await const TrackSourceRepository().saveSource(
                localPath: path,
                youtubeVideoId: videoId,
                method: TrackSourceMethod.downloadedByResonance,
                lastVerifiedAt: DateTime.now().toUtc(),
              );
            }
          },
        );
      } else {
        final downloads = await _android.downloadAudio(
          track.url,
          historyTitle: track.title,
          historyArtist: track.artist,
          onProgress: (value, _) {
            if (mounted) setState(() => _progress = value);
          },
        );
        for (final download in downloads) {
          await ImportService.importFiles([download.localPath], (_) {}, playlistNumber: widget.playlistNumber);
          addedTrack ??= download.localPath;
          if (download.youtubeVideoId != null) {
            await const TrackSourceRepository().saveSource(
              localPath: download.localPath,
              youtubeVideoId: download.youtubeVideoId!,
              method: TrackSourceMethod.downloadedByResonance,
              lastVerifiedAt: DateTime.now().toUtc(),
            );
          }
        }
      }
      if (mounted) Navigator.pop(context, addedTrack);
    } catch (error) {
      if (mounted) _showError('Download failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busyUrl = null;
          _downloadingUrl = null;
          _progress = 0;
        });
      }
    }
  }

  void _showError(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message), backgroundColor: Theme.of(context).colorScheme.error));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.recognitionLabel == null ? 'Search' : 'Song identified'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              widget.recognitionLabel == null
                  ? 'Stream or download into ${widget.playlistName}'
                  : '${widget.recognitionLabel} · choose the best YouTube match',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Search YouTube or paste a link',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  onPressed: _loading ? null : _submit,
                  tooltip: 'Search',
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_controller.text.trim().isEmpty && widget.recognitionLabel == null) return _buildSuggestions();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _MessageState(icon: Icons.error_outline_rounded, title: 'Search failed', message: _error!);
    }
    if (_results.isEmpty) {
      return const _MessageState(
        icon: Icons.travel_explore_rounded,
        title: 'Find something to play',
        message: 'Paste a video link or search by song, artist, or album.',
      );
    }
    return _buildResults(_results);
  }

  Widget _buildSuggestions() {
    if (_suggestionLoading) {
      return const _MessageState(
        icon: Icons.auto_awesome_rounded,
        title: 'Finding Suggested Music',
        message: 'Building a profile from this playlist and ranking nearby music…',
        loading: true,
      );
    }
    final profile = _suggestionProfile;
    if (profile?.isEmpty == true) {
      return _MessageState(
        icon: Icons.playlist_add_rounded,
        title: 'Add songs first',
        message: 'Suggested Music uses the songs in ${widget.playlistName} to find related tracks.',
        actionLabel: 'Back to playlist',
        onAction: () => Navigator.pop(context),
      );
    }
    if (_suggestionError != null) {
      return _MessageState(
        icon: Icons.cloud_off_rounded,
        title: 'Suggestions unavailable',
        message: _suggestionError!,
        actionLabel: 'Retry',
        onAction: _loadSuggestions,
      );
    }
    if (_suggestionTracks.isEmpty) {
      return _MessageState(
        icon: Icons.music_off_rounded,
        title: 'No valid suggestions found',
        message: 'The candidate searches did not return enough playable music outside this playlist.',
        actionLabel: 'Try another set',
        onAction: () => _loadSuggestions(refresh: true),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Suggested Music', style: Theme.of(context).textTheme.titleLarge),
                    Text('Based on the songs in ${widget.playlistName}', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => _loadSuggestions(refresh: true),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Refresh suggestions'),
              ),
            ],
          ),
        ),
        Expanded(child: _buildResults(_suggestionTracks)),
      ],
    );
  }

  Widget _buildResults(List<YoutubeTrack> tracks) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
    itemCount: tracks.length,
    separatorBuilder: (_, __) => const SizedBox(height: 10),
    itemBuilder: (_, index) {
      final track = tracks[index];
      return _ResultCard(
        track: track,
        busy: _busyUrl == track.url,
        downloading: _downloadingUrl == track.url,
        progress: _downloadingUrl == track.url ? _progress : 0,
        onPlay: () => _play(track),
        onStream: () => _stream(track),
        onDownload: () => _download(track),
      );
    },
  );
}

class _ResultCard extends StatelessWidget {
  final YoutubeTrack track;
  final bool busy;
  final bool downloading;
  final double progress;
  final VoidCallback onPlay;
  final VoidCallback onStream;
  final VoidCallback onDownload;

  const _ResultCard({
    required this.track,
    required this.busy,
    required this.downloading,
    required this.progress,
    required this.onPlay,
    required this.onStream,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final safeProgress = progress.clamp(0.0, 100.0);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final thumbnail = _Thumbnail(url: track.thumbnailUrl);
          final details = Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  [track.artist, if (track.formattedDuration.isNotEmpty) track.formattedDuration].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: busy ? null : onPlay,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Play'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : onStream,
                      icon: const Icon(Icons.sensors_rounded),
                      label: const Text('Stream'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : onDownload,
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Download'),
                    ),
                  ],
                ),
                if (downloading) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: LinearProgressIndicator(value: safeProgress / 100)),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 52,
                        child: Text(
                          '${safeProgress.toStringAsFixed(1)}%',
                          textAlign: TextAlign.right,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          );
          if (compact) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [thumbnail, details]);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 240, child: thumbnail),
              Expanded(child: details),
            ],
          );
        },
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final String? url;

  const _Thumbnail({required this.url});

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      child: Icon(Icons.music_video_rounded, size: 48, color: Theme.of(context).colorScheme.primary),
    );
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: url == null ? fallback : Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback),
    );
  }
}

class _MessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox.square(dimension: 44, child: CircularProgressIndicator())
          else
            Icon(icon, size: 52, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onAction, icon: const Icon(Icons.refresh_rounded), label: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}
