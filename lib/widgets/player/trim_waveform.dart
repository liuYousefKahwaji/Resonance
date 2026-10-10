import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Real decoded amplitudes with draggable selection edges and a source-time
/// playhead. Transport stays in PlayerHandler; this widget only edits geometry.
class TrimWaveform extends StatefulWidget {
  const TrimWaveform({
    super.key,
    required this.duration,
    required this.values,
    required this.samples,
    required this.position,
    required this.onChanged,
    required this.onSeek,
    this.onChangeEnd,
    this.enabled = true,
    this.zoomed = false,
    required this.startLabel,
    required this.endLabel,
  });
  final Duration duration;
  final RangeValues values;
  final List<double> samples;
  final Duration position;
  final ValueChanged<RangeValues> onChanged;
  final ValueChanged<Duration> onSeek;
  final VoidCallback? onChangeEnd;
  final bool enabled;
  final bool zoomed;
  final String startLabel;
  final String endLabel;
  @override
  State<TrimWaveform> createState() => _TrimWaveformState();
}

class _TrimWaveformState extends State<TrimWaveform> {
  int? _edge;
  double _width = 1;
  double _viewStart = 0;
  double _viewEnd = 1;
  double _dragViewStart = 0;
  double _dragViewEnd = 1;
  RangeValues? _dragValues;
  double _dragOrigin = 0;
  static const _padding = 16.0;

  double _time(double x, {bool dragging = false}) {
    final start = dragging ? _dragViewStart : _viewStart;
    final end = dragging ? _dragViewEnd : _viewEnd;
    return start + ((x - _padding) / math.max(1, _width - 2 * _padding)).clamp(0, 1) * (end - start);
  }

  void _begin(DragStartDetails details) {
    _dragViewStart = _viewStart;
    _dragViewEnd = _viewEnd;
    _dragValues = widget.values;
    _dragOrigin = _time(details.localPosition.dx);
    final scale = math.max(1, _width - _padding * 2) / (_viewEnd - _viewStart);
    final leftDistance = (_dragOrigin - widget.values.start).abs() * scale;
    final rightDistance = (_dragOrigin - widget.values.end).abs() * scale;
    _edge = math.min(leftDistance, rightDistance) <= 24
        ? (leftDistance <= rightDistance ? 0 : 1)
        : _dragOrigin > widget.values.start &&
              _dragOrigin < widget.values.end &&
              widget.values.end - widget.values.start < widget.duration.inMilliseconds
        ? 2
        : (leftDistance <= rightDistance ? 0 : 1);
  }

  void _drag(DragUpdateDetails details) {
    final time = _time(details.localPosition.dx, dragging: true);
    final max = widget.duration.inMilliseconds.toDouble();
    final minimum = math.min(100.0, max);
    final old = widget.values;
    if (_edge == 0) {
      widget.onChanged(RangeValues(time.clamp(0.0, math.max(0.0, old.end - minimum)), old.end));
    } else if (_edge == 1) {
      widget.onChanged(RangeValues(old.start, time.clamp(math.min(max, old.start + minimum), max)));
    } else if (_edge == 2) {
      final original = _dragValues!;
      final length = original.end - original.start;
      final start = (original.start + time - _dragOrigin).clamp(0.0, max - length).toDouble();
      widget.onChanged(RangeValues(start, start + length));
    }
  }

