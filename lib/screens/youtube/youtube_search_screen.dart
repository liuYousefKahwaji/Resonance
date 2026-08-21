import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/models/download_queue_entry.dart';
import 'package:resonance/screens/external_playlist/external_playlist_import_screen.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/services/external_playlist_service.dart';
import 'package:resonance/services/youtube_stats_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/suggested_music_service.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/widgets/youtube/android_youtube.dart';
import 'package:resonance/widgets/youtube/download_queue_panel.dart';
import 'package:resonance/widgets/youtube/windows_youtube.dart';
import 'package:resonance/app/resonance_motion.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/widgets/youtube/youtube_failure_dialog.dart';

typedef YoutubeSearchLoader = Future<List<YoutubeTrack>> Function(String input, int limit);
typedef YoutubeSuggestionsLoader =
    Future<SuggestedMusicResult> Function({required bool refresh, required bool Function() isCancelled});

class YoutubeSearchScreen extends StatefulWidget {
  final int playlistNumber;
  final String playlistName;
  final String? initialQuery;
  final String? recognitionLabel;
  final YoutubeSearchLoader? searchLoader;
  final YoutubeSuggestionsLoader? suggestionsLoader;
  final Duration previewDelay;

  const YoutubeSearchScreen({
    super.key,
    required this.playlistNumber,
    required this.playlistName,
    this.initialQuery,
    this.recognitionLabel,
    this.searchLoader,
    this.suggestionsLoader,
    this.previewDelay = const Duration(milliseconds: 500),
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
  PlaylistProfile? _suggestionProfile;
  List<YoutubeTrack> _suggestionTracks = const [];
  bool _suggestionLoading = false;
  String? _suggestionError;
  int _refreshGeneration = 0;
  int _searchGeneration = 0;
  int _suggestionGeneration = 0;
  int _statsGeneration = 0;
  Timer? _previewTimer;
  bool _waitingForPreview = false;

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
    _previewTimer?.cancel();
    _searchGeneration++;
    _suggestionGeneration++;
    _statsGeneration++;
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _previewTimer?.cancel();
    final input = _controller.text.trim();
    final generation = ++_searchGeneration;
    _statsGeneration++;
    if (input.isNotEmpty) {
      if (Platform.isWindows) _windows.cancelBackgroundSearches();
      _suggestionGeneration++;
      if (mounted) {
        setState(() {
          _loading = false;
          _waitingForPreview = true;
          _suggestionLoading = false;
          _results = const [];
          _error = null;
        });
      }
      _previewTimer = Timer(widget.previewDelay, () => unawaited(_loadPreview(input, generation)));
      return;
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _waitingForPreview = false;
        _results = const [];
        _error = null;
      });
    }
    if (_suggestionProfile == null && !_suggestionLoading) _loadSuggestions();
  }

  Future<void> _loadSuggestions({bool refresh = false}) async {
    if (_controller.text.trim().isNotEmpty) return;
    if (refresh) _refreshGeneration++;
    final generation = ++_suggestionGeneration;
    setState(() {
      _suggestionLoading = true;
      _suggestionError = null;
      if (refresh) _suggestionTracks = const [];
    });
    try {
      bool isCancelled() => !mounted || generation != _suggestionGeneration || _controller.text.trim().isNotEmpty;
      final override = widget.suggestionsLoader;
      late final SuggestedMusicResult result;
      if (override != null) {
        result = await override(refresh: refresh, isCancelled: isCancelled);
      } else {
        final currentTrackId = context.read<PlayerHandler>().mediaItem.value?.id;
        final profile = await _profileBuilder.build(
          playlistNumber: widget.playlistNumber,
          playlistName: widget.playlistName,
          currentTrackId: currentTrackId,
        );
        if (isCancelled()) return;
        if (profile.isEmpty) {
          setState(() {
            _suggestionProfile = profile;
            _suggestionTracks = const [];
            _suggestionLoading = false;
          });
          return;
        }
        if (Platform.isWindows) await _windows.initBinaries();
        result = await _suggestions.generate(
          profile: profile,
          refreshGeneration: _refreshGeneration,
          search: Platform.isWindows
              ? (query) => _windows.search(query, background: true)
              : (query) => _android.search(query),
          isCancelled: isCancelled,
        );
      }
      if (isCancelled()) return;
      setState(() {
        _suggestionProfile = result.profile;
        _suggestionTracks = result.tracks;
        _suggestionLoading = false;
      });
      unawaited(_hydrateStats(result.tracks, suggestions: true));
    } on SuggestedMusicCancelled {
      if (mounted && generation == _suggestionGeneration) {
        setState(() => _suggestionLoading = false);
      }
      return;
    } catch (error) {
      if (!mounted || generation != _suggestionGeneration || _controller.text.trim().isNotEmpty) return;
      debugPrint('Suggested Music failed: $error');
      setState(() {
        _suggestionLoading = false;
        _suggestionError = error is YoutubeFailure
            ? error.userMessage
            : 'Could not build suggestions right now. Check the connection and try again.';
      });
      if (error is YoutubeFailure && error.isAccessFailure) {
        unawaited(showYoutubeFailure(context, error));
      }
    }
  }

  bool _isLink(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
  }

  Future<List<YoutubeTrack>> _search(String input, {int limit = 10}) async {
    final loader = widget.searchLoader;
    if (loader != null) return loader(input, limit);
    if (Platform.isWindows) {
      _windows.cancelBackgroundSearches();
      await _windows.initBinaries();
    }
    if (_isLink(input)) {
      return [await (Platform.isWindows ? _windows.lookup(input) : _android.lookup(input))];
    }
    return Platform.isWindows ? _windows.search(input, limit: limit) : _android.search(input, limit: limit);
  }

  Future<void> _loadPreview(String input, int generation) async {
    if (!mounted || generation != _searchGeneration || input != _controller.text.trim()) return;
    try {
      final results = await _search(input, limit: 2);
      if (!mounted || generation != _searchGeneration || input != _controller.text.trim()) return;
      setState(() {
        _results = results.take(2).toList(growable: false);
        _waitingForPreview = false;
      });
      unawaited(_hydrateStats(_results, suggestions: false));
    } catch (_) {
      if (!mounted || generation != _searchGeneration || input != _controller.text.trim()) return;
      setState(() => _waitingForPreview = false);
    }
  }

  Future<void> _submit() async {
    final input = _controller.text.trim();
    if (input.isEmpty || _loading) return;
    _previewTimer?.cancel();
    final generation = ++_searchGeneration;
    _statsGeneration++;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _waitingForPreview = false;
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
      final results = await _search(input);
      if (mounted && generation == _searchGeneration && input == _controller.text.trim()) {
        setState(() => _results = results.take(10).toList(growable: false));
        unawaited(_hydrateStats(_results, suggestions: false));
      }
    } catch (error) {
      if (mounted && generation == _searchGeneration && input == _controller.text.trim()) {
        final failure = error is YoutubeFailure
            ? error
            : YoutubeFailureClassifier.classify(
                error,
                authenticated: YoutubeAccessService.active?.isConfigured ?? false,
                sourceUrl: _isLink(input) ? input : null,
              );
        setState(() => _error = failure.userMessage);
        if (failure.isAccessFailure) {
          unawaited(showYoutubeFailure(context, failure, sourceUrl: failure.sourceUrl));
        }
      }
    } finally {
      if (mounted && generation == _searchGeneration) setState(() => _loading = false);
    }
  }

  Future<void> _hydrateStats(List<YoutubeTrack> tracks, {required bool suggestions}) async {
    // An injected search backend owns its metadata contract as well. This is
    // important for deterministic tests and for embedders that do not ship
    // Resonance's native yt-dlp binaries.
    if (tracks.isEmpty || widget.searchLoader != null) return;
    final generation = ++_statsGeneration;
    try {
      late List<YoutubeTrack> hydrated;
      if (Platform.isWindows) {
        hydrated = await _windows.hydrateStats(tracks);
      } else {
        hydrated = tracks;
      }
      hydrated = await const YoutubeStatsService().hydrateAll(hydrated);
      if (!mounted || generation != _statsGeneration) return;
      final byUrl = {for (final track in hydrated) track.url: track};
      setState(() {
        if (suggestions) {
          _suggestionTracks = [for (final track in _suggestionTracks) byUrl[track.url] ?? track];
        } else {
          _results = [for (final track in _results) byUrl[track.url] ?? track];
        }
      });
    } catch (error) {
      debugPrint('YouTube statistics hydration failed: $error');
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
      if (mounted) await showYoutubeFailure(context, error, sourceUrl: track.url, actionLabel: 'Could not play stream');
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
      if (!mounted) return;
      if (DownloadQueueController.instance.queueMode) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${track.title} added to ${widget.playlistName}')));
      } else {
        Navigator.pop(context, track.url);
      }
    } catch (error) {
      if (mounted) await showYoutubeFailure(context, error, sourceUrl: track.url, actionLabel: 'Could not add stream');
    } finally {
      if (mounted) setState(() => _busyUrl = null);
    }
  }

  Future<void> _download(YoutubeTrack track) async {
    final queue = DownloadQueueController.instance;
    if (queue.queueMode) {
      unawaited(queue.enqueue(track, widget.playlistNumber).catchError((_) => null));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${track.title} queued')));
      return;
    }
    if (_busyUrl != null) return;
    setState(() => _busyUrl = track.url);
    try {
      final addedTrack = await queue.enqueue(track, widget.playlistNumber);
      if (mounted) Navigator.pop(context, addedTrack);
    } catch (error) {
      if (mounted) await showYoutubeFailure(context, error, sourceUrl: track.url, actionLabel: 'Download failed');
    } finally {
      if (mounted) {
        setState(() => _busyUrl = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.recognitionLabel == null ? 'Search' : 'Song identified'),
        actions: [
          AnimatedBuilder(
            animation: DownloadQueueController.instance,
            builder: (context, _) => IconButton(
              key: const Key('download-queue-toggle'),
              tooltip: DownloadQueueController.instance.queueMode ? 'Disable download queue' : 'Enable download queue',
              onPressed: () =>
                  DownloadQueueController.instance.setQueueMode(!DownloadQueueController.instance.queueMode),
              icon: Badge(
                isLabelVisible: DownloadQueueController.instance.pendingCount > 0,
                label: Text('${DownloadQueueController.instance.pendingCount}'),
                child: Icon(
                  DownloadQueueController.instance.queueMode
                      ? Icons.playlist_add_check_circle_rounded
                      : Icons.playlist_add_rounded,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
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
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: AnimatedBuilder(
          animation: DownloadQueueController.instance,
          builder: (context, _) {
            final queue = DownloadQueueController.instance;
            final showQueue = queue.queueMode;
            final search = Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: TextField(
                    key: const Key('youtube-search-field'),
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _submit(),
                    onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
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
                if (Platform.isAndroid && showQueue)
                  InkWell(
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => DraggableScrollableSheet(
                        expand: false,
                        initialChildSize: .55,
                        minChildSize: .25,
                        maxChildSize: .92,
                        builder: (_, __) => DownloadQueuePanel(controller: queue),
                      ),
                    ),
                    child: DownloadQueuePanel(controller: queue, compact: true),
                  ),
              ],
            );
            if (Platform.isWindows && showQueue) {
              return Row(
                children: [
                  Expanded(child: search),
                  VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
                  SizedBox(width: 330, child: DownloadQueuePanel(controller: queue)),
                ],
              );
            }
            return search;
          },
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_controller.text.trim().isEmpty && widget.recognitionLabel == null) return _buildSuggestions();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _MessageState(icon: Icons.error_outline_rounded, title: 'Search failed', message: _error!);
    }
    if (_waitingForPreview) return const SizedBox.shrink();
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
      final pending = DownloadQueueController.instance.pendingEntryFor(track.url, widget.playlistNumber);
      final card = _ResultCard(
        track: track,
        busy: _busyUrl == track.url,
        queued: pending != null,
        downloading: pending?.status == DownloadQueueStatus.downloading,
        progress: pending?.progress ?? 0,
        onPlay: () => _play(track),
        onStream: () => _stream(track),
        onDownload: () => _download(track),
      );
      return TweenAnimationBuilder<double>(
        key: ValueKey('result-${track.url}'),
        duration: resonanceDuration(
          context,
          index < 8 ? resonanceMotion(context).contentTransition + Duration(milliseconds: index * 35) : Duration.zero,
        ),
        curve: resonanceMotion(context).emphasizedCurve,
        tween: Tween(begin: 0, end: 1),
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(offset: Offset(0, 14 * (1 - value)), child: child),
        ),
        child: card,
      );
    },
  );
}

class _ResultCard extends StatelessWidget {
  final YoutubeTrack track;
  final bool busy;
  final bool queued;
  final bool downloading;
  final double progress;
  final VoidCallback onPlay;
  final VoidCallback onStream;
  final VoidCallback onDownload;

  const _ResultCard({
    required this.track,
    required this.busy,
    required this.queued,
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
                const SizedBox(height: 8),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  children: [
                    _StatLabel(icon: Icons.visibility_rounded, value: track.formattedViewCount, label: 'views'),
                    _StatLabel(icon: Icons.thumb_up_alt_rounded, value: track.formattedLikeCount, label: 'likes'),
                  ],
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
                      onPressed: busy || queued ? null : onDownload,
                      icon: Icon(
                        queued
                            ? downloading
                                  ? Icons.downloading_rounded
                                  : Icons.schedule_rounded
                            : Icons.download_rounded,
                      ),
                      label: Text(
                        queued
                            ? downloading
                                  ? 'Downloading'
                                  : 'Queued'
                            : 'Download',
                      ),
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

class _StatLabel extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatLabel({required this.icon, required this.value, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
      const SizedBox(width: 5),
      Text('$value $label', style: Theme.of(context).textTheme.labelMedium),
    ],
  );
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
