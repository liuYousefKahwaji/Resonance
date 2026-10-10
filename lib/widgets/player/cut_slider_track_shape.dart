import 'package:flutter/material.dart';

/// The full source stays visible, but only the saved section is colored.
class CutSliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const CutSliderTrackShape({required this.startFraction, required this.endFraction});
  final double startFraction, endFraction;
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.height <= 0) return;
    final canvas = context.canvas;
    final active = sliderTheme.activeTrackColor ?? Colors.blue;
    final inactive = sliderTheme.inactiveTrackColor ?? Colors.grey;
    final start = rect.left + rect.width * startFraction;
    final end = rect.left + rect.width * endFraction;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height)),
      Paint()..color = inactive.withValues(alpha: .24),
    );
    canvas.drawRect(Rect.fromLTRB(start, rect.top, end, rect.bottom), Paint()..color = active.withValues(alpha: .30));
    final progressEnd = thumbCenter.dx.clamp(start, end);
    canvas.drawRect(Rect.fromLTRB(start, rect.top, progressEnd, rect.bottom), Paint()..color = active);
    for (final x in [start, end]) {
      canvas.drawLine(
        Offset(x, rect.top - 3),
        Offset(x, rect.bottom + 3),
        Paint()
          ..color = active.withValues(alpha: .65)
          ..strokeWidth = 1,
      );
    }
  }
}
