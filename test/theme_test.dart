import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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

  test('each style changes the light and dark environment, not only its accent', () {
    final darkBackgrounds = {
      for (final style in ResonanceThemeStyle.values)
        buildResonanceTheme(style, Brightness.dark).scaffoldBackgroundColor,
    };
    final lightBackgrounds = {
      for (final style in ResonanceThemeStyle.values)
        buildResonanceTheme(style, Brightness.light).scaffoldBackgroundColor,
    };
    final darkSurfaces = {
      for (final style in ResonanceThemeStyle.values) buildResonanceTheme(style, Brightness.dark).colorScheme.surface,
    };

    expect(darkBackgrounds, hasLength(ResonanceThemeStyle.values.length));
    expect(lightBackgrounds, hasLength(ResonanceThemeStyle.values.length));
    expect(darkSurfaces, hasLength(ResonanceThemeStyle.values.length));
  });

  test('accent-only mode restores shared classic surfaces while preserving accents', () {
    final jade = buildResonanceTheme(ResonanceThemeStyle.jade, Brightness.dark, fullPalette: false);
    final cobalt = buildResonanceTheme(ResonanceThemeStyle.cobalt, Brightness.dark, fullPalette: false);

    expect(jade.scaffoldBackgroundColor, cobalt.scaffoldBackgroundColor);
    expect(jade.colorScheme.surface, cobalt.colorScheme.surface);
    expect(jade.colorScheme.primary, isNot(cobalt.colorScheme.primary));
  });

  test('Obsidian full styling is purple while accent-only mode uses classic surfaces', () {
    for (final brightness in Brightness.values) {
      final full = buildResonanceTheme(ResonanceThemeStyle.obsidian, brightness);
      final classic = buildResonanceTheme(ResonanceThemeStyle.obsidian, brightness, fullPalette: false);
      final classicJade = buildResonanceTheme(ResonanceThemeStyle.jade, brightness, fullPalette: false);

      expect(full.colorScheme.primary, classic.colorScheme.primary);
      expect(full.scaffoldBackgroundColor, isNot(classic.scaffoldBackgroundColor));
      expect(full.colorScheme.surface, isNot(classic.colorScheme.surface));
      expect(full.colorScheme.surfaceContainerHigh, isNot(classic.colorScheme.surfaceContainerHigh));
      expect(full.colorScheme.outline, isNot(classic.colorScheme.outline));
      expect(classic.scaffoldBackgroundColor, classicJade.scaffoldBackgroundColor);
      expect(classic.colorScheme.surface, classicJade.colorScheme.surface);
    }
  });

  test('Quartz and Aurum labels, storage names, and primary contrast are stable', () {
    expect(ResonanceThemeStyle.quartz.label, 'Quartz');
    expect(ResonanceThemeStyle.aurum.label, 'Aurum');
    expect(ResonanceThemeStyle.quartz.storageName, 'quartz');
    expect(ResonanceThemeStyle.aurum.storageName, 'aurum');
    expect(ResonanceThemeStyleLabel.fromStorage('quartz'), ResonanceThemeStyle.quartz);
    expect(ResonanceThemeStyleLabel.fromStorage('aurum'), ResonanceThemeStyle.aurum);

    for (final style in [ResonanceThemeStyle.quartz, ResonanceThemeStyle.aurum]) {
      for (final brightness in Brightness.values) {
        final scheme = buildResonanceTheme(style, brightness).colorScheme;
        expect(_contrastRatio(scheme.primary, scheme.onPrimary), greaterThanOrEqualTo(4.5));
        expect(scheme.primary, isNot(scheme.onPrimary));
      }
    }
  });

  test('theme style loads and persists independently from brightness', () async {
    SharedPreferences.setMockInitialValues({'theme_style': 'magma', 'is_dark_mode': true});
    final provider = ThemeProvider();
    await Future<void>.delayed(Duration.zero);
    expect(provider.themeStyle, ResonanceThemeStyle.magma);
    expect(provider.isDarkMode, isTrue);
    expect(provider.fullThemePalette, isTrue);
    expect(provider.artworkPlayerColors, isFalse);

    await provider.setThemeStyle(ResonanceThemeStyle.jade);
    await provider.setFullThemePalette(false);
    await provider.setArtworkPlayerColors(true);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('theme_style'), 'jade');
    expect(preferences.getBool('is_dark_mode'), isTrue);
    expect(preferences.getBool('theme_full_palette'), isFalse);
    expect(preferences.getBool('artwork_player_colors'), isTrue);
  });

  test('persisted artwork colors extract artwork observed before preferences load', () async {
    SharedPreferences.setMockInitialValues({'artwork_player_colors': true});
    final image = img.Image(width: 4, height: 4);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 205, 45, 70, 255);
      }
    }
    final artwork = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}resonance_theme_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await artwork.writeAsBytes(img.encodePng(image), flush: true);
    addTearDown(() async {
      if (await artwork.exists()) await artwork.delete();
    });

    final provider = ThemeProvider();
    await provider.updatePlayerArtwork(artwork.uri);
    await Future<void>.delayed(Duration.zero);

    expect(provider.artworkPlayerColors, isTrue);
    await provider.updatePlayerArtwork(artwork.uri);
    expect(provider.hasArtworkPalette, isTrue);
  });

  test('Windows-native mode changes control geometry without changing the palette', () {
    final classic = buildResonanceTheme(ResonanceThemeStyle.cobalt, Brightness.dark);
    final windows = buildResonanceTheme(ResonanceThemeStyle.cobalt, Brightness.dark, windowsNativeControls: true);

    expect(windows.colorScheme.primary, classic.colorScheme.primary);
    expect(windows.textTheme.bodyMedium?.fontFamily, 'Segoe UI');
    expect(windows.visualDensity, isNot(classic.visualDensity));
    expect(windows.sliderTheme.trackHeight, 2);
    expect(windows.extension<ResonancePlatformTheme>()?.windowsNativeControls, isTrue);
    expect(windows.appBarTheme.toolbarHeight, 46);
    expect(windows.appBarTheme.centerTitle, isFalse);
    expect(windows.inputDecorationTheme.contentPadding, const EdgeInsets.symmetric(horizontal: 11, vertical: 9));
    expect((windows.checkboxTheme.shape as RoundedRectangleBorder).borderRadius, BorderRadius.circular(2));
    expect(windows.popupMenuTheme.position, PopupMenuPosition.under);
  });

  test('Windows-native preference persists independently from the color theme', () async {
    SharedPreferences.setMockInitialValues({'windows_native_controls': false});
    final provider = ThemeProvider();
    await Future<void>.delayed(Duration.zero);
    expect(provider.windowsNativeControls, isFalse);

    await provider.setWindowsNativeControls(true);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('windows_native_controls'), isTrue);
  });
}

double _contrastRatio(Color a, Color b) {
  final lighter = a.computeLuminance() > b.computeLuminance() ? a : b;
  final darker = identical(lighter, a) ? b : a;
  return (lighter.computeLuminance() + 0.05) / (darker.computeLuminance() + 0.05);
}
