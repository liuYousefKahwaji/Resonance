import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/widgets/player/player_surface.dart';
import 'package:resonance/widgets/common/overflowing_text.dart';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/widgets/player/seek_bar.dart';
import 'package:resonance/widgets/player/volume_bar.dart';
import 'package:resonance/widgets/player/player_modes.dart';
import 'package:resonance/widgets/player/playback_settings.dart';
import 'package:resonance/widgets/common/track_link_menu.dart';

/// A small phone player and a balanced three-zone desktop transport.
class CompactPlayer extends StatelessWidget {
  const CompactPlayer({super.key, required this.handler, required this.onExpand, required this.onQueue});
  final PlayerHandler handler;
  final ValueChanged<String> onExpand;
  final VoidCallback onQueue;

  Widget _identity(BuildContext context, MediaItem item, bool wide, {bool marquee = false}) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onExpand(item.id),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          Container(
            width: wide ? 52 : 48,
            height: wide ? 52 : 48,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: colors.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
            child: item.artUri == null
                ? const Icon(Icons.music_note_rounded)
                : Image(
                    image: item.artUri!.scheme == 'file'
                        ? FileImage(File.fromUri(item.artUri!)) as ImageProvider
                        : NetworkImage(item.artUri.toString()),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.music_note_rounded),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (marquee)
                  OverflowingText(
                    text: item.title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  )
                else
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: wide ? 13 : 14, fontWeight: FontWeight.w600),
                  ),
                const SizedBox(height: 3),
                Text(
                  item.artist ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _phoneMini(BuildContext context, MediaItem item) => GestureDetector(
    key: const Key('compact-phone-player'),
    onVerticalDragEnd: (details) {
      if ((details.primaryVelocity ?? 0) < -180) onExpand(item.id);
    },
    child: Material(
      color: playerSurfaceColor(context),
      child: InkWell(
        onTap: () => onExpand(item.id),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 8, 8),
          child: Row(
            children: [
              Expanded(child: _identity(context, item, false, marquee: true)),
              const SizedBox(width: 4),
              IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                ),
                child: const PlaybackSettings(),
              ),
              ValueListenableBuilder<PlaybackVisualState>(
                valueListenable: handler.playbackVisualNotifier,
                builder: (context, state, _) => IconButton(
                  tooltip: context.tr(state.playing ? 'Pause' : 'Play'),
                  onPressed: handler.playPause,
                  color: Theme.of(context).colorScheme.onSurface,
                  iconSize: 32,
                  icon: Icon(state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _volumeAction(BuildContext context) => IconButton(
    tooltip: context.tr('Volume'),
    icon: const Icon(Icons.volume_up_rounded, size: 21),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => Provider<PlayerHandler>.value(
        value: handler,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.tr('Volume'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              const VolumeBar(),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _transport(BuildContext context, bool wide) => Directionality(
    textDirection: TextDirection.ltr,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (wide) ...[
          const PlayerModes(),
          const SizedBox(width: 12),
          IconButton(
            tooltip: context.tr('Previous'),
            onPressed: handler.previous,
            icon: const Icon(Icons.skip_previous_rounded, size: 25),
          ),
        ],
        ValueListenableBuilder<PlaybackVisualState>(
          valueListenable: handler.playbackVisualNotifier,
          builder: (context, state, _) => IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.onSurface,
              foregroundColor: Theme.of(context).colorScheme.surface,
              minimumSize: const Size(38, 38),
            ),
            tooltip: context.tr(state.playing ? 'Pause' : 'Play'),
            onPressed: handler.playPause,
            icon: Icon(state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 25),
          ),
        ),
        IconButton(
          tooltip: context.tr('Next'),
          onPressed: handler.next,
          icon: const Icon(Icons.skip_next_rounded, size: 25),
        ),
        if (wide) const SizedBox(width: 76),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => StreamBuilder<MediaItem?>(
    stream: handler.mediaItem,
    initialData: handler.mediaItem.value,
    builder: (context, snapshot) {
      final item = snapshot.data;
      if (item == null) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 850;
          final preferences = context.watch<ThemeProvider?>();
          if (!wide &&
              Theme.of(context).platform == TargetPlatform.android &&
              (preferences?.modernLayout ?? false) &&
              (preferences?.compactPlayerControls ?? true)) {
            return _phoneMini(context, item);
          }
          return DecoratedBox(
            decoration: BoxDecoration(
              color: playerSurfaceColor(context),
              border: Border(top: BorderSide(color: colors.onSurface.withValues(alpha: .08))),
            ),
            child: SafeArea(
              top: false,
              bottom: wide,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: wide ? 20 : 12, vertical: wide ? 10 : 0),
                child: wide
                    ? Row(
                        children: [
                          SizedBox(
                            width: (constraints.maxWidth * .25).clamp(210.0, 320.0),
                            child: Row(
                              children: [
                                Expanded(child: _identity(context, item, true)),
                                const PlaybackSettings(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _transport(context, true),
                                const SizedBox(height: 2),
                                const SeekBar(slim: true),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          SizedBox(
                            width: constraints.maxWidth >= 1100 ? 280 : 226,
                            child: Row(
                              children: [
                                Expanded(child: const VolumeBar()),
                                IconButton(
                                  tooltip: context.tr('Show queue'),
                                  onPressed: onQueue,
                                  icon: const Icon(Icons.queue_music_rounded, size: 21),
                                ),
                                if (constraints.maxWidth >= 1100) TrackLinkMenu(trackId: item.id),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                Expanded(child: _identity(context, item, false)),
                                const PlaybackSettings(),
                                IconButton(
                                  tooltip: context.tr('Show queue'),
                                  onPressed: onQueue,
                                  icon: const Icon(Icons.queue_music_rounded, size: 22),
                                ),
                                _volumeAction(context),
                              ],
                            ),
                          ),
                          const SeekBar(slim: true),
                          Padding(
                            padding: const EdgeInsets.only(top: 2, bottom: 6),
                            child: Directionality(
                              textDirection: TextDirection.ltr,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  const PlayerModes(showLoop: false),
                                  IconButton(
                                    tooltip: context.tr('Previous'),
                                    onPressed: handler.previous,
                                    icon: const Icon(Icons.skip_previous_rounded, size: 26),
                                  ),
                                  ValueListenableBuilder<PlaybackVisualState>(
                                    valueListenable: handler.playbackVisualNotifier,
                                    builder: (context, state, _) => IconButton.filled(
                                      style: IconButton.styleFrom(
                                        backgroundColor: colors.primary,
                                        foregroundColor: colors.onPrimary,
                                        fixedSize: const Size(48, 48),
                                        shape: const CircleBorder(),
                                      ),
                                      tooltip: context.tr(state.playing ? 'Pause' : 'Play'),
                                      onPressed: handler.playPause,
                                      icon: Icon(
                                        state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                        size: 27,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: context.tr('Next'),
                                    onPressed: handler.next,
                                    icon: const Icon(Icons.skip_next_rounded, size: 26),
                                  ),
                                  const PlayerModes(showShuffle: false),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          );
        },
      );
    },
  );
}
