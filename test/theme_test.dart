import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('every style produces independent light and dark themes', () {
    for (final style in ResonanceThemeStyle.values) {
      final light = buildResonanceTheme(style, Brightness.light);
      final dark = buildResonanceTheme(style, Brightness.dark);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.colorScheme.primary, isNot(dark.colorScheme.primary));
    }
  });

  test('accent families are distinct and Void uses OLED black', () {
    final accents = {
      for (final style in ResonanceThemeStyle.values) buildResonanceTheme(style, Brightness.dark).colorScheme.primary,
    };
    expect(accents, hasLength(ResonanceThemeStyle.values.length));
    expect(buildResonanceTheme(ResonanceThemeStyle.voidTheme, Brightness.dark).scaffoldBackgroundColor, Colors.black);
  });

  test('theme style loads and persists independently from brightness', () async {
    SharedPreferences.setMockInitialValues({'theme_style': 'magma', 'is_dark_mode': true});
    final provider = ThemeProvider();
    await Future<void>.delayed(Duration.zero);
    expect(provider.themeStyle, ResonanceThemeStyle.magma);
    expect(provider.isDarkMode, isTrue);

    await provider.setThemeStyle(ResonanceThemeStyle.jade);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('theme_style'), 'jade');
    expect(preferences.getBool('is_dark_mode'), isTrue);
  });
}
