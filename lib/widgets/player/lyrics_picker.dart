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
  String? _source;
  int? _durationTolerance;
  LyricTimingQuality? _timing;
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
      int rank(LrclibCandidate candidate) {
        final target = widget.targetDuration;
        final wordTimed = candidate.timingQuality == LyricTimingQuality.word;
        if (target == null || target <= Duration.zero) return wordTimed ? 0 : 1;
        if (candidate.duration <= Duration.zero) return wordTimed ? 1 : 3;
        final difference = (candidate.duration - target).abs();
        if (difference <= const Duration(seconds: 3)) return wordTimed ? 0 : 2;
        return 3;
      }

      final ranked = results.indexed.toList()
        ..sort((a, b) {
          final order = rank(a.$2).compareTo(rank(b.$2));
          return order == 0 ? a.$1.compareTo(b.$1) : order;
        });
      setState(() => _results = ranked.map((entry) => entry.$2).toList(growable: false));
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

  String _timingLabel(LyricTimingQuality timing) => context.tr(switch (timing) {
    LyricTimingQuality.word => 'Word-synced',
    LyricTimingQuality.line => 'Line-synced',
    LyricTimingQuality.plain => 'Plain',
  });

  void _clearFilters() => setState(() {
    _source = null;
    _durationTolerance = null;
    _timing = null;
  });

  Widget _filter<T>({
    required String label,
    required String tooltip,
    required T? selected,
    required Map<T?, String> options,
    required ValueChanged<T?> onChanged,
  }) => MenuAnchor(
    menuChildren: [
      for (final option in options.entries)
        MenuItemButton(
          leadingIcon: Icon(option.key == selected ? Icons.check_rounded : null, size: 18),
          onPressed: () => onChanged(option.key),
          child: Text(option.value),
        ),
    ],
    builder: (context, controller, _) => Tooltip(
      message: tooltip,
      child: OutlinedButton(
        onPressed: controller.isOpen ? controller.close : controller.open,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsetsDirectional.only(start: 11, end: 7),
          foregroundColor: selected == null ? null : Theme.of(context).colorScheme.primary,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(selected == null ? label : options[selected] ?? label),
            const Icon(Icons.expand_more, size: 17),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sources = _results.map((result) => result.source).toSet().toList()..sort();
    final target = widget.targetDuration;
    final results = _results
        .where((candidate) {
          if (_source != null && candidate.source != _source) return false;
          if (_timing != null && (candidate.instrumental || candidate.timingQuality != _timing)) return false;
          final tolerance = _durationTolerance;
          return tolerance == null ||
              target == null ||
              (candidate.duration > Duration.zero &&
                  (candidate.duration - target).abs() <= Duration(seconds: tolerance));
        })
        .toList(growable: false);
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
          if (_results.isNotEmpty && !_loading && _error == null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 20, 4),
              child: Wrap(
                spacing: 8,
                children: [
                  _filter<String>(
                    label: context.tr('Source'),
                    tooltip: context.tr('Filter by lyrics source'),
                    selected: _source,
                    options: {null: context.tr('Any source'), for (final source in sources) source: source},
                    onChanged: (value) => setState(() => _source = value),
                  ),
                  if (target != null && target > Duration.zero)
                    _filter<int>(
                      label: context.tr('Length'),
                      tooltip: context.tr('Filter by duration difference'),
                      selected: _durationTolerance,
                      options: {
                        null: context.tr('Any length'),
                        for (final seconds in [3, 10, 30]) seconds: context.tr('Within {0}s', [seconds]),
                      },
                      onChanged: (value) => setState(() => _durationTolerance = value),
                    ),
                  _filter<LyricTimingQuality>(
                    label: context.tr('Timing'),
                    tooltip: context.tr('Filter by timing'),
                    selected: _timing,
                    options: {
                      null: context.tr('Any timing'),
                      for (final timing in LyricTimingQuality.values) timing: _timingLabel(timing),
                    },
                    onChanged: (value) => setState(() => _timing = value),
                  ),
                ],
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
                : results.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _results.isNotEmpty
                                ? context.tr('No lyrics match these filters.')
                                : _searched
                                ? context.tr("No lyrics found for this search.")
                                : context.tr("Search for lyrics by title and artist."),
                            textAlign: TextAlign.center,
                          ),
                          if (_results.isNotEmpty)
                            TextButton(onPressed: _clearFilters, child: Text(context.tr('Clear filters'))),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 24),
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final candidate = results[index];
                      final difference = _difference(candidate);
                      final details = [
                        candidate.artistName,
                        if (candidate.albumName.isNotEmpty) candidate.albumName,
                        candidate.source,
                      ].where((part) => part.isNotEmpty).join(' · ');
                      return InkWell(
                        key: ValueKey('lrclib-candidate-${candidate.id}'),
                        onTap: () => Navigator.pop(context, candidate),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 56),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        candidate.trackName,
                                        style: theme.textTheme.titleMedium,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        details,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 110),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        candidate.instrumental
                                            ? context.tr("Instrumental")
                                            : _timingLabel(candidate.timingQuality),
                                        textAlign: TextAlign.end,
                                        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
                                      ),
                                      if (candidate.duration > Duration.zero)
                                        Text(
                                          [
                                            _duration(candidate.duration),
                                            if (difference != null && difference != 'exact duration') difference,
                                          ].join(' · '),
                                          textAlign: TextAlign.end,
                                          style: theme.textTheme.labelSmall?.copyWith(
                                            color: theme.colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
