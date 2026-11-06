import 'package:provider/provider.dart';
import 'package:resonance/providers/theme_provider.dart';
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

/// Modern Android players rise from their dock and return down to it.
Route<T> resonancePlayerRoute<T>(BuildContext context, WidgetBuilder builder) {
  final vertical =
      Theme.of(context).platform == TargetPlatform.android && (context.read<ThemeProvider?>()?.modernLayout ?? false);
  if (!vertical) return MaterialPageRoute<T>(builder: builder);
  final reduced = MediaQuery.disableAnimationsOf(context);
  return PageRouteBuilder<T>(
    pageBuilder: (context, _, __) => builder(context),
    transitionDuration: reduced ? Duration.zero : const Duration(milliseconds: 360),
    reverseTransitionDuration: reduced ? Duration.zero : const Duration(milliseconds: 300),
    transitionsBuilder: (context, animation, secondary, child) => SlideTransition(
      position: Tween(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}
