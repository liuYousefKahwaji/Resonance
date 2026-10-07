import 'package:resonance/widgets/youtube/youtube_artist_link.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/core/youtube/youtube_music_home_models.dart';
import 'package:resonance/models/external_playlist.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/external_playlist_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/widgets/youtube/youtube_failure_dialog.dart';
import 'package:resonance/widgets/common/progressive_network_artwork.dart';

typedef YoutubeCollectionLoader = Future<ExternalPlaylist> Function(String url);

/// Browsing a Discover collection does not change the current audio source.
/// Only selecting a row hands its complete collection queue to the player.
class YoutubeCollectionScreen extends StatefulWidget {
  const YoutubeCollectionScreen({super.key, required this.item, required this.onPlay, this.loader});

  final YoutubeMusicHomeItem item;
  final YoutubeCollectionLoader? loader;
  final Future<void> Function(YoutubeTrack selected, List<YoutubeTrack> tracks) onPlay;

  @override
  State<YoutubeCollectionScreen> createState() => _YoutubeCollectionScreenState();
}

class _YoutubeCollectionScreenState extends State<YoutubeCollectionScreen> {
  List<YoutubeTrack> _tracks = const [];
  bool _loading = true;
  Object? _error;
  String? _playingUrl;
  int _generation = 0;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final url = widget.item.playlistUrl;
      if (url == null) throw const ExternalPlaylistException('This collection has no playlist link.');
      final playlist = await (widget.loader ?? ExternalPlaylistService().fetch)(url);
      final tracks = <YoutubeTrack>[
        for (final entry in playlist.tracks)
          if (entry.sourceId case final videoId?)
            if (TrackSourceRepository.isValidYoutubeVideoId(videoId))
              YoutubeTrack(
                title: entry.title,
                artist: entry.artistLabel,
                url: TrackSourceRepository.canonicalUrlFor(videoId),
                durationSeconds: entry.duration?.inSeconds,
                thumbnailUrl: TrackSourceRepository.thumbnailUrlFor(videoId),
              ),
      ];
      if (!mounted || generation != _generation) return;
      setState(() => _tracks = List.unmodifiable(tracks));
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _play(YoutubeTrack track, {List<YoutubeTrack>? queue}) async {
    if (_playingUrl != null) return;
    setState(() => _playingUrl = track.url);
    try {
      await widget.onPlay(track, queue ?? _tracks);
    } catch (error) {
      if (mounted) {
        await showYoutubeFailure(context, error, sourceUrl: track.url, actionLabel: context.tr("Could not play track"));
      }
    } finally {
      if (mounted) setState(() => _playingUrl = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isAlbum ? context.tr("Album") : context.tr("Playlist"), style: theme.textTheme.titleMedium),
        backgroundColor: theme.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(
        top: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(colors.primary.withValues(alpha: 0.14), theme.scaffoldBackgroundColor),
                theme.scaffoldBackgroundColor,
              ],
              stops: const [0, 0.65],
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1280),
                  child: wide ? _desktop(context) : _mobile(context),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  bool get _isAlbum => widget.item.kind.toLowerCase().contains('album');

  String get _metadata {
    if (_loading || _error != null) return 'YouTube Music';
    final pieces = <String>[
      context.tr('{0} {1}', [_tracks.length, context.tr(_tracks.length == 1 ? 'song' : 'songs')]),
    ];
    if (_tracks.isNotEmpty && _tracks.every((track) => track.durationSeconds != null)) {
      final duration = Duration(seconds: _tracks.fold<int>(0, (total, track) => total + track.durationSeconds!));
      if (duration.inHours > 0) {
        pieces.add(context.tr('{0} hr {1} min', [duration.inHours, duration.inMinutes % 60]));
      } else if (duration.inMinutes > 0) {
        pieces.add(context.tr('{0} min', [duration.inMinutes]));
      }
    }
    return pieces.join(' · ');
  }

  Widget _header(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final alignment = wide ? CrossAxisAlignment.start : CrossAxisAlignment.center;
    final textAlign = wide ? TextAlign.start : TextAlign.center;
    final canPlay = !_loading && _error == null && _tracks.isNotEmpty && _playingUrl == null;
    final art = widget.item.thumbnailUrl ?? (_tracks.isNotEmpty ? _tracks.first.thumbnailUrl : null);
    return Column(
      crossAxisAlignment: alignment,
      children: [
        Container(
          key: const Key('youtube-collection-cover'),
          width: wide ? 288 : 208,
          height: wide ? 288 : 208,
          decoration: BoxDecoration(
            borderRadius: resonanceBorderRadius(context, 12, rounderRadius: 22),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.20), blurRadius: 28, offset: const Offset(0, 12)),
            ],
          ),
          child: _CollectionArtwork(url: art, cover: true, album: _isAlbum),
        ),
        SizedBox(height: wide ? 28 : 22),
        Text(
          widget.item.title,
          textAlign: textAlign,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: wide ? 30 : 27,
            fontWeight: FontWeight.w800,
            height: 1.14,
            letterSpacing: -0.7,
          ),
        ),
        if (widget.item.subtitle.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            widget.item.subtitle,
            textAlign: textAlign,
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          _metadata,
          textAlign: textAlign,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 22),
        Wrap(
          alignment: wide ? WrapAlignment.start : WrapAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              key: const Key('youtube-collection-play'),
              onPressed: canPlay ? () => _play(_tracks.first) : null,
              style: FilledButton.styleFrom(minimumSize: const Size(116, 44), shape: const StadiumBorder()),
              icon: const Icon(Icons.play_arrow_rounded, size: 25),
              label: Text(context.tr("Play")),
            ),
            OutlinedButton.icon(
              key: const Key('youtube-collection-shuffle'),
              onPressed: canPlay
                  ? () {
                      final queue = [..._tracks]..shuffle(Random());
                      unawaited(_play(queue.first, queue: List.unmodifiable(queue)));
                    }
                  : null,
              style: OutlinedButton.styleFrom(minimumSize: const Size(116, 44), shape: const StadiumBorder()),
              icon: const Icon(Icons.shuffle_rounded, size: 19),
              label: Text(context.tr("Shuffle")),
            ),
          ],
        ),
      ],
    );
  }

  Widget _desktop(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(36, 18, 36, 28),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 300, child: SingleChildScrollView(child: _header(context, wide: true))),
        const SizedBox(width: 48),
        Expanded(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(18, 4, 18, 14),
                child: Row(
                  children: [
                    Expanded(child: Text(context.tr("Songs"), style: Theme.of(context).textTheme.titleMedium)),
                    Icon(Icons.schedule_rounded, size: 17, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
              Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35)),
              const SizedBox(height: 8),
              Expanded(
                child: _loading || _error != null || _tracks.isEmpty
                    ? _status(context)
                    : Scrollbar(
                        controller: _scrollController,
                        child: ListView.builder(
                          key: const Key('youtube-collection-tracklist'),
                          controller: _scrollController,
                          itemCount: _tracks.length,
                          itemBuilder: (context, index) => _row(index, wide: true),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _mobile(BuildContext context) => CustomScrollView(
    key: const Key('youtube-collection-tracklist'),
    controller: _scrollController,
    slivers: [
      SliverPadding(
        padding: const EdgeInsetsDirectional.fromSTEB(24, 12, 24, 28),
        sliver: SliverToBoxAdapter(child: _header(context, wide: false)),
      ),
      if (_loading || _error != null || _tracks.isEmpty)
        SliverFillRemaining(hasScrollBody: false, child: _status(context))
      else
        SliverPadding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 24),
          sliver: SliverList.builder(
            itemCount: _tracks.length,
            itemBuilder: (context, index) => _row(index, wide: false),
          ),
        ),
    ],
  );

  Widget _row(int index, {required bool wide}) => _CollectionTrackRow(
    key: ValueKey('youtube-collection-track-$index'),
    track: _tracks[index],
    index: index,
    wide: wide,
    busy: _playingUrl == _tracks[index].url,
    onTap: _playingUrl == null ? () => _play(_tracks[index]) : null,
  );

  Widget _status(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 36),
              const SizedBox(height: 16),
              Text(context.tr("Could not load this collection.")),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.tr("Retry")),
              ),
              TextButton(
                onPressed: () => showYoutubeFailure(
                  context,
                  _error!,
                  sourceUrl: widget.item.playlistUrl,
                  actionLabel: context.tr("Could not load collection"),
                ),
                child: Text(context.tr("Details")),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(context.tr("No playable songs in this collection."), textAlign: TextAlign.center),
      ),
    );
  }
}

