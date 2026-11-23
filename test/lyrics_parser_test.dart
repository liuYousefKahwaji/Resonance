import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/lyrics.dart';
import 'package:resonance/services/lyrics_parser.dart';

void main() {
  test('keeps line-synced LRC at the precision provided by the source', () {
    final document = LyricsParser.parseLrc('[00:01.00]Hello bright world\n[00:04.00]Second line', source: 'test');

    expect(document.timingQuality, LyricTimingQuality.line);
    expect(document.lines, hasLength(2));
    expect(document.lines.first.start, const Duration(seconds: 1));
    expect(document.lines.first.end, const Duration(seconds: 4));
    expect(document.lines.first.words, isEmpty);
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

  test('preserves TTML spaces between timed spans without splitting syllables', () {
    const ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml">
  <body><div><p begin="1s" end="4s"><span begin="1s"><span begin="1s" end="1.2s">Hel</span><span begin="1.2s" end="2s">lo</span></span> <span begin="2s" end="4s">world</span></p></div></body>
</tt>
''';
    final line = LyricsParser.parseTtml(ttml, source: 'Better Lyrics').lines.single;
    expect(line.text, 'Hello world');
    expect(line.words.map((word) => word.text), ['Hel', 'lo ', 'world']);
    expect(line.words.last.start, const Duration(seconds: 2));
  });

  test('parses genuine QRC timings and keeps standalone spaces', () {
    final document = LyricsParser.parseQrc(
      '[ti:Sample]\n[1200,1400]First(1200,400) (1600,100)line(1700,900)',
      source: 'QQ Music',
    );
    expect(document.timingQuality, LyricTimingQuality.word);
    final line = document.lines.single;
    expect(line.text, 'First line');
    expect(line.end, const Duration(milliseconds: 2600));
    expect(line.words.map((word) => word.start.inMilliseconds), [1200, 1700]);
  });

  test('reads LRCLIB Lyricsfile words and derives missing line bounds', () {
    final document = LyricsParser.parseLyricsfile('''
lines:
  - text: Two words
    words:
      - {text: Two, start_ms: 1700, end_ms: 1900}
      - {text: words, start_ms: 1900, end_ms: 2500}
''', source: 'LRCLIB');
    expect(document.timingQuality, LyricTimingQuality.word);
    final line = document.lines.single;
    expect(line.text, 'Two words');
    expect(line.start!.inMilliseconds, 1700);
    expect(line.words.last.start.inMilliseconds, 1900);
    expect(line.end!.inMilliseconds, 2500);
  });

  test('LRCLIB start-only words use the next real timestamp or the line end', () {
    final document = LyricsParser.parseLyricsfile('''
lines:
  - text: Here we go
    start_ms: 1000
    end_ms: 2800
    words:
      - {text: "Here ", start_ms: 1000}
      - {text: "we ", start_ms: 1450}
      - {text: go, start_ms: 1900}
''', source: 'LRCLIB');
    expect(document.timingQuality, LyricTimingQuality.word);
    final words = document.lines.single.words;
    expect(words.map((word) => word.start.inMilliseconds), [1000, 1450, 1900]);
    expect(words.map((word) => word.end.inMilliseconds), [1450, 1900, 2800]);
  });
}
