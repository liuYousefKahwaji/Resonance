import 'dart:async';
import 'package:flutter/material.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_range.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/core/audio/audio_envelope_analyzer.dart';
import 'trim_waveform.dart';

String playbackTimestamp(Duration value) {
  final seconds = value.inSeconds;
  final minutes = seconds ~/ 60;
  final fraction = value.inMilliseconds % 1000;
  final base = '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  return fraction == 0 ? base : '$base.${fraction.toString().padLeft(3, '0')}';
}

Duration? parsePlaybackTimestamp(String value) {
  final parts = value.trim().split(':');
  if (value.length > 32 ||
      parts.isEmpty ||
      parts.length > 3 ||
      !RegExp(r'^\d+(?::\d+){0,2}(?:\.\d{1,3})?$').hasMatch(value.trim())) {
    return null;
  }
  final seconds = double.tryParse(parts.last);
  if (seconds == null || !seconds.isFinite || seconds > 1e9 || (parts.length > 1 && seconds >= 60)) return null;
  final minutes = parts.length > 1 ? int.tryParse(parts[parts.length - 2]) : 0;
  if (minutes == null || minutes > 1000000) return null;
  if (parts.length == 3 && minutes >= 60) return null;
  final hours = parts.length == 3 ? int.tryParse(parts.first) : 0;
  if (hours == null || hours > 1000000) return null;
  return Duration(milliseconds: ((hours * 3600 + minutes * 60 + seconds) * 1000).round());
}

Future<void> showPlaybackRangeDialog(
  BuildContext context,
  PlayerHandler handler,
  String path,
  String title, {
  Future<AudioEnvelope?> Function(String)? waveformLoader,
}) async {
  await showDialog<void>(
    barrierDismissible: false,
    context: context,
    builder: (_) => PlaybackRangeDialog(handler: handler, path: path, title: title, waveformLoader: waveformLoader),
  );
}

class PlaybackRangeDialog extends StatefulWidget {
  const PlaybackRangeDialog({
    super.key,
    required this.handler,
    required this.path,
    required this.title,
    this.waveformLoader,
  });
  final PlayerHandler handler;
  final String path;
  final String title;
  final Future<AudioEnvelope?> Function(String)? waveformLoader;
  @override
  State<PlaybackRangeDialog> createState() => _PlaybackRangeDialogState();
}

