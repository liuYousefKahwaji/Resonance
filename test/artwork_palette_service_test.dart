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
    for (final color in palette.colors) {
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

  test('keeps extracted chromatic colors faithful for gradients', () {
    final image = img.Image(width: 12, height: 12);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 18, 92, 36, 255);
      }
    }

    final color = extractArtworkPalette(image)!.primary!;

    expect(color.r, closeTo(18 / 255, 0.01));
    expect(color.g, closeTo(92 / 255, 0.01));
    expect(color.b, closeTo(36 / 255, 0.01));
  });

  test('keeps dominant black as a neutral without replacing the accurate chromatic accent', () {
    final image = img.Image(width: 20, height: 20);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        if (x < 16) {
          image.setPixelRgba(x, y, 3, 4, 6, 255);
        } else {
          image.setPixelRgba(x, y, 210, 40, 70, 255);
        }
      }
    }

    final palette = extractArtworkPalette(image);

    expect(palette, isNotNull);
    expect(palette!.colors, hasLength(1));
    expect(HSLColor.fromColor(palette.primary!).saturation, greaterThan(0.4));
    expect(HSLColor.fromColor(palette.darkNeutral!).lightness, lessThanOrEqualTo(0.12));
  });

  test('extracts up to three distinct cover colors plus black and white neutrals', () {
    final image = img.Image(width: 50, height: 20);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        if (x < 10) {
          image.setPixelRgba(x, y, 210, 35, 65, 255);
        } else if (x < 20) {
          image.setPixelRgba(x, y, 30, 100, 220, 255);
        } else if (x < 30) {
          image.setPixelRgba(x, y, 25, 175, 95, 255);
        } else if (x < 40) {
          image.setPixelRgba(x, y, 3, 3, 4, 255);
        } else {
          image.setPixelRgba(x, y, 248, 248, 246, 255);
        }
      }
    }

    final palette = extractArtworkPalette(image);

    expect(palette, isNotNull);
    expect(palette!.colors, hasLength(3));
    expect(palette.primaryColors, palette.colors.take(2));
    expect(palette.secondaryGradientColor, palette.colors[2]);
    expect(palette.darkNeutral, isNotNull);
    expect(palette.lightNeutral, isNotNull);
  });
}
