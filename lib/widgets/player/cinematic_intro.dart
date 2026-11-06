import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:resonance/l10n/app_strings.dart';

/// The timeline follows the existing 3.03-second sound, never a replacement.
class CinematicIntro extends StatefulWidget {
  const CinematicIntro({super.key, required this.position, required this.onDismiss});
  final ValueListenable<Duration> position;
  final VoidCallback onDismiss;
  @override
  State<CinematicIntro> createState() => _CinematicIntroState();
}

class _CinematicIntroState extends State<CinematicIntro> with SingleTickerProviderStateMixin {
  late final AnimationController _clock;
  bool _reducedMotion = false;
  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: const Duration(milliseconds: 3030));
    widget.position.addListener(_followAudio);
    _followAudio();
  }

  void _followAudio() {
    if (_reducedMotion) return;
    final t = (widget.position.value.inMilliseconds / 3030).clamp(0.0, 1.0);
    // Smooth frames between backend position events, anchored to the real sound.
    if (t > 0 && (!_clock.isAnimating || t - _clock.value > 0.08)) _clock.forward(from: t);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion) {
      _clock.stop();
    } else {
      _followAudio();
    }
  }

  @override
  void didUpdateWidget(CinematicIntro oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_followAudio);
      widget.position.addListener(_followAudio);
      _followAudio();
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_followAudio);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final colors = Theme.of(context).colorScheme;
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return Semantics(
      label: context.tr('Resonance'),
      button: true,
      onTap: widget.onDismiss,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onDismiss,
        child: ColoredBox(
          color: const Color(0xFF08090B),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: const Key('cinematic-ribbons'),
                    painter: _SoundMark(_clock, colors.primary, reduced, mobile ? 13 : 25),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(radius: .85, colors: [Colors.transparent, const Color(0x99000000)]),
                    ),
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _clock,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 70),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          context.tr('Resonance'),
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            fontSize: mobile ? 48 : 86,
                            height: 1.12,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            decoration: TextDecoration.none,
                            letterSpacing: -.8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(width: 44, height: 2, color: colors.primary.withValues(alpha: .85)),
                    ],
                  ),
                ),
                builder: (context, title) {
                  final t = reduced ? .72 : _clock.value;
                  final reveal = reduced ? 1.0 : Curves.easeOutQuart.transform(((t - .32) / .24).clamp(0.0, 1.0));
                  final settle = Curves.easeOutCubic.transform(((t - .45) / .45).clamp(0.0, 1.0));
                  final exit = reduced ? 1.0 : 1 - Curves.easeInCubic.transform(((t - .94) / .06).clamp(0.0, 1.0));
                  return Opacity(
                    opacity: reveal * exit,
                    child: Transform.scale(scale: reduced ? 1 : 1.14 - .14 * settle, child: title),
                  );
                },
              ),
              PositionedDirectional(
                bottom: math.max(24, MediaQuery.paddingOf(context).bottom + 16),
                child: TextButton(
                  onPressed: widget.onDismiss,
                  child: Text(
                    context.tr('tap to skip'),
                    style: const TextStyle(color: Color(0xFFB7BCC5), fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoundMark extends CustomPainter {
  _SoundMark(this.clock, this.color, this.reduced, this.ribbonCount) : super(repaint: clock);
  final Animation<double> clock;
  double get progress => reduced ? .72 : clock.value;
  final int ribbonCount;
  final Color color;
  final bool reduced;
  // RMS envelope sampled from the unchanged intro.mp3 (3.03025 seconds).
  static const _envelope = [
    0.072,
    0.208,
    0.322,
    0.437,
    0.465,
    0.540,
    0.641,
    0.764,
    0.739,
    0.766,
    0.804,
    0.893,
    0.964,
    0.975,
    0.988,
    0.996,
    1.000,
    0.946,
    0.938,
    0.978,
    0.935,
    0.841,
    0.877,
    0.832,
    0.750,
    0.718,
    0.693,
    0.588,
    0.531,
    0.529,
    0.557,
    0.570,
    0.532,
    0.535,
    0.442,
    0.401,
    0.333,
    0.344,
    0.293,
    0.259,
    0.227,
    0.204,
    0.200,
    0.178,
    0.136,
    0.091,
    0.075,
    0.043,
  ];
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final wake = Curves.easeOutCubic.transform(((progress - .015) / .25).clamp(0.0, 1.0));
    final close = Curves.easeInOutCubic.transform(((progress - .38) / .39).clamp(0.0, 1.0));
    final spread = wake * (1 - close);
    final sample = progress * (_envelope.length - 1);
    final index = sample.floor().clamp(0, _envelope.length - 2);
    final amplitude = _envelope[index] + (_envelope[index + 1] - _envelope[index]) * (sample - index);
    final fade = 1 - Curves.easeInCubic.transform(((progress - .91) / .09).clamp(0.0, 1.0));
    if (!reduced) {
      for (var i = 0; i < ribbonCount; i++) {
        final u = (i - (ribbonCount - 1) / 2) / ((ribbonCount - 1) / 2);
        final seed = (i * 37 % 101) / 101;
        final x = center.dx + u * size.width * .56 * spread;
        final bend = math.sin(u * math.pi + progress * 5) * size.width * .13 * spread;
        final length = size.height * (.38 + .42 * seed) * wake;
        final path = Path()
          ..moveTo(x - bend, center.dy - length)
          ..cubicTo(
            x + bend,
            center.dy - length * .35,
            x - bend * .3,
            center.dy + length * .3,
            x + bend * .5,
            center.dy + length,
          );
        final alpha = ((1 - close) * (.20 + .56 * amplitude) * (1 - u.abs() * .55) * fade).clamp(0.0, 1.0);
        final tint = Color.lerp(color, Colors.white, .15 + seed * .4)!;
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = (1 + seed * 8) * math.max(.15, spread)
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              tint.withValues(alpha: 0),
              tint.withValues(alpha: alpha),
              Colors.white.withValues(alpha: alpha * .8),
              tint.withValues(alpha: alpha),
              tint.withValues(alpha: 0),
            ],
            stops: const [0, .28, .48, .7, 1],
          ).createShader(Rect.fromLTWH(0, center.dy - length, size.width, length * 2));
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = paint.strokeWidth * 3
            ..color = tint.withValues(alpha: alpha * .08),
        );
        canvas.drawPath(path, paint);
      }
      final flare = math.sin(math.pi * ((progress - .04) / .36).clamp(0.0, 1.0));
      canvas.drawLine(
        Offset(center.dx - size.width * .45 * wake, center.dy),
        Offset(center.dx + size.width * .45 * wake, center.dy),
        Paint()
          ..color = Colors.white.withValues(alpha: flare * .3)
          ..strokeWidth = 1,
      );
    }
    final markReveal = reduced ? 1.0 : Curves.easeOutCubic.transform(((progress - .30) / .25).clamp(0.0, 1.0));
    final markCenter = center.translate(0, -48);
    for (var i = 0; i < 5; i++) {
      const heights = [17.0, 38.0, 58.0, 38.0, 17.0];
      final height = heights[i] * markReveal * (reduced ? 1 : .9 + .1 * amplitude);
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: markCenter.translate((i - 2) * 12, 0), width: 4, height: height),
        const Radius.circular(2),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(color, Colors.white, .55)!, color],
          ).createShader(rect.outerRect)
          ..color = Colors.white.withValues(alpha: markReveal * fade),
      );
    }
  }

  @override
  bool shouldRepaint(_SoundMark old) =>
      old.clock != clock || old.color != color || old.reduced != reduced || old.ribbonCount != ribbonCount;
}
