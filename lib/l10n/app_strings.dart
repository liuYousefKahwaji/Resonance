import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:resonance/providers/language_provider.dart';

import 'arabic_messages.dart';
import 'app_languages.dart';

/// English templates are stable message keys. Arguments are interpolated only
/// after translation, so names, paths and song metadata are never translated.
class AppStrings {
  const AppStrings(this.locale);

  final Locale locale;
  static const supportedLocales = supportedAppLocales;
  static const delegate = _AppStringsDelegate();

  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings) ??
      AppStrings(context.read<LanguageProvider?>()?.locale ?? const Locale('en'));

  String text(String template, [List<Object?> arguments = const []]) {
    var translated = locale.languageCode == 'ar' ? arabicMessages[template] ?? template : template;
    translated = translated.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
      final i = int.parse(match[1]!);
      if (i >= arguments.length) return match[0]!;
      final value = arguments[i]?.toString() ?? '';
      // Isolate mixed Arabic/Latin names, URLs and numbers from surrounding UI.
      return locale.languageCode == 'ar' ? '\u2068$value\u2069' : value;
    });
    return translated;
  }

  /// For status messages from platform/services that already contain values.
  /// Only call this for app-owned labels, never song titles or user input.
  String rendered(String value) {
    if (locale.languageCode != 'ar') return value;
    if (arabicMessages.containsKey(value)) return arabicMessages[value]!;
    for (final entry in _renderedTemplates) {
      final match = entry.pattern.firstMatch(value);
      if (match != null) return text(entry.template, [for (var i = 1; i <= match.groupCount; i++) match[i]]);
    }
    return value;
  }

  static final _renderedTemplates = [
    for (final template in arabicMessages.keys)
      if (template.contains('{0}') && RegExp(r'[a-zA-Z]').hasMatch(template))
        (
          template: template,
          pattern: RegExp('^${template.split(RegExp(r'\{\d+\}')).map(RegExp.escape).join('(.*?)')}\$', dotAll: true),
        ),
  ];
}

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();
  @override
  bool isSupported(Locale locale) =>
      AppStrings.supportedLocales.any((supported) => supported.languageCode == locale.languageCode);
  @override
  Future<AppStrings> load(Locale locale) => SynchronousFuture(AppStrings(locale));
  @override
  bool shouldReload(_AppStringsDelegate old) => false;
}

extension LocalizedContext on BuildContext {
  String tr(String template, [List<Object?> arguments = const []]) => AppStrings.of(this).text(template, arguments);
  String trRendered(String value) => AppStrings.of(this).rendered(value);
}
