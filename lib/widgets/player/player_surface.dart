import 'package:flutter/material.dart';

Color playerSurfaceColor(BuildContext context) {
  final theme = Theme.of(context);
  final base = theme.brightness == Brightness.dark ? const Color(0xFF1C1C20) : const Color(0xFFF0F0F3);
  return Color.alphaBlend(theme.colorScheme.primary.withValues(alpha: .025), base);
}
