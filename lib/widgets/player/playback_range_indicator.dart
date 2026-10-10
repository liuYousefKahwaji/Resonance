import 'dart:async';
import 'package:flutter/material.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_range.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'playback_range_dialog.dart';

String playbackRangeLabel(BuildContext context, PlaybackRange range) => context.tr('Trimmed: {0} – {1}', [
  playbackTimestamp(range.start),
  range.end == null ? context.tr('End of song') : playbackTimestamp(range.end!),
]);

class PlaybackRangeIndicator extends StatefulWidget {
  const PlaybackRangeIndicator({super.key, required this.handler, required this.path, required this.title});
  final PlayerHandler handler;
  final String path;
  final String title;
  @override
  State<PlaybackRangeIndicator> createState() => _PlaybackRangeIndicatorState();
}

class _PlaybackRangeIndicatorState extends State<PlaybackRangeIndicator> {
  PlaybackRange _range = PlaybackRange.full;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    widget.handler.playbackRangeRevision.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(covariant PlaybackRangeIndicator old) {
    super.didUpdateWidget(old);
    if (old.handler != widget.handler) {
      old.handler.playbackRangeRevision.removeListener(_load);
      widget.handler.playbackRangeRevision.addListener(_load);
    }
    if (old.path != widget.path || old.handler != widget.handler) {
      _range = PlaybackRange.full;
      _load();
    }
  }

  void _load() {
    final generation = ++_generation;
    unawaited(
      widget.handler
          .savedPlaybackRangeFor(widget.path)
          .then((range) {
            if (mounted && generation == _generation) setState(() => _range = range);
          })
          .catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    widget.handler.playbackRangeRevision.removeListener(_load);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _range.isFull
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsetsDirectional.only(start: 5),
          child: Tooltip(
            message: playbackRangeLabel(context, _range),
            child: InkResponse(
              onTap: () => showPlaybackRangeDialog(context, widget.handler, widget.path, widget.title),
              radius: 16,
              child: Icon(Icons.content_cut_rounded, size: 14, color: Theme.of(context).colorScheme.primary),
            ),
          ),
        );
}
