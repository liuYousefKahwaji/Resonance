import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/lyrics/lyrics_direction.dart';

void main() {
  test('Arabic and Hebrew lyrics use right-to-left layout after neutral prefixes', () {
    expect(lyricTextDirection('♪ ١٢٣ مرحبا يا عالم'), TextDirection.rtl);
    expect(lyricTextDirection('(2) שלום עולם'), TextDirection.rtl);
  });

  test('Latin lyrics and mixed lines follow the first strong script', () {
    expect(lyricTextDirection('Hello world'), TextDirection.ltr);
    expect(lyricTextDirection('١٢٣ Hello'), TextDirection.ltr);
    expect(lyricTextDirection('Love حب'), TextDirection.ltr);
    expect(lyricTextDirection('حب Love'), TextDirection.rtl);
  });
}
