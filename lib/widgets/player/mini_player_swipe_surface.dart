import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';

/// A dock gesture stays outside the page pager and yields vertical drags to expand.
class MiniPlayerSwipeSurface extends StatefulWidget {
  const MiniPlayerSwipeSurface({
    super.key,
    required this.child,
    required this.onNext,
    required this.onPrevious,
    required this.onExpand,
  });
  final Widget child;
  final VoidCallback onNext, onPrevious, onExpand;
  @override
  State<MiniPlayerSwipeSurface> createState() => _MiniPlayerSwipeSurfaceState();
}

class _MiniPlayerSwipeSurfaceState extends State<MiniPlayerSwipeSurface> {
  double _distance = 0;
  bool _dragging = false;
  void _reset() => setState(() {
    _distance = 0;
    _dragging = false;
  });
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return GestureDetector(
      key: const Key('mini-player-swipe-surface'),
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -180) widget.onExpand();
      },
      onHorizontalDragStart: (_) => setState(() {
        _distance = 0;
        _dragging = true;
      }),
      onHorizontalDragUpdate: (details) => setState(() => _distance = (_distance + details.delta.dx).clamp(-100, 100)),
      onHorizontalDragCancel: _reset,
      onHorizontalDragEnd: (details) {
        final distance = _distance;
        final velocity = details.primaryVelocity ?? 0;
        final accepted =
            distance.abs() >= 48 || (distance.abs() >= 14 && velocity.abs() >= 420 && distance * velocity > 0);
        _reset();
        if (accepted) {
          if (distance < 0) {
            widget.onNext();
          } else {
            widget.onPrevious();
          }
        }
      },
      child: ClipRect(
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedSlide(
              duration: reduced || _dragging ? Duration.zero : const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              offset: Offset(_distance / 900, 0),
              child: widget.child,
            ),
            Positioned(
              top: 0,
              bottom: 0,
              left: _distance > 0 ? 0 : null,
              right: _distance <= 0 ? 0 : null,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: reduced ? Duration.zero : const Duration(milliseconds: 100),
                  opacity: _dragging ? (_distance.abs() / 48).clamp(0, 1) : 0,
                  child: Container(
                    width: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Semantics(
                      label: context.tr(_distance < 0 ? 'Next' : 'Previous'),
                      child: Icon(_distance < 0 ? Icons.skip_next_rounded : Icons.skip_previous_rounded, size: 26),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
