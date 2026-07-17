import 'package:flutter/material.dart';

/// A smooth, platform-independent audio pulse. The ticker samples a real RMS
/// envelope at the live playback position and turns its level into a filled
/// aura, so both platforms react to the track without drawing bars or dots.
class PlaybackPulse extends StatefulWidget {
  final Widget child;
  final bool active;
  final double borderRadius;
  final double reach;
  final double Function()? amplitudeProvider;
  final Color? color;

  const PlaybackPulse({
    super.key,
    required this.child,
    required this.active,
    required this.borderRadius,
    this.reach = 18,
    this.amplitudeProvider,
    this.color,
  });

  @override
  State<PlaybackPulse> createState() => _PlaybackPulseState();
}

class _PlaybackPulseState extends State<PlaybackPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _smoothedLevel = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1550));
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant PlaybackPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
      _smoothedLevel = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final targetColor = widget.color ?? Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<Color?>(
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeInOutCubic,
      tween: ColorTween(end: targetColor),
      builder: (context, animatedColor, _) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          child: widget.child,
          builder: (context, child) {
            final target = widget.active ? (widget.amplitudeProvider?.call() ?? 0).clamp(0.0, 1.0) : 0.0;
            final response = target > _smoothedLevel ? 0.34 : 0.16;
            _smoothedLevel += (target - _smoothedLevel) * response;
            return CustomPaint(
              key: const ValueKey('playback-pulse'),
              painter: _PulsePainter(
                level: _smoothedLevel,
                active: widget.active,
                color: animatedColor ?? targetColor,
                borderRadius: widget.borderRadius,
                reach: widget.reach,
              ),
              child: child,
            );
          },
        ),
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  final double level;
  final bool active;
  final Color color;
  final double borderRadius;
  final double reach;

  const _PulsePainter({
    required this.level,
    required this.active,
    required this.color,
    required this.borderRadius,
    required this.reach,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final innerGlow = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: active ? 0.04 + level * 0.14 : 0.025);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.inflate(2 + level * 7), Radius.circular(borderRadius + 5 + level * 4)),
      innerGlow,
    );

    if (!active || level < 0.01) return;
    for (var layer = 0; layer < 3; layer++) {
      final depth = (layer + 1) / 3;
      final expansion = 3 + reach * level * (0.45 + depth * 0.70);
      final opacity = level * (0.17 - layer * 0.035);
      final pulseRect = rect.inflate(expansion);
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..shader = RadialGradient(
          radius: 0.82,
          colors: [
            color.withValues(alpha: opacity),
            color.withValues(alpha: opacity * 0.72),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.72, 1],
        ).createShader(pulseRect);
      canvas.drawRRect(RRect.fromRectAndRadius(pulseRect, Radius.circular(borderRadius + expansion)), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PulsePainter oldDelegate) =>
      level != oldDelegate.level ||
      active != oldDelegate.active ||
      color != oldDelegate.color ||
      borderRadius != oldDelegate.borderRadius ||
      reach != oldDelegate.reach;
}
