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
          words: parsed.words.isEmpty ? estimateWords(parsed.text, current.start, nextStart) : parsed.words,
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
      final wordElements = paragraph.descendants
          .whereType<XmlElement>()
          .where(
            (element) =>
                element.name.local == 'span' &&
                _attribute(element, 'begin') != null &&
                !_isAlternateText(element, paragraph),
          )
          .toList(growable: false);
      final words = <LyricWord>[];
      for (var index = 0; index < wordElements.length; index++) {
        final element = wordElements[index];
        final start = _ttmlTime(_attribute(element, 'begin'));
        if (start == null) continue;
        final followingStart = index + 1 < wordElements.length
            ? _ttmlTime(_attribute(wordElements[index + 1], 'begin'))
            : null;
        final end = _ttmlEnd(element, start) ?? followingStart ?? lineEnd ?? start + const Duration(milliseconds: 600);
        final text = element.innerText;
        if (text.trim().isEmpty) continue;
        words.add(LyricWord(text: text, start: start, end: end < start ? start : end));
      }
      hasNativeWords |= words.isNotEmpty;
      final text = words.isNotEmpty ? words.map((word) => word.text).join().trim() : _primaryText(paragraph).trim();
      if (text.isEmpty) continue;
      staged.add((text: text, start: lineStart, end: lineEnd, words: words));
    }

    final lines = <LyricLine>[];
    for (var index = 0; index < staged.length; index++) {
      final current = staged[index];
      final inferredEnd =
          current.end ??
          (index + 1 < staged.length ? staged[index + 1].start : null) ??
          (current.start == null ? null : current.start! + const Duration(seconds: 5));
      final words = current.words.isNotEmpty
          ? current.words
          : current.start != null && inferredEnd != null
          ? estimateWords(current.text, current.start!, inferredEnd)
          : const <LyricWord>[];
      lines.add(LyricLine(text: current.text, start: current.start, end: inferredEnd, words: words));
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

  static List<LyricWord> estimateWords(String text, Duration start, Duration end) {
    final matches = RegExp(r'\S+\s*').allMatches(text).toList(growable: false);
    if (matches.isEmpty || end <= start) return const [];
    final weights = [for (final match in matches) (match.group(0)!.trim().runes.length + 1).clamp(2, 14)];
    final total = weights.fold<int>(0, (sum, weight) => sum + weight);
    var cursor = start.inMilliseconds;
    return [
      for (var index = 0; index < matches.length; index++)
        () {
          final wordStart = cursor;
          final wordEnd = index == matches.length - 1
              ? end.inMilliseconds
              : cursor + ((end.inMilliseconds - start.inMilliseconds) * weights[index] / total).round();
          cursor = wordEnd;
          return LyricWord(
            text: matches[index].group(0)!,
            start: Duration(milliseconds: wordStart),
            end: Duration(milliseconds: wordEnd),
          );
        }(),
    ];
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
