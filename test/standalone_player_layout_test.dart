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
}
