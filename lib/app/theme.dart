import 'package:flutter/material.dart';

@immutable
class ResonancePlatformTheme extends ThemeExtension<ResonancePlatformTheme> {
  final bool windowsNativeControls;

  const ResonancePlatformTheme({required this.windowsNativeControls});

  @override
  ResonancePlatformTheme copyWith({bool? windowsNativeControls}) =>
      ResonancePlatformTheme(windowsNativeControls: windowsNativeControls ?? this.windowsNativeControls);

  @override
  ResonancePlatformTheme lerp(covariant ResonancePlatformTheme? other, double t) {
    return t < 0.5 ? this : (other ?? this);
  }
}

bool useWindowsNativeControls(BuildContext context) =>
    Theme.of(context).extension<ResonancePlatformTheme>()?.windowsNativeControls ?? false;

enum ResonanceThemeStyle { obsidian, jade, cobalt, magma, voidTheme, quartz, aurum }

extension ResonanceThemeStyleLabel on ResonanceThemeStyle {
  String get label => switch (this) {
    ResonanceThemeStyle.obsidian => 'Obsidian',
    ResonanceThemeStyle.jade => 'Jade',
    ResonanceThemeStyle.cobalt => 'Cobalt',
    ResonanceThemeStyle.magma => 'Magma',
    ResonanceThemeStyle.voidTheme => 'Void',
    ResonanceThemeStyle.quartz => 'Quartz',
    ResonanceThemeStyle.aurum => 'Aurum',
  };

  // Dart enum values cannot be named `void`, so storage/UI use `void` while
  // the source identifier remains explicit.
  String get storageName => this == ResonanceThemeStyle.voidTheme ? 'void' : name;

  static ResonanceThemeStyle fromStorage(String? value) {
    if (value == 'void') return ResonanceThemeStyle.voidTheme;
    return ResonanceThemeStyle.values.firstWhere(
      (style) => style.name == value,
      orElse: () => ResonanceThemeStyle.obsidian,
    );
  }
}

class _Palette {
  final Color darkPrimary;
  final Color darkSecondary;
  final Color lightPrimary;
  final Color lightSecondary;
  final Color darkBase;
  final Color darkSurface;
  final Color darkElevated;
  final Color darkHighest;
  final Color darkBorder;
  final Color lightBase;
  final Color lightSurface;
  final Color lightElevated;
  final Color lightHighest;
  final Color lightBorder;

  const _Palette({
    required this.darkPrimary,
    required this.darkSecondary,
    required this.lightPrimary,
    required this.lightSecondary,
    this.darkBase = const Color(0xFF0D0D14),
    this.darkSurface = const Color(0xFF1A1A24),
    this.darkElevated = const Color(0xFF242430),
    this.darkHighest = const Color(0xFF30303A),
    this.darkBorder = const Color(0xFF30303A),
    this.lightBase = const Color(0xFFF6F3FB),
    this.lightSurface = const Color(0xFFFDFBFF),
    this.lightElevated = const Color(0xFFEFE9F8),
    this.lightHighest = const Color(0xFFE4DCF0),
    this.lightBorder = const Color(0xFFD5C9E5),
  });
}

