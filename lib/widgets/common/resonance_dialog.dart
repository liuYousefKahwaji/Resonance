import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:resonance/app/route_transitions.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/l10n/app_strings.dart';

/// Windows keeps slider overlay semantics attached throughout the entrance.
/// Android retains the standard Material route and transition.
Future<T?> showResonanceDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
  AnimationStyle? animationStyle,
}) {
  if (Theme.of(context).platform != TargetPlatform.windows) {
    return showDialog<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior: traversalEdgeBehavior,
      fullscreenDialog: fullscreenDialog,
      requestFocus: requestFocus,
      animationStyle: animationStyle,
    );
  }
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push<T>(
    _WindowsDialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor ?? DialogTheme.of(context).barrierColor ?? Colors.black54,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior: traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
      fullscreenDialog: fullscreenDialog,
      requestFocus: requestFocus,
      animationStyle: animationStyle,
    ),
  );
}

class _WindowsDialogRoute<T> extends DialogRoute<T> {
  _WindowsDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.anchorPoint,
    super.traversalEdgeBehavior,
    super.fullscreenDialog,
    super.requestFocus,
    super.animationStyle,
  });

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => resonanceFadeTransition(context, animation, secondaryAnimation, child);
}

/// Shared prompts use desktop spacing, controls and a separate action footer on
/// Windows. Android keeps the familiar Material dialog and all caller behavior.
class ResonanceDialog extends AlertDialog {
  const ResonanceDialog({
    super.key,
    super.icon,
    super.iconPadding,
    super.iconColor,
    super.title,
    super.titlePadding,
    super.titleTextStyle,
    super.content,
    super.contentPadding,
    super.contentTextStyle,
    super.actions,
    super.actionsPadding,
    super.actionsAlignment,
    super.actionsOverflowAlignment,
    super.actionsOverflowDirection,
    super.actionsOverflowButtonSpacing,
    super.buttonPadding,
    super.backgroundColor,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.semanticLabel,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.alignment,
    super.constraints,
    super.scrollable,
  });

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) {
      return AlertDialog(
        icon: icon,
        iconPadding: iconPadding,
        iconColor: iconColor,
        title: title,
        titlePadding: titlePadding,
        titleTextStyle: titleTextStyle,
        content: content,
        contentPadding: contentPadding,
        contentTextStyle: contentTextStyle,
        actions: actions,
        actionsPadding: actionsPadding,
        actionsAlignment: actionsAlignment,
        actionsOverflowAlignment: actionsOverflowAlignment,
        actionsOverflowDirection: actionsOverflowDirection,
        actionsOverflowButtonSpacing: actionsOverflowButtonSpacing,
        buttonPadding: buttonPadding,
        backgroundColor: backgroundColor,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        semanticLabel: semanticLabel,
        insetPadding: insetPadding,
        clipBehavior: clipBehavior,
        shape: shape,
        alignment: alignment,
        constraints: constraints,
        scrollable: scrollable,
      );
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = resonanceCornerRadius(context, 8, rounderRadius: 12);
    final surface = backgroundColor ?? colors.surface;
    final footer = Color.alphaBlend(colors.onSurface.withValues(alpha: .035), surface);
    final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(4));
    final desktop = theme.copyWith(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textTheme: theme.textTheme.apply(fontFamily: 'Segoe UI'),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: colors.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: colors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: colors.primary),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(style: ButtonStyle(shape: WidgetStatePropertyAll(buttonShape))),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: buttonShape, minimumSize: const Size(88, 32)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: buttonShape, minimumSize: const Size(88, 32)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: buttonShape, minimumSize: const Size(0, 32)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: buttonShape, minimumSize: const Size(88, 32)),
      ),
      popupMenuTheme: theme.popupMenuTheme.copyWith(
        shape: buttonShape,
        elevation: 8,
        surfaceTintColor: Colors.transparent,
      ),
    );
    final maxWidth = math.max(0.0, math.min(760.0, MediaQuery.sizeOf(context).width - 48));
    bool primaryAction(int i) =>
        i == actions!.length - 1 &&
        !(actions![i] is ButtonStyleButton && (actions![i] as ButtonStyleButton).style?.foregroundColor != null);
    return Theme(
      data: desktop,
      child: Dialog(
        key: const Key('windows-dialog-frame'),
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 16,
        shadowColor: Colors.black.withValues(alpha: .3),
        insetPadding: insetPadding ?? const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: colors.outlineVariant),
        ),
        alignment: alignment,
        constraints: constraints ?? BoxConstraints(minWidth: math.min(320, maxWidth), maxWidth: maxWidth),
        child: Semantics(
          namesRoute: true,
          label: semanticLabel,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null || icon != null)
                  Padding(
                    padding: titlePadding ?? const EdgeInsetsDirectional.fromSTEB(24, 22, 24, 16),
                    child: Row(
                      children: [
                        if (icon != null) ...[
                          IconTheme(
                            data: IconThemeData(color: iconColor ?? colors.primary, size: 24),
                            child: icon!,
                          ),
                          const SizedBox(width: 12),
                        ],
                        if (title != null)
                          Expanded(
                            child: DefaultTextStyle(
                              style:
                                  titleTextStyle ??
                                  desktop.textTheme.titleLarge!.copyWith(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w600,
                                    color: colors.onSurface,
                                  ),
                              child: title!,
                            ),
                          ),
                      ],
                    ),
                  ),
                if (content != null)
                  Flexible(
                    child: Padding(
                      padding: contentPadding ?? EdgeInsetsDirectional.fromSTEB(24, title == null ? 24 : 0, 24, 24),
                      child: DefaultTextStyle(
                        style: contentTextStyle ?? desktop.textTheme.bodyMedium!,
                        child: scrollable ? SingleChildScrollView(child: content!) : content!,
                      ),
                    ),
                  ),
                if (actions?.isNotEmpty == true)
                  DecoratedBox(
                    key: const Key('windows-dialog-footer'),
                    decoration: BoxDecoration(
                      color: footer,
                      border: Border(top: BorderSide(color: colors.outlineVariant)),
                    ),
                    child: Padding(
                      padding: actionsPadding ?? const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      child: OverflowBar(
                        alignment: actionsAlignment ?? MainAxisAlignment.end,
                        spacing: 8,
                        overflowSpacing: actionsOverflowButtonSpacing ?? 8,
                        overflowAlignment: actionsOverflowAlignment ?? OverflowBarAlignment.end,
                        overflowDirection: actionsOverflowDirection ?? VerticalDirection.down,
                        children: [
                          for (var i = 0; i < actions!.length; i++)
                            TextButtonTheme(
                              data: TextButtonThemeData(
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(88, 32),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                                  shape: buttonShape,
                                  foregroundColor: primaryAction(i) ? colors.onPrimary : colors.onSurface,
                                  backgroundColor: primaryAction(i) ? colors.primary : colors.surfaceContainerHighest,
                                  side: primaryAction(i) ? BorderSide.none : BorderSide(color: colors.outline),
                                ),
                              ),
                              child: Padding(padding: buttonPadding ?? EdgeInsets.zero, child: actions![i]),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ResonanceChoiceDialog extends SimpleDialog {
  const ResonanceChoiceDialog({super.key, super.title, super.children});

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) return SimpleDialog(title: title, children: children);
    return ResonanceDialog(
      title: title,
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children ?? const [],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel')))],
    );
  }
}
