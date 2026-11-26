import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';

class ViceCityIntroBackdrop extends StatelessWidget {
  const ViceCityIntroBackdrop({super.key, required this.clock});

  final Animation<double> clock;

  static bool isPortrait(BuildContext context) => MediaQuery.sizeOf(context).aspectRatio < .9;

  @override
  Widget build(BuildContext context) {
    final portrait = isPortrait(context);
    final photo = Image.asset(
      portrait ? 'assets/themes/vice_city/palms-tall.webp' : 'assets/themes/vice_city/palms-wide.webp',
      fit: BoxFit.cover,
      alignment: portrait ? Alignment.center : const Alignment(0, -.24),
      excludeFromSemantics: true,
    );
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF29133C)),
          if (MediaQuery.disableAnimationsOf(context))
            photo
          else
            AnimatedBuilder(
              animation: clock,
              child: photo,
              builder: (context, child) =>
                  Transform.scale(scale: 1.02 + .045 * Curves.easeOutCubic.transform(clock.value), child: child),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0x90362274), Color(0x33462368), Color(0x25E35C96), Color(0xD523112F)],
                stops: [0, .35, .63, 1],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.center,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xB21B0E30)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ViceCityIntroWordmark extends StatelessWidget {
  const ViceCityIntroWordmark({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    if (Localizations.localeOf(context).languageCode == 'ar') {
      return Text(
        context.tr('Resonance'),
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          color: const Color(0xFFFFD4B1),
          fontSize: width / 5.4,
          fontWeight: FontWeight.w900,
          decoration: TextDecoration.none,
          shadows: const [Shadow(color: Color(0xDF210B31), blurRadius: 12, offset: Offset(1, 3))],
        ),
      );
    }
    return Image.asset(
      'assets/themes/vice_city/resonance-wordmark.png',
      width: width,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
    );
  }
}