_Palette _palette(ResonanceThemeStyle style) => switch (style) {
  ResonanceThemeStyle.obsidian => const _Palette(
    darkPrimary: Color(0xFF7C3AED),
    darkSecondary: Color(0xFFA855F7),
    lightPrimary: Color(0xFF6D28D9),
    lightSecondary: Color(0xFF7C3AED),
    darkBase: Color(0xFF0F0918),
    darkSurface: Color(0xFF191024),
    darkElevated: Color(0xFF261738),
    darkHighest: Color(0xFF352149),
    darkBorder: Color(0xFF4A3161),
    lightBase: Color(0xFFF7F1FC),
    lightSurface: Color(0xFFFEFBFF),
    lightElevated: Color(0xFFEEE2F7),
    lightHighest: Color(0xFFE2D1EF),
    lightBorder: Color(0xFFCFB7DF),
  ),
  ResonanceThemeStyle.jade => const _Palette(
    darkPrimary: Color(0xFF1DB954),
    darkSecondary: Color(0xFF4ADE80),
    lightPrimary: Color(0xFF15803D),
    lightSecondary: Color(0xFF16A34A),
    darkBase: Color(0xFF07140D),
    darkSurface: Color(0xFF0E2116),
    darkElevated: Color(0xFF17301F),
    darkHighest: Color(0xFF21402B),
    darkBorder: Color(0xFF285238),
    lightBase: Color(0xFFF0F8F2),
    lightSurface: Color(0xFFFBFEFC),
    lightElevated: Color(0xFFE2F1E6),
    lightHighest: Color(0xFFD4E8DA),
    lightBorder: Color(0xFFBAD6C3),
  ),
  ResonanceThemeStyle.cobalt => const _Palette(
    darkPrimary: Color(0xFF3B82F6),
    darkSecondary: Color(0xFF60A5FA),
    lightPrimary: Color(0xFF1D4ED8),
    lightSecondary: Color(0xFF2563EB),
    darkBase: Color(0xFF07111F),
    darkSurface: Color(0xFF0E1C30),
    darkElevated: Color(0xFF172A45),
    darkHighest: Color(0xFF203A5D),
    darkBorder: Color(0xFF294B75),
    lightBase: Color(0xFFEFF5FC),
    lightSurface: Color(0xFFFBFDFF),
    lightElevated: Color(0xFFDDEAF8),
    lightHighest: Color(0xFFCDDEF2),
    lightBorder: Color(0xFFB2CBE8),
  ),
  ResonanceThemeStyle.magma => const _Palette(
    darkPrimary: Color(0xFFFF1744),
    darkSecondary: Color(0xFFFF5252),
    lightPrimary: Color(0xFFC62828),
    lightSecondary: Color(0xFFE53935),
    darkBase: Color(0xFF18090B),
    darkSurface: Color(0xFF281013),
    darkElevated: Color(0xFF3A191D),
    darkHighest: Color(0xFF4D2228),
    darkBorder: Color(0xFF653037),
    lightBase: Color(0xFFFFF1F0),
    lightSurface: Color(0xFFFFFCFB),
    lightElevated: Color(0xFFF9E1DF),
    lightHighest: Color(0xFFF2D0CD),
    lightBorder: Color(0xFFE5B9B5),
  ),
  ResonanceThemeStyle.voidTheme => const _Palette(
    darkPrimary: Color(0xFFB8BDC7),
    darkSecondary: Color(0xFFE2E8F0),
    lightPrimary: Color(0xFF475569),
    lightSecondary: Color(0xFF64748B),
    darkBase: Color(0xFF000000),
    darkSurface: Color(0xFF0A0A0A),
    darkElevated: Color(0xFF151515),
    darkHighest: Color(0xFF222222),
    darkBorder: Color(0xFF303030),
    lightBase: Color(0xFFECEFF1),
    lightSurface: Color(0xFFF9FAFB),
    lightElevated: Color(0xFFE2E5E9),
    lightHighest: Color(0xFFD4D8DD),
    lightBorder: Color(0xFFBEC4CB),
  ),
  ResonanceThemeStyle.quartz => const _Palette(
    darkPrimary: Color(0xFFF1F3F5),
    darkSecondary: Color(0xFFC9CED6),
    lightPrimary: Color(0xFF4B5563),
    lightSecondary: Color(0xFF6B7280),
    darkBase: Color(0xFF0C0D0F),
    darkSurface: Color(0xFF17191D),
    darkElevated: Color(0xFF23262B),
    darkHighest: Color(0xFF30343A),
    darkBorder: Color(0xFF464B53),
    lightBase: Color(0xFFF4F5F7),
    lightSurface: Color(0xFFFFFFFF),
    lightElevated: Color(0xFFE8EAED),
    lightHighest: Color(0xFFDADDDF),
    lightBorder: Color(0xFFC5C9CF),
  ),
  ResonanceThemeStyle.aurum => const _Palette(
    darkPrimary: Color(0xFFF2C14E),
    darkSecondary: Color(0xFFD89B26),
    lightPrimary: Color(0xFF946200),
    lightSecondary: Color(0xFFB7791F),
    darkBase: Color(0xFF151006),
    darkSurface: Color(0xFF211809),
    darkElevated: Color(0xFF30230D),
    darkHighest: Color(0xFF413015),
    darkBorder: Color(0xFF5B4315),
    lightBase: Color(0xFFFFF8E7),
    lightSurface: Color(0xFFFFFCF4),
    lightElevated: Color(0xFFF7EBC7),
    lightHighest: Color(0xFFEEDCA3),
    lightBorder: Color(0xFFD8BE73),
  ),
};

