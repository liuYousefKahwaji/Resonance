import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:resonance/models/lyrics.dart';
import 'package:resonance/services/lyrics_service.dart';
import 'package:resonance/l10n/app_strings.dart';

class LyricsPicker extends StatefulWidget {
  final String initialQuery;
  final Duration? targetDuration;

  const LyricsPicker({super.key, required this.initialQuery, required this.targetDuration, this.search});
  final Future<List<LrclibCandidate>> Function(String)? search;

  @override
  State<LyricsPicker> createState() => LyricsPickerState();
}

class LyricsPickerState extends State<LyricsPicker> {
  late final TextEditingController _queryController;
  List<LrclibCandidate> _results = const [];
  bool _loading = true;
  bool _searched = false;
  String? _error;
  DateTime? _retryAt;
  Timer? _retryTimer;
  int get _retrySeconds {
    final remaining = _retryAt?.difference(DateTime.now()).inMilliseconds ?? 0;
    return remaining > 0 ? (remaining / 1000).ceil() : 0;
  }

  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    _search();
  }

  @override
  void dispose() {
    _generation++;
    _retryTimer?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    final generation = ++_generation;
    _retryTimer?.cancel();
    setState(() {
      _loading = true;
      _searched = true;
      _error = null;
      _retryAt = null;
    });
    try {
      final results = await (widget.search ?? const LyricsService().searchLrclibCandidates)(query);
      if (!mounted || generation != _generation) return;
      setState(() => _results = results);
    } catch (error) {
      if (mounted && generation == _generation) {
        _retryAt = error is LyricsLookupException ? error.retryAt : null;
        if (_retrySeconds > 0) {
          _retryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
            if (!mounted || _retrySeconds == 0) timer.cancel();
            if (mounted) setState(() {});
          });
        }
        setState(
          () => _error = error is LyricsLookupException
              ? error.message
              : 'Could not reach LRCLIB. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  String _duration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String? _difference(LrclibCandidate candidate) {
    final target = widget.targetDuration;
    if (target == null || target.inSeconds <= 0 || candidate.duration.inSeconds <= 0) return null;
    final difference = candidate.duration.inSeconds - target.inSeconds;
    if (difference == 0) return 'exact duration';
    return '${difference > 0 ? '+' : ''}${difference}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 12, 12),
            child: Row(
              children: [
                Expanded(child: Text(context.tr("Choose lyrics"), style: theme.textTheme.titleLarge)),
                IconButton(
                  tooltip: context.tr("Close"),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              key: const Key('lyrics-search-field'),
              controller: _queryController,
              autofocus: Platform.isWindows,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: context.tr("Artist and song title"),
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  tooltip: context.tr("Search"),
                  onPressed: _search,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 10, 20, 8),
            child: Text(
              context.tr(
                "Automatic matching only accepts results within 3 seconds. You can deliberately choose any version here.",
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(context.tr(_error!), textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _retrySeconds > 0 ? null : _search,
                            child: Text(
                              _retrySeconds > 0 ? context.tr('Retry in {0}s', [_retrySeconds]) : context.tr('Retry'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : _results.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _searched
                            ? context.tr("No LRCLIB results for this search.")
                            : context.tr("Search LRCLIB to choose a result."),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 24),
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final candidate = _results[index];
                      final difference = _difference(candidate);
                      final details = [
                        candidate.artistName,
                        if (candidate.albumName.isNotEmpty) candidate.albumName,
                      ].where((part) => part.isNotEmpty).join(' · ');
                      return ListTile(
                        key: ValueKey('lrclib-candidate-${candidate.id}'),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        title: Text(candidate.trackName, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                        trailing: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 116),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(_duration(candidate.duration), style: theme.textTheme.labelLarge),
                              Text(
                                candidate.instrumental
                                    ? context.tr("Instrumental")
                                    : candidate.hasSyncedLyrics
                                    ? context.tr("Synced")
                                    : context.tr("Plain"),
                                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                              ),
                              if (difference != null)
                                Text(
                                  difference,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: difference == 'exact duration'
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        onTap: () => Navigator.pop(context, candidate),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
