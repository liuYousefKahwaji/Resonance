import 'package:flutter/material.dart';

/// A single-line label that stays still when it fits and gently traverses its
/// overflow when it does not. The pause at both ends keeps metadata readable.
class OverflowingText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  const OverflowingText({super.key, required this.text, this.style, this.textAlign = TextAlign.left});

  @override
  State<OverflowingText> createState() => _OverflowingTextState();
}

class _OverflowingTextState extends State<OverflowingText> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Animation<double> _offset = const AlwaysStoppedAnimation<double>(0);
  double _configuredDistance = 0;
  bool _configurationScheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant OverflowingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _configuredDistance = -1;
    }
  }

  void _scheduleConfiguration(double distance) {
    if (_configurationScheduled || (distance - _configuredDistance).abs() < 0.5) return;
    _configurationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _configurationScheduled = false;
      if (!mounted) return;
      _configure(distance);
    });
  }

  void _configure(double distance) {
    _configuredDistance = distance;
    _controller.stop();
    _controller.reset();
    if (distance <= 0) {
      _offset = const AlwaysStoppedAnimation<double>(0);
      return;
    }

    final travelMilliseconds = (distance * 18).round().clamp(1800, 5200);
    _controller.duration = Duration(milliseconds: travelMilliseconds * 2 + 2400);
    _offset = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(0), weight: 12),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: -distance).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 38,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(-distance), weight: 12),
      TweenSequenceItem(
        tween: Tween<double>(begin: -distance, end: 0).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 38,
      ),
    ]).animate(_controller);
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = widget.style ?? DefaultTextStyle.of(context).style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textDirection = Directionality.of(context);
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: effectiveStyle),
          maxLines: 1,
          textDirection: textDirection,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final availableWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : painter.width;
        final distance = (painter.width - availableWidth).clamp(0.0, double.infinity);
        _scheduleConfiguration(distance);

        if (distance <= 0) {
          return Text(widget.text, style: effectiveStyle, textAlign: widget.textAlign, maxLines: 1, softWrap: false);
        }

        return Semantics(
          label: widget.text,
          child: ExcludeSemantics(
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => Transform.translate(
                  key: const ValueKey('overflowing-text-motion'),
                  offset: Offset(textDirection == TextDirection.rtl ? -_offset.value : _offset.value, 0),
                  child: child,
                ),
                child: OverflowBox(
                  alignment: AlignmentDirectional.centerStart,
                  minWidth: painter.width,
                  maxWidth: painter.width,
                  child: SizedBox(
                    key: const ValueKey('overflowing-text-content'),
                    width: painter.width,
                    child: Text(
                      widget.text,
                      style: effectiveStyle,
                      maxLines: 1,
                      softWrap: false,
                      textDirection: textDirection,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