class _PlaybackRangeDialogState extends State<PlaybackRangeDialog> {
  final _start = TextEditingController();
  final _end = TextEditingController();
  // Keep voice and instrument energy, not only the bass used by pulse effects.
  final _analyzer = AudioEnvelopeAnalyzer(cacheNamespace: 'resonance_trim_waveforms_8k', sampleRate: 8000);
  StreamSubscription<Duration>? _positionSubscription;
  Duration? _duration;
  Duration _cursor = Duration.zero;
  RangeValues _values = const RangeValues(0, 1);
  List<double> _samples = const [];
  bool _waveformLoading = true;
  bool _busy = false;
  bool _previewing = false;
  bool _zoomed = false;
  bool _followMain = true;
  String? _error;
  DateTime _lastCursorPaint = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    widget.handler.playbackRangePreviewNotifier.addListener(_previewChanged);
    _positionSubscription = widget.handler.positionStream.listen((position) {
      if (_followMain && widget.handler.mediaItem.value?.id == widget.path && !_previewing) {
        _paintCursor(widget.handler.sourcePositionFor(position));
      }
    });
    unawaited(_load());
  }

  void _paintCursor(Duration position, {bool force = false}) {
    if (!mounted) return;
    _cursor = position;
    final now = DateTime.now();
    if (force || now.difference(_lastCursorPaint) >= const Duration(milliseconds: 80)) {
      _lastCursorPaint = now;
      setState(() {});
    }
  }

  void _previewChanged() {
    final preview = widget.handler.playbackRangePreviewNotifier.value;
    if (preview?.path == widget.path) {
      final changed = _previewing != (preview!.playing || preview.loading);
      _previewing = preview.playing || preview.loading;
      _paintCursor(preview.position, force: changed);
    } else if (mounted && _previewing) {
      setState(() => _previewing = false);
    }
  }

  Future<void> _load() async {
    try {
      final duration = await widget.handler.originalDurationFor(widget.path);
      if (duration == null || duration <= Duration.zero) throw StateError('Could not read the song length.');
      final saved = (await widget.handler.playbackRangeFor(widget.path)).bounded(duration);
      if (!mounted) return;
      setState(() {
        _duration = duration;
        _values = RangeValues(saved.start.inMilliseconds.toDouble(), (saved.end ?? duration).inMilliseconds.toDouble());
        _cursor = widget.handler.mediaItem.value?.id == widget.path
            ? widget.handler.currentSourcePosition
            : saved.start;
        _updateFields();
      });
      unawaited(_loadWaveform());
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not read the song length.');
    }
  }

  Future<void> _loadWaveform() async {
    AudioEnvelope? envelope;
    try {
      envelope = await (widget.waveformLoader ?? _analyzer.analyze)(widget.path);
    } catch (_) {
      // Playback and exact time editing remain available when decoding fails.
    }
    if (mounted) {
      setState(() {
        _samples = envelope?.samples ?? const [];
        _waveformLoading = false;
      });
    }
  }

  void _updateFields() {
    _start.text = playbackTimestamp(Duration(milliseconds: _values.start.round()));
    _end.text = playbackTimestamp(Duration(milliseconds: _values.end.round()));
    _error = null;
  }

  PlaybackRange? _read() {
    final start = parsePlaybackTimestamp(_start.text);
    final end = parsePlaybackTimestamp(_end.text);
    if (start == null || end == null || start < Duration.zero || end > _duration! || end <= start) {
      setState(() => _error = 'Choose an end time after the start, within the song.');
      return null;
    }
    return PlaybackRange(start: start, end: end == _duration ? null : end);
  }

  void _syncFields(String _) {
    final start = parsePlaybackTimestamp(_start.text), end = parsePlaybackTimestamp(_end.text);
    if (start != null && end != null && end > start && end <= _duration!) {
      setState(() {
        _values = RangeValues(start.inMilliseconds.toDouble(), end.inMilliseconds.toDouble());
        _error = null;
      });
    }
  }

  Future<void> _restartPreview() async {
    if (!_previewing || _busy) return;
    final range = _read();
    if (range == null) return;
    setState(() => _busy = true);
    try {
      await widget.handler.previewPlaybackRange(widget.path, range);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not preview this section.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview() async {
    final range = _previewing ? null : _read();
    if (!_previewing && range == null) return;
    setState(() => _busy = true);
    try {
      if (_previewing) {
        await widget.handler.stopPlaybackRangePreview();
      } else {
        _followMain = false;
        await widget.handler.previewPlaybackRange(widget.path, range!);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not preview this section.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _seekCursor(Duration source) {
    _followMain = false;
    _paintCursor(source, force: true);
    if (_previewing) {
      final max = (_values.end - 1).clamp(_values.start, _values.end);
      final clamped = source.inMilliseconds.toDouble().clamp(_values.start, max);
      unawaited(
        widget.handler.seekPlaybackRangePreview(Duration(milliseconds: clamped.round())).catchError((Object _) {}),
      );
    }
  }

  void _useCurrentPosition(bool start) {
    final preview = widget.handler.playbackRangePreviewNotifier.value;
    final position = preview?.path == widget.path
        ? preview!.position
        : _followMain && widget.handler.mediaItem.value?.id == widget.path
        ? widget.handler.currentSourcePosition
        : _cursor;
    final max = _duration!.inMilliseconds.toDouble();
    final minimum = max < 100 ? max : 100.0;
    final time = position.inMilliseconds
        .toDouble()
        .clamp(start ? 0.0 : minimum, start ? max - minimum : max)
        .toDouble();
    setState(() {
      _values = start
          ? RangeValues(time, _values.end > time ? _values.end : max)
          : RangeValues(_values.start < time ? _values.start : 0, time);
      _updateFields();
    });
    unawaited(_restartPreview());
  }

  Future<void> _save() async {
    final range = _read();
    if (range == null) return;
    setState(() => _busy = true);
    try {
      await widget.handler.stopPlaybackRangePreview();
      await widget.handler.savePlaybackRange(widget.path, range);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not save playback range.';
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    widget.handler.playbackRangePreviewNotifier.removeListener(_previewChanged);
    unawaited(_positionSubscription?.cancel());
    unawaited(widget.handler.stopPlaybackRangePreview());
    _analyzer.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Widget _timeField(bool start) => Expanded(
    child: TextField(
      key: Key(start ? 'trim-start-time' : 'trim-end-time'),
      controller: start ? _start : _end,
      onChanged: _syncFields,
      onSubmitted: (_) => unawaited(_restartPreview()),
      enabled: !_busy,
      textDirection: TextDirection.ltr,
      keyboardType: TextInputType.datetime,
      decoration: InputDecoration(
        labelText: context.tr(start ? 'Start time' : 'End time'),
        filled: true,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          key: Key(start ? 'trim-start-here' : 'trim-end-here'),
          tooltip: context.tr('Use current position'),
          onPressed: _busy ? null : () => _useCurrentPosition(start),
          icon: const Icon(Icons.my_location_rounded, size: 18),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(context.tr('Trim playback')),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                context.tr('Choose the part you want to hear. Your file stays unchanged.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (_duration == null && _error == null) const Center(child: CircularProgressIndicator()),
              if (_duration != null) ...[
                Row(
                  children: [
                    Expanded(child: Text(context.tr('Preview'), style: Theme.of(context).textTheme.labelLarge)),
                    if (_waveformLoading)
                      const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                    IconButton(
                      tooltip: context.tr(_zoomed ? 'Show full song' : 'Zoom to selection'),
                      onPressed: () => setState(() => _zoomed = !_zoomed),
                      icon: Icon(_zoomed ? Icons.zoom_out_rounded : Icons.zoom_in_rounded, size: 20),
                    ),
                  ],
                ),
                TrimWaveform(
                  duration: _duration!,
                  values: _values,
                  samples: _samples,
                  position: _cursor,
                  enabled: !_busy,
                  zoomed: _zoomed,
                  startLabel: context.tr('Start time'),
                  endLabel: context.tr('End time'),
                  onChanged: (values) => setState(() {
                    _values = values;
                    _updateFields();
                  }),
                  onChangeEnd: () => unawaited(_restartPreview()),
                  onSeek: _seekCursor,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton.filledTonal(
                      key: const Key('trim-preview'),
                      tooltip: context.tr(_previewing ? 'Stop preview' : 'Preview'),
                      onPressed: _busy ? null : _preview,
                      icon: _busy
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(_previewing ? Icons.stop_rounded : Icons.play_arrow_rounded),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(
                          '${playbackTimestamp(_cursor)} / ${playbackTimestamp(_duration!)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  context.tr('Drag the edges, or tap the waveform to choose a position.'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                Row(children: [_timeField(true), const SizedBox(width: 12), _timeField(false)]),
                const SizedBox(height: 10),
                Text(
                  context.tr('Selected length: {0}', [
                    playbackTimestamp(Duration(milliseconds: (_values.end - _values.start).round())),
                  ]),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(context.tr(_error!), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _duration == null || _busy
              ? null
              : () {
                  setState(() {
                    _values = RangeValues(0, _duration!.inMilliseconds.toDouble());
                    _updateFields();
                  });
                  unawaited(_restartPreview());
                },
          child: Text(context.tr('Reset to full song')),
        ),
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
        FilledButton(onPressed: _duration == null || _busy ? null : _save, child: Text(context.tr('Save'))),
      ],
    ),
  );
}
