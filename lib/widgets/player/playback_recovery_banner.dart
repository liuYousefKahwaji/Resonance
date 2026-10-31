import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_failure.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/youtube_search_source.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/screens/settings/youtube_access_screen.dart';
import 'package:resonance/widgets/common/resonance_dialog.dart';
import 'package:resonance/widgets/youtube/android_youtube.dart';
import 'package:resonance/widgets/youtube/windows_youtube.dart';

typedef RecoverySearch = Future<List<YoutubeTrack>> Function(String query, YoutubeSearchSource source);

/// Non-modal: choosing any other song stays possible during failure/retry.
class PlaybackRecoveryBanner extends StatelessWidget {
  const PlaybackRecoveryBanner({super.key, required this.handler, required this.navigatorKey});
  final PlayerHandler handler;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlaybackFailure?>(
    valueListenable: handler.playbackFailureNotifier,
    builder: (context, failure, _) {
      if (failure == null) return const SizedBox.shrink();
      final youtube = YoutubeTrack(title: '', artist: '', url: failure.track.id).videoId != null;
      final classified = !youtube
          ? YoutubeFailure(
              kind: YoutubeFailureKind.unknown,
              userMessage: 'Playback stopped. Check your connection and try again.',
              technicalSummary: YoutubeFailureClassifier.sanitize(failure.error.toString()),
            )
          : failure.error is YoutubeFailure
          ? failure.error as YoutubeFailure
          : YoutubeFailureClassifier.classify(failure.error, sourceUrl: failure.track.id);
      final colors = Theme.of(context).colorScheme;
      BuildContext? routeContext() => navigatorKey.currentState?.overlay?.context;
      return Material(
        color: colors.surfaceContainerHigh,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline_rounded, color: colors.error, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.tr('Could not play “{0}”.', [failure.track.title]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            context.tr(classified.userMessage),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => handler.dismissPlaybackFailure(failure),
                      icon: Icon(Icons.close_rounded, size: 18, semanticLabel: context.tr('Dismiss')),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton(
                      onPressed: () => unawaited(handler.retryFailedPlayback(failure)),
                      child: Text(context.tr('Retry')),
                    ),
                    if (youtube)
                      TextButton(
                        onPressed: () async {
                          final host = routeContext();
                          if (host == null) return;
                          final chosen = await showResonanceDialog<YoutubeTrack>(
                            context: host,
                            builder: (_) => PlaybackAlternativeDialog(
                              failed: failure.track.id,
                              query: '${failure.track.artist ?? ''} ${failure.track.title}'.trim(),
                            ),
                          );
                          if (chosen == null || !handler.isCurrentPlaybackFailure(failure)) return;
                          try {
                            await handler.playFailureAlternative(failure, chosen);
                          } catch (_) {
                            // The new failure is published by PlayerHandler, preserving its queue.
                          }
                        },
                        child: Text(context.tr('Find another upload')),
                      ),
                    if (classified.isAccessFailure)
                      TextButton(
                        onPressed: () {
                          final host = routeContext();
                          if (host != null) {
                            Navigator.of(host).push(
                              MaterialPageRoute<void>(builder: (_) => YoutubeAccessScreen(sourceUrl: failure.track.id)),
                            );
                          }
                        },
                        child: Text(context.tr('Open YouTube access')),
                      ),
                    TextButton(
                      onPressed: () {
                        final host = routeContext();
                        if (host != null) {
                          showResonanceDialog<void>(
                            context: host,
                            builder: (dialogContext) => ResonanceDialog(
                              title: Text(dialogContext.tr('Details')),
                              content: SingleChildScrollView(
                                child: SelectableText(
                                  classified.technicalSummary.isEmpty
                                      ? classified.userMessage
                                      : classified.technicalSummary,
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dialogContext),
                                  child: Text(dialogContext.tr('Close')),
                                ),
                              ],
                            ),
                          );
                        }
                      },
                      child: Text(context.tr('Details')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class PlaybackAlternativeDialog extends StatefulWidget {
  const PlaybackAlternativeDialog({super.key, required this.failed, required this.query, this.search});
  final String failed, query;
  final RecoverySearch? search;
  @override
  State<PlaybackAlternativeDialog> createState() => _PlaybackAlternativeDialogState();
}

class _PlaybackAlternativeDialogState extends State<PlaybackAlternativeDialog> {
  late final _query = TextEditingController(text: widget.query);
  var _source = YoutubeSearchSource.music;
  List<YoutubeTrack> _results = const [];
  bool _loading = true;
  Object? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final generation = ++_generation;
    final query = _query.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<YoutubeTrack> results;
      if (widget.search != null) {
        results = await widget.search!(query, _source);
      } else if (Platform.isWindows) {
        final downloader = MediaDownloader();
        await downloader.initBinaries();
        results = await downloader.search(query, limit: 8, source: _source);
      } else {
        results = await AndroidYoutubeDownloader().search(query, limit: 8, source: _source);
      }
      if (!mounted || generation != _generation) return;
      final failedId = YoutubeTrack(title: '', artist: '', url: widget.failed).videoId;
      final seen = <String>{};
      setState(
        () => _results = results
            .where(
              (e) =>
                  e.url != widget.failed && (failedId == null || e.videoId != failedId) && seen.add(e.videoId ?? e.url),
            )
            .toList(),
      );
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ResonanceDialog(
    title: Text(context.tr('Find another upload')),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.tr('Choose a version to play. Your saved playlist will stay unchanged.')),
          const SizedBox(height: 12),
          TextField(
            controller: _query,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: context.tr('Search'),
              suffixIcon: IconButton(
                tooltip: context.tr('Search'),
                onPressed: _search,
                icon: const Icon(Icons.search_rounded),
              ),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButton<YoutubeSearchSource>(
            value: _source,
            isExpanded: true,
            items: [
              DropdownMenuItem(value: YoutubeSearchSource.music, child: Text(context.tr('YouTube Music'))),
              DropdownMenuItem(value: YoutubeSearchSource.youtube, child: Text(context.tr('YouTube'))),
            ],
            onChanged: (source) {
              if (source == null) return;
              setState(() => _source = source);
              unawaited(_search());
            },
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _error != null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(context.tr('Could not load alternatives. Check your connection and try again.')),
                        TextButton(onPressed: _search, child: Text(context.tr('Retry'))),
                      ],
                    )
                  : _results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(context.tr('No other uploads found. Try a different search or YouTube.')),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final track = _results[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.play_circle_outline_rounded),
                          title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.pop(context, track),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel')))],
  );
}
