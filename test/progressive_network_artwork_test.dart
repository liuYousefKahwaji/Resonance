import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/common/progressive_network_artwork.dart';

void main() {
  test('upgrades standard YouTube thumbnails to max resolution', () {
    expect(
      ProgressiveNetworkArtwork.highQualityUrlFor('https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg'),
      'https://i.ytimg.com/vi/jNQXAC9IVRw/maxresdefault.jpg',
    );
    expect(
      ProgressiveNetworkArtwork.highQualityUrlFor('https://i.ytimg.com/vi_webp/jNQXAC9IVRw/hqdefault.webp'),
      'https://i.ytimg.com/vi_webp/jNQXAC9IVRw/maxresdefault.webp',
    );
  });

  test('requests larger Google-hosted music artwork while preserving transforms', () {
    expect(
      ProgressiveNetworkArtwork.highQualityUrlFor('https://lh3.googleusercontent.com/example=w120-h120-l90-rj'),
      'https://lh3.googleusercontent.com/example=w1200-h1200-l90-rj',
    );
    expect(
      ProgressiveNetworkArtwork.highQualityUrlFor('https://yt3.ggpht.com/example=s88-c-k-c0x00ffffff-no-rj'),
      'https://yt3.ggpht.com/example=s1200-c-k-c0x00ffffff-no-rj',
    );
  });
}
