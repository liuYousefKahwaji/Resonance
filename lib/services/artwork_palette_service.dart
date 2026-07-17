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
  final Color primary;
  final Color secondary;

  const ArtworkPalette({required this.primary, required this.secondary});
}

/// Extracts a restrained pair of artwork colors and keeps a small persistent
/// cache so changing back to a recently played track is effectively free.
class ArtworkPaletteService {
  static const _cacheKey = 'artwork_palette_cache_v1';
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
        final colors = entry.value;
        if (colors is List && colors.length == 2 && colors[0] is int && colors[1] is int) {
          _memoryCache[entry.key] = ArtworkPalette(
            primary: Color(colors[0] as int),
            secondary: Color(colors[1] as int),
          );
        }
      }
    } catch (error) {
      debugPrint('Ignoring invalid artwork palette cache: $error');
    }
  }

  Future<void> _saveDiskCache() async {
    try {
      final entries = _memoryCache.entries.where((entry) => entry.value != null).toList();
      final trimmed = entries.length <= _maxCacheEntries ? entries : entries.sublist(entries.length - _maxCacheEntries);
      final encoded = <String, List<int>>{
        for (final entry in trimmed) entry.key: [entry.value!.primary.toARGB32(), entry.value!.secondary.toARGB32()],
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
  final step = math.max(1, math.min(image.width, image.height) ~/ 44);

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
      if (hsl.saturation < 0.18 || hsl.lightness < 0.10 || hsl.lightness > 0.90) continue;
      final bucketIndex = ((hsl.hue / 360) * bucketCount).floor() % bucketCount;
      final centerBias = 1 - ((x / image.width - 0.5).abs() + (y / image.height - 0.5).abs()) * 0.16;
      final weight = (0.25 + hsl.saturation * 0.75) * centerBias.clamp(0.72, 1.0);
      buckets[bucketIndex].add(color, weight);
    }
  }

  final ranked = List.generate(bucketCount, (index) => index)
    ..sort((a, b) => buckets[b].weight.compareTo(buckets[a].weight));
  if (buckets[ranked.first].weight <= 0) return null;

  final primaryIndex = ranked.first;
  final secondaryIndex = ranked.firstWhere((index) {
    if (buckets[index].weight <= 0) return false;
    final distance = (index - primaryIndex).abs();
    final wrappedDistance = math.min(distance, bucketCount - distance);
    return wrappedDistance >= 3;
  }, orElse: () => primaryIndex);

  final primary = _safeAccent(buckets[primaryIndex].average);
  final secondary = secondaryIndex == primaryIndex
      ? _safeAccent(HSLColor.fromColor(primary).withHue((HSLColor.fromColor(primary).hue + 38) % 360).toColor())
      : _safeAccent(buckets[secondaryIndex].average);
  return ArtworkPalette(primary: primary, secondary: secondary);
}

Color _safeAccent(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withSaturation(hsl.saturation.clamp(0.42, 0.88)).withLightness(hsl.lightness.clamp(0.34, 0.66)).toColor();
}