class _CollectionArtwork extends StatelessWidget {
  const _CollectionArtwork({this.url, this.cover = false, this.album = false});
  final String? url;
  final bool cover;
  final bool album;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(colors.primary.withValues(alpha: 0.24), colors.surfaceContainer),
            colors.surfaceContainerHigh,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          cover ? (album ? Icons.album_rounded : Icons.library_music_rounded) : Icons.music_note_rounded,
          size: cover ? 64 : 22,
          color: colors.primary.withValues(alpha: cover ? 0.65 : 0.75),
        ),
      ),
    );
    final imageUrl = url?.trim();
    return ClipRRect(
      borderRadius: resonanceBorderRadius(context, cover ? 12 : 6, rounderRadius: cover ? 22 : 10),
      child: imageUrl == null || imageUrl.isEmpty
          ? fallback
          : cover
          ? ProgressiveNetworkArtwork(url: imageUrl, fallback: fallback, lowCacheSize: 360, highCacheSize: 800)
          : Image.network(
              imageUrl,
              fit: BoxFit.cover,
              cacheWidth: 120,
              cacheHeight: 120,
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }
}

class _CollectionTrackRow extends StatefulWidget {
  const _CollectionTrackRow({
    super.key,
    required this.track,
    required this.index,
    required this.wide,
    required this.busy,
    this.onTap,
  });
  final YoutubeTrack track;
  final int index;
  final bool wide;
  final bool busy;
  final VoidCallback? onTap;

  @override
  State<_CollectionTrackRow> createState() => _CollectionTrackRowState();
}

class _CollectionTrackRowState extends State<_CollectionTrackRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final track = widget.track;
    return Semantics(
      button: true,
      label: context.tr("Play {0} by {1}", [track.title, track.artist]),
      child: Material(
        color: widget.busy ? colors.primary.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: resonanceBorderRadius(context, 8, rounderRadius: 14),
        child: InkWell(
          onTap: widget.onTap,
          onHover: (value) => setState(() => _hovered = value),
          borderRadius: resonanceBorderRadius(context, 8, rounderRadius: 14),
          hoverColor: colors.onSurface.withValues(alpha: 0.045),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.wide ? 12 : 8, vertical: 10),
            child: Row(
              children: [
                if (widget.wide) ...[
                  SizedBox(
                    width: 28,
                    child: _hovered
                        ? Icon(Icons.play_arrow_rounded, size: 21, color: colors.onSurface)
                        : Text(
                            '${widget.index + 1}',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                          ),
                  ),
                  const SizedBox(width: 12),
                ],
                SizedBox.square(
                  dimension: 46,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _CollectionArtwork(url: track.thumbnailUrl),
                      if (widget.busy)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: resonanceBorderRadius(context, 6, rounderRadius: 10),
                          ),
                          child: const Center(
                            child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      YoutubeArtistLink(
                        track: track,
                        child: Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  track.formattedDuration,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
