import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class ArtworkPalette {
  final List<Color> colors;
  final Color? darkNeutral;
  final Color? lightNeutral;

  ArtworkPalette({required List<Color> colors, this.darkNeutral, this.lightNeutral})
    : assert(colors.length <= 3),
      colors = List<Color>.unmodifiable(colors);

  Color? get primary => colors.isEmpty ? null : colors.first;
  Color? get secondary => colors.length > 1 ? colors[1] : primary;
  Color? get tertiary => colors.length > 2 ? colors[2] : null;
  List<Color> get primaryColors => colors.take(2).toList(growable: false);
  Color? get secondaryGradientColor => tertiary;
}

/// Extracts a restrained artwork palette and keeps a small persistent
/// cache so changing back to a recently played track is effectively free.
class ArtworkPaletteService {
  static const _cacheKey = 'artwork_palette_cache_v3';
  static const _maxCacheEntries = 80;

  final Map<String, ArtworkPalette?> _memoryCache = {};
  bool _diskCacheLoaded = false;

  Future<ArtworkPalette?> paletteFor(Uri? artworkUri) async {
    if (artworkUri == null) return null;
    final key = artworkUri.toString();
    await _loadDiskCache();
    if (_memoryCache.containsKey(key)) return _memoryCache[key];

    ArtworkPalette? palette;
    try {
      final bytes = await _readArtwork(artworkUri);
      final decoded = bytes == null ? null : img.decodeImage(bytes);
      if (decoded != null) palette = extractArtworkPalette(decoded);
    } catch (error, stackTrace) {
      debugPrint('Artwork palette extraction failed for $artworkUri: $error\n$stackTrace');
    }

    _memoryCache[key] = palette;
    unawaited(_saveDiskCache());
    return palette;
  }

  Future<void> _loadDiskCache() async {
    if (_diskCacheLoaded) return;
    _diskCacheLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      for (final entry in decoded.entries) {
        final palette = entry.value;
        if (palette is! Map) continue;
        final encodedColors = palette['colors'];
        if (encodedColors is! List || encodedColors.length > 3 || encodedColors.any((value) => value is! int)) continue;
        final dark = palette['dark'];
        final light = palette['light'];
        _memoryCache[entry.key] = ArtworkPalette(
          colors: encodedColors.cast<int>().map(Color.new).toList(growable: false),
          darkNeutral: dark is int ? Color(dark) : null,
          lightNeutral: light is int ? Color(light) : null,
        );
      }
    } catch (error) {
      debugPrint('Ignoring invalid artwork palette cache: $error');
    }
  }

  Future<void> _saveDiskCache() async {
    try {
      final entries = _memoryCache.entries.where((entry) => entry.value != null).toList();
      final trimmed = entries.length <= _maxCacheEntries ? entries : entries.sublist(entries.length - _maxCacheEntries);
      final encoded = <String, Map<String, Object?>>{
        for (final entry in trimmed)
          entry.key: {
            'colors': entry.value!.colors.map((color) => color.toARGB32()).toList(growable: false),
            'dark': entry.value!.darkNeutral?.toARGB32(),
            'light': entry.value!.lightNeutral?.toARGB32(),
          },
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(encoded));
    } catch (error) {
      debugPrint('Could not save artwork palette cache: $error');
    }
  }

  Future<Uint8List?> _readArtwork(Uri uri) async {
    if (uri.scheme == 'file') {
      final file = File.fromUri(uri);
      if (!await file.exists()) return null;
      return file.readAsBytes();
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 6));
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final builder = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        length += chunk.length;
        if (length > 12 * 1024 * 1024) return null;
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}

class _ColorBucket {
  double weight = 0;
  double red = 0;
  double green = 0;
  double blue = 0;

  void add(Color color, double sampleWeight) {
    weight += sampleWeight;
    red += color.r * sampleWeight;
    green += color.g * sampleWeight;
    blue += color.b * sampleWeight;
  }

