import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/youtube_artist.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/services/youtube/youtube_artist_service.dart';
import 'package:resonance/services/youtube_stats_service.dart';
import 'package:resonance/widgets/youtube/youtube_failure_dialog.dart';

typedef YoutubeArtistLoader = Future<YoutubeArtistPage> Function(YoutubeArtistSort sort, YoutubeArtistCursor? cursor);
typedef YoutubeArtistPlay = Future<void> Function(YoutubeTrack selected, List<YoutubeTrack> queue);

Future<void> openYoutubeArtist(
  BuildContext context,
  YoutubeTrack seed, {
  YoutubeArtistPlay? onPlay,
  bool returnToPlayer = false,
}) => Navigator.push<void>(
  context,
  MaterialPageRoute(
    builder: (_) => YoutubeArtistScreen(
      seed: seed,
      onPlay:
          onPlay ??
          (selected, tracks) async {
            final handler = context.read<PlayerHandler>();
            final seen = <String>{};
            final queue = [
              for (final track in tracks)
                if (seen.add(track.url))
                  StandaloneStreamQueueItem(
                    url: track.url,
                    title: track.title,
                    artist: track.artist,
                    thumbnailUrl: track.thumbnailUrl,
                  ),
            ];
            final playback = handler.playStandaloneStream(
              url: selected.url,
              title: selected.title,
              artist: selected.artist,
              thumbnailUrl: selected.thumbnailUrl,
              queueItems: queue,
              queueIndex: queue.indexWhere((item) => item.url == selected.url),
              relatedQueue: false,
            );
            if (returnToPlayer) {
              if (context.mounted) Navigator.pop(context);
              try {
                await playback;
              } catch (error) {
                if (context.mounted && handler.mediaItem.value?.id == selected.url) {
                  await showYoutubeFailure(
                    context,
                    error,
                    sourceUrl: selected.url,
                    actionLabel: context.tr('Could not play stream'),
                  );
                }
              }
              return;
            }
            final route = MaterialPageRoute<void>(builder: (_) => const StandalonePlayerScreen());
            final player = Navigator.push(context, route);
            try {
              await playback;
            } catch (_) {
              if (context.mounted && route.isCurrent) Navigator.pop(context);
              await player;
              rethrow;
            }
            await player;
          },
    ),
  ),
);

class YoutubeArtistScreen extends StatefulWidget {
  const YoutubeArtistScreen({super.key, required this.seed, required this.onPlay, this.loader, this.statsLoader});
  final YoutubeTrack seed;
  final YoutubeArtistPlay onPlay;
  final YoutubeArtistLoader? loader;
  final Future<YoutubeTrack> Function(YoutubeTrack track)? statsLoader;
  @override
  State<YoutubeArtistScreen> createState() => _YoutubeArtistScreenState();
}

class _YoutubeArtistScreenState extends State<YoutubeArtistScreen> {
  YoutubeArtistService _service = YoutubeArtistService();
  final _scroll = ScrollController();
  YoutubeArtistSort _sort = YoutubeArtistSort.newest;
  YoutubeArtistPage? _page;
  List<YoutubeTrack> _tracks = [];
  bool _loading = true, _loadingMore = false;
  Object? _error, _moreError;
  int _generation = 0;
  int _playGeneration = 0;
  String? _playingUrl;
  final _statsPending = <String, YoutubeTrack>{};
  final _statsAttempted = <String>{};
  int _statsRunning = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _service.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({YoutubeArtistSort? sort}) async {
    if (sort != null) _sort = sort;
    final generation = ++_generation;
    _service.cancel();
    _service = YoutubeArtistService();
    _statsPending.clear();
    _statsAttempted.clear();
    setState(() {
      _loading = true;
      _error = null;
      _moreError = null;
      _loadingMore = false;
      _tracks = [];
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    try {
      final page = await (widget.loader?.call(_sort, null) ?? _service.fetch(widget.seed, _sort));
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = page;
        _tracks = page.tracks.toList();
        _loading = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    final page = _page;
    if (_loading || _loadingMore || page?.next == null) return;
    final generation = _generation;
    final sort = _sort;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final next =
          await (widget.loader?.call(sort, page!.next) ??
              _service.fetch(
                widget.seed,
                sort,
                cursor: page!.next,
                artist: page.artist,
                availableSorts: page.availableSorts,
              ));
      if (!mounted || generation != _generation) return;
      final seen = _tracks.map((track) => track.videoId).toSet();
      setState(() {
        _tracks.addAll(next.tracks.where((track) => seen.add(track.videoId)));
        _page = next;
        _loadingMore = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loadingMore = false;
          _moreError = error;
        });
      }
    }
  }

  void _visibleStats(YoutubeTrack track) {
    if (track.viewCount != null && track.likeCount != null || !_statsAttempted.add(track.url)) return;
    _statsPending[track.url] = track;
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainStats());
  }

