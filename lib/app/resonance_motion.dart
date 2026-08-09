import 'package:flutter/material.dart';

/// Shared motion tokens used throughout Resonance. Keeping these in one place
/// makes transitions feel related and gives reduced-motion users one reliable
/// switch instead of a collection of widget-specific exceptions.
@immutable
class ResonanceMotionTheme extends ThemeExtension<ResonanceMotionTheme> {
  final Duration press;
  final Duration stateChange;
  final Duration contentTransition;
  final Duration emphasizedNavigation;
  final Curve standardCurve;
  final Curve emphasizedCurve;
  final Curve exitCurve;

  const ResonanceMotionTheme({
    this.press = const Duration(milliseconds: 125),
    this.stateChange = const Duration(milliseconds: 210),
    this.contentTransition = const Duration(milliseconds: 380),
    this.emphasizedNavigation = const Duration(milliseconds: 520),
    this.standardCurve = Curves.easeOutCubic,
    this.emphasizedCurve = Curves.easeOutQuart,
    this.exitCurve = Curves.easeInCubic,
  });

  @override
  ResonanceMotionTheme copyWith({
    Duration? press,
    Duration? stateChange,
    Duration? contentTransition,
    Duration? emphasizedNavigation,
    Curve? standardCurve,
    Curve? emphasizedCurve,
    Curve? exitCurve,
  }) => ResonanceMotionTheme(
    press: press ?? this.press,
    stateChange: stateChange ?? this.stateChange,
    contentTransition: contentTransition ?? this.contentTransition,
    emphasizedNavigation: emphasizedNavigation ?? this.emphasizedNavigation,
    standardCurve: standardCurve ?? this.standardCurve,
    emphasizedCurve: emphasizedCurve ?? this.emphasizedCurve,
    exitCurve: exitCurve ?? this.exitCurve,
  );

  @override
  ResonanceMotionTheme lerp(covariant ResonanceMotionTheme? other, double t) => t < .5 ? this : (other ?? this);
}

ResonanceMotionTheme resonanceMotion(BuildContext context) =>
    Theme.of(context).extension<ResonanceMotionTheme>() ?? const ResonanceMotionTheme();

Duration resonanceDuration(BuildContext context, Duration duration) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