  void _nudge(bool start, double amount) {
    final old = widget.values;
    final max = widget.duration.inMilliseconds.toDouble();
    final minimum = math.min(100.0, max);
    widget.onChanged(
      start
          ? RangeValues((old.start + amount).clamp(0.0, math.max(0.0, old.end - minimum)), old.end)
          : RangeValues(old.start, (old.end + amount).clamp(math.min(max, old.start + minimum), max)),
    );
    widget.onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        final max = widget.duration.inMilliseconds.toDouble();
        final margin = math.max(1000.0, (widget.values.end - widget.values.start) * .12);
        _viewStart = widget.zoomed ? (widget.values.start - margin).clamp(0, max) : 0;
        _viewEnd = widget.zoomed ? (widget.values.end + margin).clamp(0, max) : max;
        if (_edge != null) {
          _viewStart = _dragViewStart;
          _viewEnd = _dragViewEnd;
        }
        final colors = Theme.of(context).colorScheme;
        double xFor(double ms) => _padding + (ms - _viewStart) / (_viewEnd - _viewStart) * (_width - _padding * 2);
        return SizedBox(
          height: 116,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              MouseRegion(
                cursor: widget.enabled ? SystemMouseCursors.resizeLeftRight : SystemMouseCursors.basic,
                child: GestureDetector(
                  key: const Key('trim-waveform'),
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onTapUp: widget.enabled
                      ? (details) => widget.onSeek(Duration(milliseconds: _time(details.localPosition.dx).round()))
                      : null,
                  onHorizontalDragStart: widget.enabled ? _begin : null,
                  onHorizontalDragUpdate: widget.enabled ? _drag : null,
                  onHorizontalDragEnd: widget.enabled
                      ? (_) {
                          setState(() => _edge = null);
                          widget.onChangeEnd?.call();
                        }
                      : null,
                  onHorizontalDragCancel: () => setState(() => _edge = null),
                  child: CustomPaint(
                    size: Size(_width, 116),
                    painter: TrimWaveformPainter(
                      samples: widget.samples,
                      values: widget.values,
                      totalMs: max,
                      viewStart: _viewStart,
                      viewEnd: _viewEnd,
                      cursorMs: widget.position.inMilliseconds.toDouble(),
                      primary: colors.primary,
                      muted: colors.onSurface.withValues(alpha: .20),
                      background: colors.surfaceContainerHighest,
                    ),
                  ),
                ),
              ),
              for (final start in [true, false])
                Positioned(
                  left: (xFor(start ? widget.values.start : widget.values.end) - 16).clamp(0, math.max(0, _width - 32)),
                  top: 0,
                  width: 32,
                  height: 116,
                  child: IgnorePointer(
                    child: Semantics(
                      label: start ? widget.startLabel : widget.endLabel,
                      value: ((start ? widget.values.start : widget.values.end) / 1000).toStringAsFixed(1),
                      increasedValue: ((start ? widget.values.start + 100 : widget.values.end + 100) / 1000)
                          .toStringAsFixed(1),
                      decreasedValue: ((start ? widget.values.start - 100 : widget.values.end - 100) / 1000)
                          .toStringAsFixed(1),
                      onIncrease: widget.enabled ? () => _nudge(start, 100) : null,
                      onDecrease: widget.enabled ? () => _nudge(start, -100) : null,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

class TrimWaveformPainter extends CustomPainter {
  const TrimWaveformPainter({
    required this.samples,
    required this.values,
    required this.totalMs,
    required this.viewStart,
    required this.viewEnd,
    required this.cursorMs,
    required this.primary,
    required this.muted,
    required this.background,
  });
  final List<double> samples;
  final RangeValues values;
  final double totalMs, viewStart, viewEnd, cursorMs;
  final Color primary, muted, background;
  @override
  void paint(Canvas canvas, Size size) {
    const left = 16.0;
    final width = math.max(1.0, size.width - 32);
    double x(double time) => left + (time - viewStart) / (viewEnd - viewStart) * width;
    final selected = Rect.fromLTRB(
      x(values.start).clamp(left, size.width - left),
      14,
      x(values.end).clamp(left, size.width - left),
      size.height - 14,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, size.height), const Radius.circular(12)),
      Paint()..color = background.withValues(alpha: .45),
    );
    canvas.drawRect(selected, Paint()..color = primary.withValues(alpha: .10));
    final count = math.max(1, (width / 3).floor());
    for (var index = 0; index < count; index++) {
      final time = viewStart + index / count * (viewEnd - viewStart);
      final sampleStart = (time / totalMs * samples.length).floor().clamp(0, samples.length);
      final sampleEnd = ((time + (viewEnd - viewStart) / count) / totalMs * samples.length).ceil().clamp(
        0,
        samples.length,
      );
      var amplitude = 0.0;
      for (var j = sampleStart; j < sampleEnd; j++) {
        amplitude = math.max(amplitude, samples[j]);
      }
      final height = math.max(2.0, amplitude.clamp(0.0, 1.0) * 70.0);
      final active = time >= values.start && time <= values.end;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(left + index / count * width, size.height / 2), width: 1.8, height: height),
          const Radius.circular(1),
        ),
        Paint()..color = active ? primary.withValues(alpha: .85) : muted,
      );
    }
    final edgePaint = Paint()
      ..color = primary
      ..strokeWidth = 2;
    for (final time in [values.start, values.end]) {
      final position = x(time).clamp(left, size.width - left);
      canvas.drawLine(Offset(position, 12), Offset(position, size.height - 12), edgePaint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(position, size.height / 2), width: 9, height: 28),
          const Radius.circular(4),
        ),
        edgePaint,
      );
      canvas.drawLine(
        Offset(position, size.height / 2 - 6),
        Offset(position, size.height / 2 + 6),
        Paint()
          ..color = background
          ..strokeWidth = 1.5,
      );
    }
    if (cursorMs >= viewStart && cursorMs <= viewEnd) {
      final cursor = x(cursorMs);
      canvas.drawLine(
        Offset(cursor, 7),
        Offset(cursor, size.height - 7),
        Paint()
          ..color = primary.withValues(alpha: .55)
          ..strokeWidth = 1,
      );
      final marker = Path()
        ..moveTo(cursor - 4, 6)
        ..lineTo(cursor + 4, 6)
        ..lineTo(cursor, 11)
        ..close();
      canvas.drawPath(marker, Paint()..color = primary);
    }
  }

  @override
  bool shouldRepaint(covariant TrimWaveformPainter old) =>
      old.samples != samples ||
      old.values != values ||
      old.cursorMs != cursorMs ||
      old.viewStart != viewStart ||
      old.viewEnd != viewEnd ||
      old.primary != primary ||
      old.background != background ||
      old.muted != muted;
}
