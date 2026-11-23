import 'package:yaml/yaml.dart';
import 'package:resonance/models/lyrics.dart';
import 'package:xml/xml.dart';

class LyricsParser {
  static final _lineTimestamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  static final _wordTimestamp = RegExp(r'<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>');

  const LyricsParser._();

  static LyricsDocument parseLrc(String input, {required String source}) {
    var offset = Duration.zero;
    final offsetMatch = RegExp(r'\[offset:([+-]?\d+)\]', caseSensitive: false).firstMatch(input);
    if (offsetMatch != null) offset = Duration(milliseconds: int.tryParse(offsetMatch.group(1)!) ?? 0);
    final staged = <({Duration start, String content})>[];
    for (final rawLine in input.replaceAll('\r\n', '\n').split('\n')) {
      final timestamps = _lineTimestamp.allMatches(rawLine).toList(growable: false);
      if (timestamps.isEmpty) continue;
      final content = rawLine.substring(timestamps.last.end).trim();
      for (final timestamp in timestamps) {
        staged.add((start: _duration(timestamp) + offset, content: content));
      }
    }
    staged.sort((first, second) => first.start.compareTo(second.start));
    final lines = <LyricLine>[];
    var hasNativeWords = false;
    for (var index = 0; index < staged.length; index++) {
      final current = staged[index];
      final nextStart = index + 1 < staged.length
          ? staged[index + 1].start
          : current.start + const Duration(seconds: 5);
      final parsed = _parseEnhancedWords(current.content, current.start, nextStart);
      hasNativeWords |= parsed.words.isNotEmpty;
      lines.add(
        LyricLine(
          text: parsed.text,
          start: current.start.isNegative ? Duration.zero : current.start,
          end: nextStart,
          words: parsed.words,
        ),
      );
    }
    return LyricsDocument(
      lines: lines,
      timingQuality: hasNativeWords ? LyricTimingQuality.word : LyricTimingQuality.line,
      source: source,
    );
  }

