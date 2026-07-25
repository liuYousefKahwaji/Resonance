import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The shared Resonance vinyl treatment used by both the compact now-playing
/// card and the standalone-player easter egg.
class ResonanceVinylDisc extends StatefulWidget {
  final double size;
  final bool spinning;
  final Color accent;
  final double Function()? amplitudeProvider;

  const ResonanceVinylDisc({
    super.key,
    required this.size,
    required this.spinning,
    required this.accent,
    this.amplitudeProvider,
  });

  @override
  State<ResonanceVinylDisc> createState() => _ResonanceVinylDiscState();
}

class _ResonanceVinylDiscState extends State<ResonanceVinylDisc> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(seconds: 11));

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant ResonanceVinylDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinning == oldWidget.spinning) return;
    if (widget.spinning) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion) {
      _controller.stop();
    } else if (widget.spinning && !_controller.isAnimating) {
      _controller.repeat();
    }

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final rawAmplitude = widget.spinning ? (widget.amplitudeProvider?.call() ?? 0.28) : 0.0;
          final amplitude = math.sqrt(rawAmplitude.clamp(0.0, 1.0));
          return Transform.rotate(
            angle: _controller.value * math.pi * 2,
            child: CustomPaint(
              size: Size.square(widget.size),
              painter: ResonanceVinylPainter(
                accent: widget.accent,
                phase: _controller.value,
                amplitude: amplitude,
                active: widget.spinning && !reducedMotion,
              ),
            ),
          );
        },
      ),
    );
  }
}

@visibleForTesting
class ResonanceVinylPainter extends CustomPainter {
  final Color accent;
  final double phase;
  final double amplitude;
  final bool active;

  const ResonanceVinylPainter({
    required this.accent,
    required this.phase,
    required this.amplitude,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final scale = size.shortestSide / 40;
    final detailScale = scale.clamp(1.0, 4.5);

    if (active) {
      canvas.drawCircle(
        center,
        radius - 0.5 * detailScale,
        Paint()
          ..color = accent.withValues(alpha: 0.13 + amplitude * 0.17)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, (4 + amplitude * 3.5) * detailScale),
      );
    }

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.30, -0.35),
          radius: 1.05,
          colors: <Color>[Color(0xFF393941), Color(0xFF15151A), Color(0xFF08080B)],
          stops: <double>[0, 0.48, 1],
        ).createShader(Offset.zero & size),
    );

    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.55 * detailScale
      ..color = const Color(0xFF666672).withValues(alpha: 0.62);
    for (final fraction in <double>[0.41, 0.50, 0.59, 0.68, 0.77, 0.86]) {
      canvas.drawCircle(center, radius * fraction, groove);
    }

    canvas.save();
    canvas.clipPath(Path()..addOval(Offset.zero & size));
    canvas.rotate(-0.16);
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.39, -5 * detailScale, size.width * 0.20, size.height + 10 * detailScale),
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.16 + amplitude * 0.10),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(size.width * 0.39, 0, size.width * 0.20, size.height)),
    );
    canvas.restore();

    final highlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.9 * detailScale
      ..color = Colors.white.withValues(alpha: 0.18 + amplitude * 0.14);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius * 0.73), -1.12, 0.72, false, highlight);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 0.55),
      2.02,
      0.48,
      false,
      highlight..color = Colors.white.withValues(alpha: 0.10 + amplitude * 0.08),
    );

    canvas.drawCircle(center, radius * 0.32, Paint()..color = accent);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 0.25),
      -math.pi / 2,
      math.pi * 0.72,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 * detailScale
        ..color = Colors.white.withValues(alpha: 0.75),
    );
    canvas.drawCircle(center, radius * 0.07, Paint()..color = const Color(0xFF111116));

    // Brief glints mimic dust catching the light without becoming a strobe.
    if (active) {
      final sparkle = math.pow(math.max(0.0, math.sin(phase * math.pi * 6)), 20).toDouble();
      if (sparkle > 0.02) {
        final point = Offset(size.width * 0.88, size.height * 0.22);
        final sparklePaint = Paint()
          ..color = Colors.white.withValues(alpha: sparkle * (0.55 + amplitude * 0.35))
          ..strokeWidth = 0.8 * detailScale
          ..strokeCap = StrokeCap.round;
        final reach = (1.2 + sparkle * 1.8) * detailScale;
        canvas.drawLine(point.translate(-reach, 0), point.translate(reach, 0), sparklePaint);
        canvas.drawLine(point.translate(0, -reach), point.translate(0, reach), sparklePaint);
        canvas.drawCircle(
          point,
          (0.7 + sparkle * 0.6) * detailScale,
          Paint()..color = accent.withValues(alpha: sparkle * 0.8),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant ResonanceVinylPainter oldDelegate) =>
      oldDelegate.accent != accent ||
      oldDelegate.phase != phase ||
      oldDelegate.amplitude != amplitude ||
      oldDelegate.active != active;
}