  Color get average => Color.from(
    alpha: 1,
    red: (red / weight).clamp(0, 1),
    green: (green / weight).clamp(0, 1),
    blue: (blue / weight).clamp(0, 1),
  );
}

/// Pure extraction entry point used by regression tests and the service.
@visibleForTesting
ArtworkPalette? extractArtworkPalette(img.Image image) {
  if (image.width == 0 || image.height == 0) return null;
  const bucketCount = 24;
  final buckets = List.generate(bucketCount, (_) => _ColorBucket());
  final darkNeutral = _ColorBucket();
  final lightNeutral = _ColorBucket();
  final step = math.max(1, math.min(image.width, image.height) ~/ 44);
  var sampledWeight = 0.0;

  for (var y = 0; y < image.height; y += step) {
    for (var x = 0; x < image.width; x += step) {
      final pixel = image.getPixel(x, y);
      if (pixel.a < 160) continue;
      final color = Color.fromARGB(
        255,
        pixel.r.round().clamp(0, 255),
        pixel.g.round().clamp(0, 255),
        pixel.b.round().clamp(0, 255),
      );
      final hsl = HSLColor.fromColor(color);
      final centerBias = 1 - ((x / image.width - 0.5).abs() + (y / image.height - 0.5).abs()) * 0.16;
      final positionWeight = centerBias.clamp(0.72, 1.0);
      sampledWeight += positionWeight;
      // HSL saturation is unstable near black (tiny RGB differences can look
      // highly saturated), so darkness alone decides whether this sample is
      // a neutral gradient candidate.
      if (hsl.lightness <= 0.12) {
        darkNeutral.add(color, positionWeight);
        continue;
      }
      if (hsl.lightness >= 0.88 && hsl.saturation <= 0.24) {
        lightNeutral.add(color, positionWeight);
        continue;
      }
      if (hsl.saturation < 0.18 || hsl.lightness < 0.10 || hsl.lightness > 0.90) continue;
      final bucketIndex = ((hsl.hue / 360) * bucketCount).floor() % bucketCount;
      final weight = (0.25 + hsl.saturation * 0.75) * positionWeight;
      buckets[bucketIndex].add(color, weight);
    }
  }

  final ranked = List.generate(bucketCount, (index) => index)
    ..sort((a, b) => buckets[b].weight.compareTo(buckets[a].weight));
  final selectedBuckets = <int>[];
  for (final index in ranked) {
    if (buckets[index].weight <= 0) break;
    final distinct = selectedBuckets.every((selected) {
      final distance = (index - selected).abs();
      return math.min(distance, bucketCount - distance) >= 2;
    });
    if (distinct) selectedBuckets.add(index);
    if (selectedBuckets.length == 3) break;
  }

  final minimumNeutralWeight = sampledWeight * 0.045;
  final dark = darkNeutral.weight >= minimumNeutralWeight ? _safeDarkNeutral(darkNeutral.average) : null;
  final light = lightNeutral.weight >= minimumNeutralWeight ? _safeLightNeutral(lightNeutral.average) : null;
  if (selectedBuckets.isEmpty && dark == null && light == null) return null;
  return ArtworkPalette(
    // Keep the cover colors faithful here. ThemeProvider separately derives
    // contrast-safe control colors; gradients should use the artwork itself.
    colors: selectedBuckets.map((index) => buckets[index].average).toList(growable: false),
    darkNeutral: dark,
    lightNeutral: light,
  );
}

Color _safeDarkNeutral(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withSaturation(hsl.saturation.clamp(0.0, 0.18)).withLightness(hsl.lightness.clamp(0.0, 0.12)).toColor();
}

Color _safeLightNeutral(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withSaturation(hsl.saturation.clamp(0.0, 0.16)).withLightness(hsl.lightness.clamp(0.88, 1.0)).toColor();
}
