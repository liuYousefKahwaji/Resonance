import 'package:flutter/material.dart';

/// Only the active row animates. Selection and artwork stay steady, and the
/// overlay repaints without rebuilding any row contents.
class CurrentTrackSurface extends StatefulWidget {
  const CurrentTrackSurface({
    super.key,
    required this.enabled,
    required this.decoration,
    required this.child,
    required this.duration,
    required this.curve,
  });
  final bool enabled;
  final BoxDecoration decoration;
  final Widget child;
  final Duration duration;
  final Curve curve;
  @override
  State<CurrentTrackSurface> createState() => _CurrentTrackSurfaceState();
}

class _CurrentTrackSurfaceState extends State<CurrentTrackSurface> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  void _sync() {
    final animate = widget.enabled && !MediaQuery.disableAnimationsOf(context) && TickerMode.of(context);
    if (animate && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!animate) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(CurrentTrackSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: widget.duration,
    curve: widget.curve,
    decoration: widget.decoration,
    child: Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => DecoratedBox(
                key: const Key('current-track-pulse'),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: Curves.easeInOut.transform(_pulse.value) * .045),
                  borderRadius: widget.decoration.borderRadius,
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    ),
  );
}