  void _drainStats() {
    if (!mounted) return;
    while (_statsRunning < 4 && _statsPending.isNotEmpty) {
      final track = _statsPending.remove(_statsPending.keys.first)!;
      final generation = _generation;
      _statsRunning++;
      unawaited(() async {
        try {
          final enriched = await (widget.statsLoader?.call(track) ?? const YoutubeStatsService().hydrate(track));
          if (mounted && generation == _generation) {
            setState(() {
              _tracks = [
                for (final current in _tracks)
                  current.url == track.url
                      ? current.copyWith(viewCount: enriched.viewCount, likeCount: enriched.likeCount)
                      : current,
              ];
            });
          }
        } catch (_) {
          // Unavailable engagement data does not make a playable row fail.
        } finally {
          _statsRunning--;
          _drainStats();
        }
      }());
    }
  }

  Future<void> _play(YoutubeTrack track, {bool shuffle = false}) async {
    final queue = _tracks.toList();
    if (shuffle) queue.shuffle(Random());
    final selected = shuffle ? queue.first : track;
    if (_playingUrl == selected.url) return;
    final generation = ++_playGeneration;
    setState(() => _playingUrl = selected.url);
    try {
      await widget.onPlay(selected, queue);
    } catch (error) {
      if (mounted && generation == _playGeneration) {
        await showYoutubeFailure(
          context,
          error,
          sourceUrl: selected.url,
          actionLabel: context.tr('Could not play stream'),
        );
      }
    } finally {
      if (mounted && generation == _playGeneration) setState(() => _playingUrl = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('Artist')),
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1280),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 760 && MediaQuery.textScalerOf(context).scale(14) <= 18;
                return NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.depth == 0 &&
                        notification is ScrollUpdateNotification &&
                        notification.scrollDelta != 0 &&
                        notification.metrics.extentAfter < 480 &&
                        _moreError == null) {
                      unawaited(_loadMore());
                    }
                    return false;
                  },
                  child: CustomScrollView(
                    controller: _scroll,
                    slivers: [
                      SliverToBoxAdapter(
                        child: _ArtistHeader(
                          profile: _page?.artist,
                          seed: widget.seed,
                          wide: wide,
                          enabled: !_loading && _tracks.isNotEmpty && _playingUrl == null,
                          onPlay: () => _play(_tracks.first),
                          onShuffle: () => _play(_tracks.first, shuffle: true),
                        ),
                      ),
                      SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 16),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 24),
                              Text(
                                context.tr('Songs & videos'),
                                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                children: [
                                  for (final sort in YoutubeArtistSort.values)
                                    Padding(
                                      padding: const EdgeInsetsDirectional.only(end: 18),
                                      child: Tooltip(
                                        message: context.tr(sort.label),
                                        child: InkWell(
                                          key: ValueKey('artist-sort-${sort.name}'),
                                          onTap:
                                              (_page == null || _page!.availableSorts.contains(sort)) && sort != _sort
                                              ? () => _load(sort: sort)
                                              : null,
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 180),
                                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
                                            decoration: BoxDecoration(
                                              border: Border(
                                                bottom: BorderSide(
                                                  width: 2,
                                                  color: sort == _sort ? theme.colorScheme.primary : Colors.transparent,
                                                ),
                                              ),
                                            ),
                                            child: Text(
                                              context.tr(sort.label),
                                              style: theme.textTheme.labelLarge?.copyWith(
                                                fontWeight: sort == _sort ? FontWeight.w800 : FontWeight.w500,
                                                color: sort == _sort
                                                    ? theme.colorScheme.primary
                                                    : (_page == null || _page!.availableSorts.contains(sort))
                                                    ? theme.colorScheme.onSurfaceVariant
                                                    : theme.disabledColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (wide && !_loading && _tracks.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsetsDirectional.fromSTEB(88, 0, 16, 8),
                                  child: Row(
                                    children: [
                                      Expanded(child: Text(context.tr('Title'), style: theme.textTheme.labelMedium)),
                                      SizedBox(
                                        width: 100,
                                        child: Text(context.tr('Views'), style: theme.textTheme.labelMedium),
                                      ),
                                      SizedBox(
                                        width: 86,
                                        child: Text(context.tr('Likes'), style: theme.textTheme.labelMedium),
                                      ),
                                      const SizedBox(width: 56),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (_loading)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                        )
                      else if (_error != null)
                        SliverToBoxAdapter(
                          child: _status(context.tr('Could not load this artist.'), retry: () => _load()),
                        )
                      else if (_tracks.isEmpty)
                        SliverToBoxAdapter(child: _status(context.tr('This artist has no public songs.')))
                      else
                        SliverPadding(
                          padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 12),
                          sliver: SliverList.builder(
                            itemCount: _tracks.length,
                            itemBuilder: (context, index) {
                              final track = _tracks[index];
                              _visibleStats(track);
                              return _ArtistTrackRow(
                                track: track,
                                wide: wide,
                                busy: _playingUrl == track.url,
                                onTap: _playingUrl != track.url ? () => _play(track) : null,
                              );
                            },
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 88,
                          child: Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator(strokeWidth: 2)
                                : _moreError != null
                                ? TextButton.icon(
                                    onPressed: _loadMore,
                                    icon: const Icon(Icons.refresh_rounded),
                                    label: Text(context.tr('Could not load more songs. Retry')),
                                  )
                                : _page?.next != null && !_loading
                                ? Text(context.tr('Scroll to load more'), style: theme.textTheme.bodySmall)
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _status(String message, {VoidCallback? retry}) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      children: [
        Icon(
          retry == null ? Icons.music_off_rounded : Icons.cloud_off_rounded,
          size: 36,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 14),
        Text(message, textAlign: TextAlign.center),
        if (retry != null) ...[
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(context.tr('Retry')),
          ),
        ],
      ],
    ),
  );
}

class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({
    required this.profile,
    required this.seed,
    required this.wide,
    required this.enabled,
    required this.onPlay,
    required this.onShuffle,
  });
  final YoutubeArtistProfile? profile;
  final YoutubeTrack seed;
  final bool wide, enabled;
  final VoidCallback onPlay, onShuffle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final avatar = profile?.avatarUrl;
    final banner = profile?.bannerUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: (wide ? 300 : 240) * MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.5),
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: colors.surfaceContainer, borderRadius: resonanceBorderRadius(context, 12)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [colors.primary.withValues(alpha: 0.35), colors.surfaceContainerHigh],
                  ),
                ),
              ),
              if (banner != null)
                Image.network(banner, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, theme.scaffoldBackgroundColor.withValues(alpha: 0.95)],
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(wide ? 32 : 20),
                child: Align(
                  alignment: AlignmentDirectional.bottomStart,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        width: wide ? 112 : 72,
                        height: wide ? 112 : 72,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: colors.surfaceContainerHigh),
                        child: avatar == null
                            ? Icon(Icons.person_rounded, size: wide ? 56 : 36, color: colors.primary)
                            : Image.network(
                                avatar,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    Icon(Icons.person_rounded, size: 36, color: colors.primary),
                              ),
                      ),
                      SizedBox(width: wide ? 24 : 16),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.tr('Artist'),
                              style: theme.textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              profile?.name ?? seed.artist,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineLarge?.copyWith(
                                fontSize: wide ? 48 : 30,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(wide ? 32 : 20, 16, wide ? 32 : 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (profile?.description.trim().isNotEmpty == true) ...[
                Text(
                  profile!.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
              ],
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: enabled ? onPlay : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(context.tr('Play')),
                  ),
                  OutlinedButton.icon(
                    onPressed: enabled ? onShuffle : null,
                    icon: const Icon(Icons.shuffle_rounded),
                    label: Text(context.tr('Shuffle')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArtistTrackRow extends StatelessWidget {
  const _ArtistTrackRow({required this.track, required this.wide, required this.busy, this.onTap});
  final YoutubeTrack track;
  final bool wide, busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Widget stat(IconData icon, String value, String label) => Tooltip(
      message: value == '—' ? context.tr('Count unavailable') : context.tr(label),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(value, style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
        ],
      ),
    );
    return Material(
      color: Colors.transparent,
      borderRadius: resonanceBorderRadius(context, 10),
      child: InkWell(
        key: ValueKey('artist-track-${track.videoId}'),
        borderRadius: resonanceBorderRadius(context, 10),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: wide ? 12 : 8, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: wide ? 60 : 52,
                height: wide ? 60 : 52,
                child: ClipRRect(
                  borderRadius: resonanceBorderRadius(context, 7),
                  child: track.thumbnailUrl == null
                      ? ColoredBox(color: colors.surfaceContainerHigh, child: const Icon(Icons.music_note_rounded))
                      : Image.network(
                          track.thumbnailUrl!,
                          fit: BoxFit.cover,
                          cacheWidth: 160,
                          errorBuilder: (_, __, ___) => ColoredBox(
                            color: colors.surfaceContainerHigh,
                            child: const Icon(Icons.music_note_rounded),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: wide ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (!wide) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 14,
                        runSpacing: 3,
                        children: [
                          stat(Icons.visibility_outlined, track.formattedViewCount, 'Views'),
                          stat(Icons.thumb_up_outlined, track.formattedLikeCount, 'Likes'),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (wide) ...[
                SizedBox(width: 100, child: stat(Icons.visibility_outlined, track.formattedViewCount, 'Views')),
                SizedBox(width: 86, child: stat(Icons.thumb_up_outlined, track.formattedLikeCount, 'Likes')),
              ],
              SizedBox(
                width: wide ? 56 : 42,
                child: busy
                    ? const Center(
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : Text(
                        track.formattedDuration,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
