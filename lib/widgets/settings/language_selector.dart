import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/providers/language_provider.dart';

/// Language names stay in their own language so switching back is easy.
class LanguageSelector extends StatelessWidget {
  const LanguageSelector({super.key});

  @override
  Widget build(BuildContext context) => Consumer<LanguageProvider>(
    builder: (context, language, _) => DropdownButtonHideUnderline(
      child: DropdownButton<Locale>(
        key: const Key('app-language-setting'),
        value: language.locale,
        onChanged: (locale) {
          if (locale != null) unawaited(language.setLocale(locale));
        },
        items: const [
          DropdownMenuItem(value: Locale('en'), child: Text('English')),
          DropdownMenuItem(value: Locale('ar'), child: Text('العربية')),
        ],
      ),
    ),
  );
}
