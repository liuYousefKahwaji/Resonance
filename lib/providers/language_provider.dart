import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonance/l10n/app_languages.dart';

class LanguageProvider extends ChangeNotifier {
  static const preferenceKey = 'app_language';
  Locale _locale = const Locale('en');
  Locale get locale => _locale;

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(preferenceKey);
    _locale = supportedAppLocales.firstWhere(
      (locale) => locale.languageCode == saved,
      orElse: () => const Locale('en'),
    );
    notifyListeners();
  }

  Future<void> setLocale(Locale locale) async {
    if (!supportedAppLocales.contains(locale)) {
      throw ArgumentError.value(locale, 'locale', 'Unsupported language');
    }
    if (_locale == locale) return;
    _locale = locale;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(preferenceKey, locale.languageCode);
  }
}
