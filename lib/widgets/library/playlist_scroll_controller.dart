import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

/// Eases discrete desktop wheel input. Touch and scrollbar drags still use
/// the platform's ordinary scrolling behavior.
class PlaylistScrollController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _PlaylistScrollPosition(
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
      );
}

class _PlaylistScrollPosition extends ScrollPositionWithSingleContext {
  _PlaylistScrollPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    required super.oldPosition,
  });

  DrivenScrollActivity? _wheelActivity;
  _WheelMotion? _wheelMotion;

  @override
  void pointerScroll(double delta) {
    final scrollContext = context.notificationContext ?? context.storageContext;
    if (delta == 0 || MediaQuery.maybeDisableAnimationsOf(scrollContext) == true) {
      super.pointerScroll(delta);
      return;
    }

    final motion = identical(activity, _wheelActivity) ? _wheelMotion : null;
    final pending = motion?.target ?? pixels;
    // Preserve repeated wheel ticks while letting a reversal take effect from
    // the visible position immediately.
    final base = (pending - pixels) * delta > 0 ? pending : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent).toDouble();
    if (target == base) return;

    updateUserScrollDirection(delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse);
    if (motion != null) {
      motion.retarget(pixels, target);
      return;
    }

    final next = _WheelMotion(pixels, target);
    final wheel = DrivenScrollActivity.simulation(this, next, vsync: context.vsync);
    _wheelMotion = next;
    _wheelActivity = wheel;
    beginActivity(wheel);
  }
}

/// Continuous input steers an existing ticker instead of restarting the
/// activity and losing a frame on each wheel event.
class _WheelMotion extends Simulation {
  _WheelMotion(this._from, this.target);

  static const _durationSeconds = .11;
  double _from;
  double target;
  double _lastTime = 0;
  double _startedAt = 0;

  void retarget(double from, double to) {
    _from = from;
    target = to;
    _startedAt = _lastTime;
  }

  double _remaining(double time) => (1 - (time - _startedAt) / _durationSeconds).clamp(0, 1).toDouble();

  @override
  double x(double time) {
    _lastTime = time;
    final remaining = _remaining(time);
    return target - (target - _from) * remaining * remaining * remaining;
  }

  @override
  double dx(double time) {
    final remaining = _remaining(time);
    return 3 * (target - _from) / _durationSeconds * remaining * remaining;
  }

  @override
  bool isDone(double time) => time - _startedAt >= _durationSeconds;
}
