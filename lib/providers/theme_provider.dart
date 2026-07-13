import 'package:flutter/material.dart';
import 'package:resonance/app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  ResonanceThemeStyle _themeStyle = ResonanceThemeStyle.obsidian;
  bool _fullThemePalette = true;

  ThemeMode get themeMode => _themeMode;
  bool get isDarkMode => _themeMode == ThemeMode.dark;
  ResonanceThemeStyle get themeStyle => _themeStyle;
  bool get fullThemePalette => _fullThemePalette;

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('is_dark_mode') ?? false;
    _themeStyle = ResonanceThemeStyleLabel.fromStorage(prefs.getString('theme_style'));
    _fullThemePalette = prefs.getBool('theme_full_palette') ?? true;
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
}