ThemeData buildResonanceTheme(
  ResonanceThemeStyle style,
  Brightness brightness, {
  bool fullPalette = true,
  bool windowsNativeControls = false,
}) {
  final palette = _palette(style);
  final dark = brightness == Brightness.dark;
  final primary = dark ? palette.darkPrimary : palette.lightPrimary;
  final secondary = dark ? palette.darkSecondary : palette.lightSecondary;
  final voidStyle = style == ResonanceThemeStyle.voidTheme;
  final bgBase = fullPalette
      ? (dark ? palette.darkBase : palette.lightBase)
      : dark
      ? (voidStyle ? const Color(0xFF000000) : const Color(0xFF0D0D14))
      : const Color(0xFFF3F4F6);
  final bgSurface = fullPalette
      ? (dark ? palette.darkSurface : palette.lightSurface)
      : dark
      ? (voidStyle ? const Color(0xFF0A0A0A) : const Color(0xFF1A1A24))
      : Colors.white;
  final bgElevated = fullPalette
      ? (dark ? palette.darkElevated : palette.lightElevated)
      : dark
      ? (voidStyle ? const Color(0xFF151515) : const Color(0xFF242430))
      : const Color(0xFFF8FAFC);
  final bgHighest = fullPalette
      ? (dark ? palette.darkHighest : palette.lightHighest)
      : dark
      ? const Color(0xFF30303A)
      : const Color(0xFFE9ECF2);
  final textPrimary = dark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A);
  const textMuted = Color(0xFF64748B);
  final onPrimary = ThemeData.estimateBrightnessForColor(primary) == Brightness.dark
      ? Colors.white
      : const Color(0xFF111318);
  final border = fullPalette
      ? (dark ? palette.darkBorder : palette.lightBorder)
      : dark
      ? const Color(0xFF30303A)
      : const Color(0xFFD8DCE5);
  final controlRadius = windowsNativeControls ? 5.0 : 10.0;
  final surfaceRadius = windowsNativeControls ? 8.0 : 14.0;
  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius));
  final appBackground = windowsNativeControls
      ? Color.alphaBlend(primary.withValues(alpha: dark ? 0.035 : 0.025), bgBase)
      : bgBase;
  final appSurface = windowsNativeControls
      ? Color.alphaBlend(primary.withValues(alpha: dark ? 0.025 : 0.018), bgSurface)
      : bgSurface;

  final scheme =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
        primary: primary,
        onPrimary: onPrimary,
        secondary: secondary,
        surface: appSurface,
      ).copyWith(
        onSurface: textPrimary,
        onSurfaceVariant: textMuted,
        outline: border,
        surfaceContainerHigh: bgElevated,
        surfaceContainerHighest: bgHighest,
        surfaceContainerLow: appBackground,
      );

  return ThemeData(
    brightness: brightness,
    useMaterial3: true,
    fontFamily: windowsNativeControls ? 'Segoe UI' : null,
    visualDensity: windowsNativeControls ? const VisualDensity(horizontal: -1, vertical: -1) : VisualDensity.standard,
    materialTapTargetSize: windowsNativeControls ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
    splashFactory: windowsNativeControls ? NoSplash.splashFactory : null,
    hoverColor: primary.withValues(alpha: dark ? 0.11 : 0.07),
    focusColor: primary.withValues(alpha: dark ? 0.18 : 0.12),
    scaffoldBackgroundColor: appBackground,
    canvasColor: appSurface,
    cardColor: appSurface,
    colorScheme: scheme,
    extensions: [ResonancePlatformTheme(windowsNativeControls: windowsNativeControls)],
    appBarTheme: AppBarTheme(
      backgroundColor: windowsNativeControls ? appSurface : appBackground,
      foregroundColor: textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: windowsNativeControls ? false : null,
      toolbarHeight: windowsNativeControls ? 46 : null,
      titleSpacing: windowsNativeControls ? 14 : null,
      titleTextStyle: TextStyle(
        color: textPrimary,
        fontFamily: windowsNativeControls ? 'Segoe UI' : null,
        fontSize: windowsNativeControls ? 16 : 18,
        fontWeight: FontWeight.w600,
      ),
      surfaceTintColor: Colors.transparent,
      shape: windowsNativeControls ? Border(bottom: BorderSide(color: border)) : null,
    ),
    cardTheme: CardThemeData(
      color: appSurface,
      elevation: windowsNativeControls ? 1 : 0,
      shadowColor: windowsNativeControls ? Colors.black.withValues(alpha: dark ? 0.28 : 0.10) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(surfaceRadius),
        side: BorderSide(color: border),
      ),
    ),
    listTileTheme: ListTileThemeData(
      textColor: textPrimary,
      iconColor: textMuted,
      dense: windowsNativeControls,
      minVerticalPadding: windowsNativeControls ? 6 : null,
      horizontalTitleGap: windowsNativeControls ? 12 : null,
      shape: windowsNativeControls ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)) : null,
      selectedTileColor: primary.withValues(alpha: dark ? 0.16 : 0.09),
    ),
    iconTheme: const IconThemeData(color: textMuted),
    dialogTheme: DialogThemeData(
      backgroundColor: appSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(windowsNativeControls ? 8 : 20),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bgElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(controlRadius),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(controlRadius),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(controlRadius),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
      labelStyle: const TextStyle(color: textMuted),
      hintStyle: TextStyle(color: dark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
      contentPadding: windowsNativeControls ? const EdgeInsets.symmetric(horizontal: 11, vertical: 9) : null,
      prefixIconConstraints: windowsNativeControls ? const BoxConstraints(minWidth: 36, minHeight: 32) : null,
      suffixIconConstraints: windowsNativeControls ? const BoxConstraints(minWidth: 36, minHeight: 32) : null,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        minimumSize: windowsNativeControls ? const Size(0, 32) : null,
        padding: windowsNativeControls ? const EdgeInsets.symmetric(horizontal: 14, vertical: 7) : null,
        shape: controlShape,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: windowsNativeControls ? const Size(0, 32) : null,
        padding: windowsNativeControls ? const EdgeInsets.symmetric(horizontal: 14, vertical: 7) : null,
        shape: controlShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: windowsNativeControls ? const Size(0, 32) : null,
        padding: windowsNativeControls ? const EdgeInsets.symmetric(horizontal: 14, vertical: 7) : null,
        shape: controlShape,
        side: BorderSide(color: border),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: secondary,
        minimumSize: windowsNativeControls ? const Size(0, 30) : null,
        shape: controlShape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(controlShape),
        minimumSize: WidgetStatePropertyAll(windowsNativeControls ? const Size.square(32) : const Size.square(40)),
        padding: WidgetStatePropertyAll(windowsNativeControls ? const EdgeInsets.all(6) : null),
        backgroundColor: windowsNativeControls
            ? WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) return primary.withValues(alpha: dark ? 0.20 : 0.13);
                if (states.contains(WidgetState.hovered)) return primary.withValues(alpha: dark ? 0.12 : 0.07);
                return Colors.transparent;
              })
            : null,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: primary,
      inactiveTrackColor: border,
      thumbColor: primary,
      overlayColor: primary.withValues(alpha: 0.15),
      trackHeight: windowsNativeControls ? 2 : 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: windowsNativeControls ? 6 : 10),
    ),
    dividerColor: border,
    dividerTheme: DividerThemeData(color: border, thickness: 1),
    textTheme: TextTheme(
      titleLarge: TextStyle(color: textPrimary, fontWeight: FontWeight.w700, fontSize: 18),
      titleMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.w600, fontSize: 15),
      bodyMedium: TextStyle(color: textPrimary, fontSize: 14),
      bodySmall: const TextStyle(color: textMuted, fontSize: 12),
      labelSmall: const TextStyle(color: textMuted, fontSize: 11, letterSpacing: 0.5),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: bgElevated,
      contentTextStyle: TextStyle(color: textPrimary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? scheme.onPrimary : textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? primary : border),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? Colors.transparent : textMuted,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(windowsNativeControls ? 5 : 7),
      radius: Radius.circular(windowsNativeControls ? 2 : 8),
      thumbVisibility: const WidgetStatePropertyAll(false),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: appSurface,
      surfaceTintColor: Colors.transparent,
      elevation: windowsNativeControls ? 8 : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(windowsNativeControls ? 4 : 14),
        side: windowsNativeControls ? BorderSide(color: border) : BorderSide.none,
      ),
      position: windowsNativeControls ? PopupMenuPosition.under : PopupMenuPosition.over,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(appSurface),
        elevation: WidgetStatePropertyAll(windowsNativeControls ? 8 : null),
        padding: WidgetStatePropertyAll(windowsNativeControls ? const EdgeInsets.symmetric(vertical: 3) : null),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(windowsNativeControls ? 4 : 14),
            side: windowsNativeControls ? BorderSide(color: border) : BorderSide.none,
          ),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(windowsNativeControls ? const Size(160, 32) : null),
        padding: WidgetStatePropertyAll(
          windowsNativeControls ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6) : null,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(windowsNativeControls ? 3 : controlRadius)),
        ),
        overlayColor: windowsNativeControls
            ? WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) return primary.withValues(alpha: 0.16);
                if (states.contains(WidgetState.hovered)) return primary.withValues(alpha: 0.09);
                return Colors.transparent;
              })
            : null,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(windowsNativeControls ? 2 : 4)),
      side: BorderSide(color: textMuted, width: 1),
      visualDensity: windowsNativeControls ? VisualDensity.compact : VisualDensity.standard,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: windowsNativeControls ? const Duration(milliseconds: 550) : null,
      decoration: windowsNativeControls
          ? BoxDecoration(
              color: dark ? const Color(0xFF2C2C2C) : const Color(0xFFF9F9F9),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: border),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 8)],
            )
          : null,
      textStyle: windowsNativeControls ? TextStyle(color: textPrimary, fontSize: 12) : null,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: appSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(windowsNativeControls ? 8 : 20)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: windowsNativeControls ? 48 : null,
      backgroundColor: appSurface,
      indicatorColor: primary.withValues(alpha: dark ? 0.22 : 0.12),
      indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(windowsNativeControls ? 4 : 16)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: appSurface,
      minWidth: windowsNativeControls ? 54 : null,
      indicatorColor: primary.withValues(alpha: dark ? 0.22 : 0.12),
      indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(windowsNativeControls ? 4 : 16)),
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: border,
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: windowsNativeControls ? UnderlineTabIndicator(borderSide: BorderSide(color: primary, width: 2)) : null,
      labelColor: textPrimary,
      unselectedLabelColor: textMuted,
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? primary : textMuted,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? primary.withValues(alpha: dark ? 0.2 : 0.1) : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? secondary : textMuted,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: border)),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
