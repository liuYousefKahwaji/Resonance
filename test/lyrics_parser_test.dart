import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/lyrics.dart';
import 'package:resonance/services/lyrics_parser.dart';

void main() {
  test('parses line-synced LRC and estimates word timing', () {
    final document = LyricsParser.parseLrc('[00:01.00]Hello bright world\n[00:04.00]Second line', source: 'test');

    expect(document.timingQuality, LyricTimingQuality.line);
    expect(document.lines, hasLength(2));
    expect(document.lines.first.start, const Duration(seconds: 1));
    expect(document.lines.first.end, const Duration(seconds: 4));
    expect(document.lines.first.words.map((word) => word.text.trim()), ['Hello', 'bright', 'world']);
    expect(document.lines.first.words.first.start, const Duration(seconds: 1));
    expect(document.lines.first.words.last.end, const Duration(seconds: 4));
  });

  test('preserves native enhanced-LRC word timestamps', () {
    final document = LyricsParser.parseLrc('[00:10.00]<00:10.00>Hello <00:10.50>world', source: 'test');

    expect(document.timingQuality, LyricTimingQuality.word);
    expect(document.lines.single.text, 'Hello world');
    expect(document.lines.single.words.first.start, const Duration(seconds: 10));
    expect(document.lines.single.words.last.start, const Duration(milliseconds: 10500));
  });

  test('parses genuine TTML word and syllable timing', () {
    const ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body><div>
    <p begin="00:00:10.000" end="00:00:12.500">
      <span begin="00:00:10.000" end="00:00:10.400">Hel</span><span begin="00:00:10.400" end="00:00:10.800">lo </span><span begin="00:00:10.800" end="00:00:12.500">world</span>
    </p>
  </div></body>
</tt>
''';

    final document = LyricsParser.parseTtml(ttml, source: 'TTML test');

    expect(document.timingQuality, LyricTimingQuality.word);
    expect(document.lines.single.text, 'Hello world');
    expect(document.lines.single.words, hasLength(3));
    expect(document.lines.single.words[1].start, const Duration(milliseconds: 10400));
    expect(document.lines.single.words.last.end, const Duration(milliseconds: 12500));
  });

  test('ignores TTML translations when constructing the primary lyric line', () {
    const ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body><div>
    <p begin="1.2s" dur="2.0s"><span begin="1.2s" end="3.2s">Bonjour</span><span ttm:role="x-translation">Hello</span></p>
  </div></body>
</tt>
''';

    final document = LyricsParser.parseTtml(ttml, source: 'TTML test');

    expect(document.lines.single.text, 'Bonjour');
    expect(document.lines.single.start, const Duration(milliseconds: 1200));
    expect(document.lines.single.end, const Duration(milliseconds: 3200));
  });
}
