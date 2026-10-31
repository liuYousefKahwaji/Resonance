import 'package:flutter/material.dart';

/// Route entrance used for Windows pages that can contain slider overlays.
Widget resonancePageTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) => FadeTransition(
  // Flutter <=3.44 can serialize a slider's overlay without its traversal
  // parent when a route starts at zero opacity (flutter/flutter#190357).
  alwaysIncludeSemantics: Theme.of(context).platform == TargetPlatform.windows,
  opacity: animation,
  child: SlideTransition(
    position: Tween<Offset>(begin: const Offset(0, .025), end: Offset.zero).animate(animation),
    child: child,
  ),
);

/// Hero's first-frame offstage measurement also detaches slider traversal
/// parents in affected Flutter versions. Windows uses the page fade instead;
/// keep Android's shared-artwork Hero flights. No accessibility is disabled.
Widget resonanceNavigatorSemantics(BuildContext context, Widget child) =>
    Theme.of(context).platform == TargetPlatform.windows ? HeroControllerScope.none(child: child) : child;

Widget resonanceFadeTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) => FadeTransition(
  alwaysIncludeSemantics: Theme.of(context).platform == TargetPlatform.windows,
  opacity: animation,
  child: child,
);

class ResonanceWindowsPageTransitionsBuilder extends PageTransitionsBuilder {
  const ResonanceWindowsPageTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => resonancePageTransition(context, animation, secondaryAnimation, child);
}
