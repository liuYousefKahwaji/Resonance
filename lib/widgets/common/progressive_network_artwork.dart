import 'package:flutter/material.dart';

/// Shows the supplied thumbnail immediately, then fades in a larger YouTube
/// artwork variant only after that image has decoded successfully.
class ProgressiveNetworkArtwork extends StatelessWidget {
  const ProgressiveNetworkArtwork({
    super.key,
    required this.url,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.lowCacheSize = 160,
    this.highCacheSize = 1200,
    this.fadeDuration = const Duration(milliseconds: 280),
  });

  final String url;
  final Widget fallback;
  final BoxFit fit;
  final int lowCacheSize;
  final int highCacheSize;
  final Duration fadeDuration;

  @visibleForTesting
  static String highQualityUrlFor(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    final host = uri.host.toLowerCase();
    if (host.endsWith('ytimg.com') && RegExp(r'/vi(?:_webp)?/[A-Za-z0-9_-]{11}/').hasMatch(uri.path)) {
      final segments = [...uri.pathSegments];
      if (segments.isNotEmpty) {
        final extension = segments.last.toLowerCase().endsWith('.webp') ? 'webp' : 'jpg';
        segments[segments.length - 1] = 'maxresdefault.$extension';
        return uri.replace(pathSegments: segments).toString();
      }
    }
    var upgraded = value.replaceFirstMapped(
      RegExp(r'=w\d+-h\d+([^?]*)$'),
      (match) => '=w1200-h1200${match.group(1) ?? ''}',
    );
    if (upgraded != value) return upgraded;
    upgraded = value.replaceFirstMapped(RegExp(r'=s\d+([^?]*)$'), (match) => '=s1200${match.group(1) ?? ''}');
    return upgraded;
  }

  @override
  Widget build(BuildContext context) {
    final highQualityUrl = highQualityUrlFor(url);
    final low = Image.network(
      url,
      fit: fit,
      cacheWidth: lowCacheSize,
      cacheHeight: lowCacheSize,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => fallback,
    );
    if (highQualityUrl == url) return low;
    return Stack(
      fit: StackFit.expand,
      children: [
        low,
        Image.network(
          highQualityUrl,
          fit: fit,
          cacheWidth: highCacheSize,
          cacheHeight: highCacheSize,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) => AnimatedOpacity(
            opacity: wasSynchronouslyLoaded || frame != null ? 1 : 0,
            duration: fadeDuration,
            curve: Curves.easeOutCubic,
            child: child,
          ),
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ],
    );
  }
}
