import 'dart:io';

import 'package:flutter/material.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/services/artwork_palette_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  ResonanceThemeStyle _themeStyle = ResonanceThemeStyle.obsidian;
  bool _fullThemePalette = true;
  bool _artworkPlayerColors = false;
  bool _windowsNativeControls = Platform.isWindows;
  ArtworkPalette? _artworkPalette;
  final ArtworkPaletteService _artworkPaletteService = ArtworkPaletteService();
  String? _currentArtworkKey;
  int _paletteGeneration = 0;

  ThemeMode get themeMode => _themeMode;
  bool get isDarkMode => _themeMode == ThemeMode.dark;
  ResonanceThemeStyle get themeStyle => _themeStyle;
  bool get fullThemePalette => _fullThemePalette;
  bool get artworkPlayerColors => _artworkPlayerColors;
  bool get windowsNativeControls => _windowsNativeControls;
  bool get hasArtworkPalette => _artworkPlayerColors && _artworkPalette != null;
  bool get preserveOledPlayerSurface => _themeStyle == ResonanceThemeStyle.voidTheme;

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('is_dark_mode') ?? false;
    _themeStyle = ResonanceThemeStyleLabel.fromStorage(prefs.getString('theme_style'));
    _fullThemePalette = prefs.getBool('theme_full_palette') ?? true;
    _windowsNativeControls = prefs.getBool('windows_native_controls') ?? Platform.isWindows;
    final artworkPlayerColors = prefs.getBool('artwork_player_colors') ?? false;
    if (artworkPlayerColors && !_artworkPlayerColors && _currentArtworkKey != null) {
      // The player can publish its current artwork before async preferences
      // finish loading. Invalidate that disabled-state observation so the
      // rebuild below actually extracts the already-playing track's palette.
      _currentArtworkKey = null;
    }
    _artworkPlayerColors = artworkPlayerColors;
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  Future<void> toggleTheme(bool isDark) async {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_dark_mode', isDark);
  }

  Future<void> setThemeStyle(ResonanceThemeStyle style) async {
    if (_themeStyle == style) return;
    _themeStyle = style;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_style', style.storageName);
  }

  Future<void> setFullThemePalette(bool enabled) async {
    if (_fullThemePalette == enabled) return;
    _fullThemePalette = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('theme_full_palette', enabled);
  }

  Future<void> setArtworkPlayerColors(bool enabled) async {
    if (_artworkPlayerColors == enabled) return;
    _artworkPlayerColors = enabled;
    if (!enabled) {
      _paletteGeneration++;
      _artworkPalette = null;
    } else if (_currentArtworkKey != null) {
      _currentArtworkKey = null;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('artwork_player_colors', enabled);
  }

  Future<void> setWindowsNativeControls(bool enabled) async {
    if (_windowsNativeControls == enabled) return;
    _windowsNativeControls = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('windows_native_controls', enabled);
  }

  Future<void> updatePlayerArtwork(Uri? artworkUri) async {
    final key = artworkUri?.toString();
    if (_currentArtworkKey == key) return;
    _currentArtworkKey = key;
    final generation = ++_paletteGeneration;
    if (!_artworkPlayerColors || artworkUri == null) {
      if (_artworkPalette != null) {
        _artworkPalette = null;
        notifyListeners();
      }
      return;
    }
    final palette = await _artworkPaletteService.paletteFor(artworkUri);
    if (generation != _paletteGeneration || _currentArtworkKey != key) return;
    _artworkPalette = palette;
    notifyListeners();
  }

  Color playerAccent(Color base, Brightness brightness) {
    final extracted = _artworkPalette?.primary;
    if (!_artworkPlayerColors || extracted == null) return base;
    final blended = Color.alphaBlend(extracted.withValues(alpha: 0.72), base);
    final hsl = HSLColor.fromColor(blended);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.42, 0.88))
        .withLightness(
          brightness == Brightness.dark ? hsl.lightness.clamp(0.44, 0.70) : hsl.lightness.clamp(0.28, 0.54),
        )
        .toColor();
  }

  Color playerSecondary(Color base, Brightness brightness) {
    final extracted = _artworkPalette?.secondary;
    if (!_artworkPlayerColors || extracted == null) return base;
    final blended = Color.alphaBlend(extracted.withValues(alpha: 0.64), base);
    final hsl = HSLColor.fromColor(blended);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.36, 0.82))
        .withLightness(
          brightness == Brightness.dark ? hsl.lightness.clamp(0.40, 0.66) : hsl.lightness.clamp(0.30, 0.57),
        )
        .toColor();
  }
}
