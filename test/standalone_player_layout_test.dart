import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';

void main() {
  test('standalone artwork remains bounded on compact screens', () {
    const constraints = BoxConstraints(maxWidth: 320, maxHeight: 180);
    final size = standaloneArtworkSize(constraints);

    expect(size, lessThanOrEqualTo(constraints.maxWidth * 0.66));
    expect(size, lessThanOrEqualTo(constraints.maxHeight * 0.76));
    expect(size, greaterThanOrEqualTo(0));
  });

  test('standalone artwork has a desktop size cap', () {
    const constraints = BoxConstraints(maxWidth: 1800, maxHeight: 1200);
    expect(standaloneArtworkSize(constraints), 420);
  });

  test('lyrics panel keeps a small balanced vertical inset', () {
    expect(
      standaloneLyricsVerticalInset(const BoxConstraints(maxWidth: 360, maxHeight: 320)),
      closeTo(11.2, 0.001),
    );
    expect(standaloneLyricsVerticalInset(const BoxConstraints(maxWidth: 900, maxHeight: 100)), 10);
    expect(standaloneLyricsVerticalInset(const BoxConstraints(maxWidth: 1600, maxHeight: 1200)), 24);
  });

  test('standalone gradient blends the selected accent into the dark base', () {
    final theme = ThemeData.dark().copyWith(
      scaffoldBackgroundColor: const Color(0xFF101014),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF10B981), brightness: Brightness.dark),
    );
    final colors = standaloneGradientColors(theme);

    expect(colors, hasLength(3));
    expect(colors.first, isNot(theme.scaffoldBackgroundColor));
    expect(colors.last, theme.scaffoldBackgroundColor);
  });

  test('standalone gradient blends the selected accent into the light base', () {
    final theme = ThemeData.light().copyWith(
      scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
    );
    final colors = standaloneGradientColors(theme);

    expect(colors.first, isNot(theme.scaffoldBackgroundColor));
    expect(colors.last, theme.scaffoldBackgroundColor);
  });

  test('standalone gradient can blend two artwork-derived accents', () {
    final theme = ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF101014));
    final colors = standaloneGradientColors(
      theme,
      playerAccent: const Color(0xFFE24A62),
      playerSecondary: const Color(0xFF3478D4),
    );

    expect(colors.first, isNot(colors[1]));
    expect(colors.last, theme.scaffoldBackgroundColor);
  });

  test('standalone gradient combines three cover colors', () {
    final theme = ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF101014));
    final colors = standaloneGradientColors(
      theme,
      playerColors: const [Color(0xFFE24A62), Color(0xFF3478D4), Color(0xFFF2C14E)],
    );

    expect(colors, hasLength(4));
    expect(colors.toSet(), hasLength(4));
  });

  test('black and white cover colors use normal strength in either theme', () {
    final darkTheme = ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF101014));
    final lightTheme = ThemeData.light().copyWith(scaffoldBackgroundColor: const Color(0xFFF6F5F2));

    expect(
      standaloneGradientColors(darkTheme, playerColors: const [Colors.white]).first,
      Color.alphaBlend(Colors.white.withValues(alpha: 0.64), darkTheme.scaffoldBackgroundColor),
    );
    expect(
      standaloneGradientColors(lightTheme, playerColors: const [Colors.black]).first,
      Color.alphaBlend(Colors.black.withValues(alpha: 0.42), lightTheme.scaffoldBackgroundColor),
    );
  });

  test('OLED preservation keeps the standalone surface true black', () {
    final theme = ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black);
    final colors = standaloneGradientColors(
      theme,
      playerAccent: const Color(0xFFE24A62),
      playerSecondary: const Color(0xFF3478D4),
      preserveOledSurface: true,
    );

    expect(colors, everyElement(Colors.black));
  });

  test('standalone gradient fields move visibly and loop without a seam', () {
    final start = standaloneGradientFrame(0);
    final quarter = standaloneGradientFrame(0.25);
    final end = standaloneGradientFrame(1);

    expect(start.primaryCenter.dx, closeTo(end.primaryCenter.dx, 0.000001));
    expect(start.primaryCenter.dy, closeTo(end.primaryCenter.dy, 0.000001));
    expect(start.secondaryCenter.dx, closeTo(end.secondaryCenter.dx, 0.000001));
    expect(start.secondaryCenter.dy, closeTo(end.secondaryCenter.dy, 0.000001));
    expect(start.tertiaryCenter.dx, closeTo(end.tertiaryCenter.dx, 0.000001));
    expect(start.tertiaryCenter.dy, closeTo(end.tertiaryCenter.dy, 0.000001));
    expect(start.primaryRadius, closeTo(end.primaryRadius, 0.000001));
    expect(start.secondaryRadius, closeTo(end.secondaryRadius, 0.000001));
    expect(start.tertiaryRadius, closeTo(end.tertiaryRadius, 0.000001));
    expect((quarter.primaryCenter - start.primaryCenter).distance, greaterThan(0.35));
    expect((quarter.secondaryCenter - start.secondaryCenter).distance, greaterThan(0.35));

    final justBeforeWrap = standaloneGradientFrame(0.999);
    final justAfterWrap = standaloneGradientFrame(0.001);
    expect((justAfterWrap.primaryCenter - justBeforeWrap.primaryCenter).distance, lessThan(0.01));
    expect((justAfterWrap.secondaryCenter - justBeforeWrap.secondaryCenter).distance, lessThan(0.01));
  });

  testWidgets('standalone gradient remains static when reduced motion is enabled', (tester) async {
    const colors = <Color>[Color(0xFF321050), Color(0xFF21152E), Color(0xFF0F0918)];
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: StandaloneGradientSurface(colors: colors, child: SizedBox.expand()),
        ),
      ),
    );

    StandaloneGradientFrame frame() {
      final paint = tester.widget<CustomPaint>(find.byKey(const Key('standalone-animated-gradient')));
      return (paint.painter! as StandaloneGradientPainter).frame;
    }

    final before = frame();
    await tester.pump(const Duration(seconds: 6));
    final after = frame();
    expect(after.primaryCenter, before.primaryCenter);
    expect(after.secondaryCenter, before.secondaryCenter);
    expect(after.tertiaryCenter, before.tertiaryCenter);
  });

  testWidgets('standalone gradient moves while animations are enabled', (tester) async {
    const colors = <Color>[Color(0xFF321050), Color(0xFF21152E), Color(0xFF0F0918)];
    await tester.pumpWidget(
      const MaterialApp(
        home: StandaloneGradientSurface(colors: colors, child: SizedBox.expand()),
      ),
    );

    StandaloneGradientFrame frame() {
      final paint = tester.widget<CustomPaint>(find.byKey(const Key('standalone-animated-gradient')));
      return (paint.painter! as StandaloneGradientPainter).frame;
    }

    final before = frame();
    await tester.pump(const Duration(seconds: 4));
    final after = frame();
    expect((after.primaryCenter - before.primaryCenter).distance, greaterThan(0.35));
    expect(after.secondaryCenter, isNot(before.secondaryCenter));
  });
}