  static LyricsDocument parsePlain(String input, {required String source}) => LyricsDocument(
    lines: input
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) => LyricLine(text: line.trimRight()))
        .toList(growable: false),
    timingQuality: LyricTimingQuality.plain,
    source: source,
  );

  /// Parses TTML used by Better Lyrics, AMLL, and Apple Music-style lyric
  /// files. Timed spans are kept as the provider authored them, so a span can
  /// represent either a word or a syllable without Resonance guessing.
  static LyricsDocument parseTtml(String input, {required String source}) {
    final xml = XmlDocument.parse(input);
    final elements = xml.descendants.whereType<XmlElement>();
    final paragraphs = elements.where((element) => element.name.local == 'p').toList(growable: false);
    final staged = <({String text, Duration? start, Duration? end, List<LyricWord> words})>[];
    var hasNativeWords = false;

    for (final paragraph in paragraphs) {
      final lineStart = _ttmlTime(_attribute(paragraph, 'begin'));
      final lineEnd = _ttmlEnd(paragraph, lineStart);
      final segments = <({XmlElement element, String text})>[];
      final leading = StringBuffer();
      void visit(XmlNode node) {
        if (node is XmlText) {
          final value = node.value.replaceAll(RegExp(r'\s+'), ' ');
          if (segments.isEmpty) {
            leading.write(value);
          } else if (value.isNotEmpty) {
            final last = segments.removeLast();
            segments.add((element: last.element, text: last.text + value));
          }
          return;
        }
        if (node is! XmlElement || _isAlternateText(node, paragraph)) return;
        if (node.name.local == 'span' &&
            _ttmlTime(_attribute(node, 'begin')) != null &&
            !node.descendants.whereType<XmlElement>().any(
              (span) =>
                  span.name.local == 'span' &&
                  !_isAlternateText(span, paragraph) &&
                  _ttmlTime(_attribute(span, 'begin')) != null,
            )) {
          final text = _primaryText(node);
          if (text.trim().isNotEmpty) {
            segments.add((element: node, text: segments.isEmpty ? leading.toString().trimLeft() + text : text));
          }
          return;
        }
        for (final child in node.children) {
          visit(child);
        }
      }

      visit(paragraph);
      final words = <LyricWord>[];
      for (var index = 0; index < segments.length; index++) {
        final segment = segments[index];
        final start = _ttmlTime(_attribute(segment.element, 'begin'))!;
        final followingStart = index + 1 < segments.length
            ? _ttmlTime(_attribute(segments[index + 1].element, 'begin'))
            : null;
        final end = _ttmlEnd(segment.element, start) ?? followingStart ?? lineEnd ?? start;
        final text = segment.text;
        words.add(LyricWord(text: text, start: start, end: end < start ? start : end));
      }
      hasNativeWords |= words.isNotEmpty;
      final text = words.isNotEmpty ? words.map((word) => word.text).join().trim() : _primaryText(paragraph).trim();
      if (text.isEmpty) continue;
      staged.add((
        text: text,
        start: lineStart ?? (words.isEmpty ? null : words.first.start),
        end: lineEnd,
        words: words,
      ));
    }

    final lines = <LyricLine>[];
    for (var index = 0; index < staged.length; index++) {
      final current = staged[index];
      final inferredEnd =
          current.end ??
          (index + 1 < staged.length ? staged[index + 1].start : null) ??
          (current.start == null ? null : current.start! + const Duration(seconds: 5));
      lines.add(LyricLine(text: current.text, start: current.start, end: inferredEnd, words: current.words));
    }

    return LyricsDocument(
      lines: lines,
      timingQuality: hasNativeWords
          ? LyricTimingQuality.word
          : lines.any((line) => line.start != null)
          ? LyricTimingQuality.line
          : LyricTimingQuality.plain,
      source: source,
    );
  }

  static LyricsDocument parseQrc(String input, {required String source, String title = '', String artist = ''}) {
    final body = input.trimLeft().startsWith('<')
        ? XmlDocument.parse(input).descendants
                  .whereType<XmlElement>()
                  .map((element) => element.getAttribute('LyricContent'))
                  .nonNulls
                  .firstOrNull ??
              ''
        : input;
    final headers = RegExp(r'\[(\d+),(\d+)\]').allMatches(body).toList();
    final wordTime = RegExp(r'\((\d+),(\d+)\)');
    final credits = RegExp(
      r'^(?:lyrics by|composed by|arranged by|producer|作词|作曲|编曲|制作人)\s*[:：]',
      caseSensitive: false,
    );
    final lines = <LyricLine>[];
    for (var index = 0; index < headers.length; index++) {
      final header = headers[index];
      final start = int.parse(header.group(1)!);
      final duration = int.parse(header.group(2)!);
      final content = body.substring(header.end, index + 1 < headers.length ? headers[index + 1].start : body.length);
      var cursor = 0;
      final words = <LyricWord>[];
      for (final time in wordTime.allMatches(content)) {
        final text = content.substring(cursor, time.start);
        cursor = time.end;
        if (text.trim().isEmpty) {
          if (text.isNotEmpty && words.isNotEmpty && !words.last.text.endsWith(' ')) {
            final previous = words.removeLast();
            words.add(LyricWord(text: '${previous.text} ', start: previous.start, end: previous.end));
          }
          continue;
        }
        final wordStart = int.parse(time.group(1)!);
        final length = int.parse(time.group(2)!);
        words.add(
          LyricWord(
            text: text,
            start: Duration(milliseconds: wordStart),
            end: Duration(milliseconds: wordStart + length),
          ),
        );
      }
      final text = words.map((word) => word.text).join().trim();
      if (text.isEmpty || credits.hasMatch(text)) continue;
      final identity = text.toLowerCase();
      if (lines.isEmpty && [title, artist, '$title - $artist'].any((name) => identity == name.trim().toLowerCase())) {
        continue;
      }
      final lineEnd = duration > 0
          ? start + duration
          : index + 1 < headers.length
          ? int.parse(headers[index + 1].group(1)!)
          : words.last.end.inMilliseconds;
      lines.add(
        LyricLine(
          text: text,
          start: Duration(milliseconds: start),
          end: Duration(milliseconds: lineEnd),
          words: words,
        ),
      );
    }
    return LyricsDocument(lines: lines, timingQuality: LyricTimingQuality.word, source: source);
  }

  static LyricsDocument parseLyricsfile(String input, {required String source}) {
    final data = loadYaml(input);
    final rawLines = data is Map ? data['lines'] : null;
    final entries = rawLines is List ? rawLines.whereType<Map>().toList() : const <Map>[];
    final lines = <LyricLine>[];
    Duration? time(Object? value) => value is int && value >= 0 ? Duration(milliseconds: value) : null;
    final pending = entries
        .map((entry) {
          final rawWords = entry['words'];
          final words = <({String text, Duration start, Duration? end})>[];
          if (rawWords is List) {
            for (final word in rawWords.whereType<Map>()) {
              final start = time(word['start_ms']);
              final label = word['text'];
              if (label is String && label.trim().isNotEmpty && start != null) {
                words.add((text: label, start: start, end: time(word['end_ms'])));
              }
            }
          }
          return (
            text: entry['text'] is String ? entry['text'] as String : words.map((word) => word.text).join(),
            start: time(entry['start_ms']) ?? words.firstOrNull?.start,
            end: time(entry['end_ms']),
            words: words,
          );
        })
        .where((entry) => entry.text.trim().isNotEmpty)
        .toList();

    for (final (index, entry) in pending.indexed) {
      final lineEnd = entry.end ?? (index + 1 < pending.length ? pending[index + 1].start : null);
      final words = <LyricWord>[];
      for (final (wordIndex, word) in entry.words.indexed) {
        final next = wordIndex + 1 < entry.words.length ? entry.words[wordIndex + 1].start : lineEnd;
        final end = word.end ?? next ?? word.start;
        words.add(LyricWord(text: word.text, start: word.start, end: end < word.start ? word.start : end));
      }
      lines.add(LyricLine(text: entry.text, start: entry.start, end: lineEnd ?? words.lastOrNull?.end, words: words));
    }
    return LyricsDocument(
      lines: lines,
      source: source,
      timingQuality: lines.any((line) => line.words.isNotEmpty)
          ? LyricTimingQuality.word
          : lines.any((line) => line.start != null)
          ? LyricTimingQuality.line
          : LyricTimingQuality.plain,
    );
  }

  static ({String text, List<LyricWord> words}) _parseEnhancedWords(
    String content,
    Duration lineStart,
    Duration lineEnd,
  ) {
    final matches = _wordTimestamp.allMatches(content).toList(growable: false);
    if (matches.isEmpty) return (text: content, words: const []);
    final words = <LyricWord>[];
    final text = StringBuffer();
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final wordStart = _duration(match);
      final wordEnd = index + 1 < matches.length ? _duration(matches[index + 1]) : lineEnd;
      final segmentEnd = index + 1 < matches.length ? matches[index + 1].start : content.length;
      final wordText = content.substring(match.end, segmentEnd);
      text.write(wordText);
      if (wordText.trim().isNotEmpty) {
        words.add(LyricWord(text: wordText, start: wordStart, end: wordEnd));
      }
    }
    return (text: text.toString().trim(), words: words);
  }

  static Duration _duration(RegExpMatch match) {
    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    final fraction = match.group(3) ?? '0';
    final milliseconds = fraction.length == 1
        ? int.parse(fraction) * 100
        : fraction.length == 2
        ? int.parse(fraction) * 10
        : int.parse(fraction.substring(0, 3));
    return Duration(minutes: minutes, seconds: seconds, milliseconds: milliseconds);
  }

  static String? _attribute(XmlElement element, String localName) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == localName) return attribute.value;
    }
    return null;
  }

  static Duration? _ttmlEnd(XmlElement element, Duration? start) {
    final explicit = _ttmlTime(_attribute(element, 'end'));
    if (explicit != null) return explicit;
    final duration = _ttmlTime(_attribute(element, 'dur'));
    return duration == null || start == null ? null : start + duration;
  }

  static Duration? _ttmlTime(String? input) {
    final value = input?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.endsWith('ms')) {
      final milliseconds = double.tryParse(value.substring(0, value.length - 2));
      return milliseconds == null ? null : Duration(microseconds: (milliseconds * 1000).round());
    }
    if (value.endsWith('s')) {
      final seconds = double.tryParse(value.substring(0, value.length - 1));
      return seconds == null ? null : Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());
    }
    final parts = value.split(':');
    if (parts.isEmpty || parts.length > 3) return null;
    final seconds = double.tryParse(parts.last);
    if (seconds == null) return null;
    var totalSeconds = seconds;
    if (parts.length >= 2) totalSeconds += (int.tryParse(parts[parts.length - 2]) ?? 0) * 60;
    if (parts.length == 3) totalSeconds += (int.tryParse(parts.first) ?? 0) * 3600;
    return Duration(microseconds: (totalSeconds * Duration.microsecondsPerSecond).round());
  }

  static bool _isAlternateText(XmlElement element, XmlElement paragraph) {
    XmlNode? current = element;
    while (current != null && !identical(current, paragraph)) {
      if (current is XmlElement) {
        final role = _attribute(current, 'role')?.toLowerCase();
        if (role == 'x-translation' || role == 'x-roman') return true;
      }
      current = current.parent;
    }
    return false;
  }

  static String _primaryText(XmlElement paragraph) {
    final buffer = StringBuffer();

    void append(XmlNode node, {bool alternate = false}) {
      if (node is XmlText && !alternate) {
        buffer.write(node.value);
        return;
      }
      if (node is! XmlElement) return;
      final role = _attribute(node, 'role')?.toLowerCase();
      final isAlternate = alternate || role == 'x-translation' || role == 'x-roman';
      for (final child in node.children) {
        append(child, alternate: isAlternate);
      }
    }

    append(paragraph);
    return buffer.toString();
  }
}
