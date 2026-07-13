import 'package:flutter/material.dart';

enum ResonanceThemeStyle { obsidian, jade, cobalt, magma, voidTheme }

extension ResonanceThemeStyleLabel on ResonanceThemeStyle {
  String get label => switch (this) {
    ResonanceThemeStyle.obsidian => 'Obsidian',
    ResonanceThemeStyle.jade => 'Jade',
    ResonanceThemeStyle.cobalt => 'Cobalt',
    ResonanceThemeStyle.magma => 'Magma',
    ResonanceThemeStyle.voidTheme => 'Void',
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
};

ThemeData buildResonanceTheme(ResonanceThemeStyle style, Brightness brightness, {bool fullPalette = true}) {
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
  final border = fullPalette
      ? (dark ? palette.darkBorder : palette.lightBorder)
      : dark
      ? const Color(0xFF30303A)
      : const Color(0xFFD8DCE5);

  final scheme =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
        primary: primary,
        secondary: secondary,
        surface: bgSurface,
      ).copyWith(
        onSurface: textPrimary,
        onSurfaceVariant: textMuted,
        outline: border,
        surfaceContainerHigh: bgElevated,
        surfaceContainerHighest: bgHighest,
      );

  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: bgBase,
    cardColor: bgSurface,
    colorScheme: scheme,
    appBarTheme: AppBarTheme(backgroundColor: bgBase, elevation: 0, surfaceTintColor: Colors.transparent),
    cardTheme: CardThemeData(
      color: bgSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: border),
      ),
    ),
    listTileTheme: ListTileThemeData(textColor: textPrimary, iconColor: textMuted),
    iconTheme: const IconThemeData(color: textMuted),
    dialogTheme: DialogThemeData(
      backgroundColor: bgSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bgElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
      labelStyle: const TextStyle(color: textMuted),
      hintStyle: TextStyle(color: dark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: secondary)),
    sliderTheme: SliderThemeData(
      activeTrackColor: primary,
      inactiveTrackColor: border,
      thumbColor: primary,
      overlayColor: primary.withValues(alpha: 0.15),
      trackHeight: 3,
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
        (states) => states.contains(WidgetState.selected) ? Colors.white : textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? primary : border),
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
