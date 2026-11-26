import 'package:flutter/material.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/l10n/app_strings.dart';

/// These finished word graphics use Pricedown Black. Localized and runtime
/// text uses the regular interface font.
class ViceCityTitle extends StatelessWidget {
  const ViceCityTitle(this.title, {super.key, this.style});

  final String title;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = context.tr(title);
    if (theme.extension<ViceCityTheme>() == null || Localizations.localeOf(context).languageCode != 'en') {
      return Text(text, style: style);
    }
    return Image.asset(
      'assets/themes/vice_city/title-${title.toLowerCase()}.png',
      height: MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 18),
      fit: BoxFit.contain,
      alignment: AlignmentDirectional.centerStart,
      color: theme.colorScheme.onSurface,
      semanticLabel: text,
      filterQuality: FilterQuality.medium,
    );
  }
}
