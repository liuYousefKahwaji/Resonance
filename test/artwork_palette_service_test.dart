import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:resonance/services/artwork_palette_service.dart';

void main() {
  test('extracts safe distinct accents from colorful artwork', () {
    final image = img.Image(width: 20, height: 20);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        if (x < 13) {
          image.setPixelRgba(x, y, 205, 45, 70, 255);
        } else {
          image.setPixelRgba(x, y, 35, 105, 220, 255);
        }
      }
    }

    final palette = extractArtworkPalette(image);

    expect(palette, isNotNull);
    expect(palette!.primary, isNot(palette.secondary));
    for (final color in [palette.primary, palette.secondary]) {
      final hsl = HSLColor.fromColor(color);
      expect(hsl.saturation, inInclusiveRange(0.42, 0.88));
      expect(hsl.lightness, inInclusiveRange(0.34, 0.66));
    }
  });

  test('falls back when artwork contains no useful chroma', () {
    final image = img.Image(width: 8, height: 8);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 120, 120, 120, 255);
      }
    }

    expect(extractArtworkPalette(image), isNull);
  });
}
