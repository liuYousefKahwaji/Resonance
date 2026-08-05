enum LyricTimingQuality { word, line, plain }

class LrclibCandidate {
  final int id;
  final String trackName;
  final String artistName;
  final String albumName;
  final Duration duration;
  final bool instrumental;
  final bool hasSyncedLyrics;
  final bool hasPlainLyrics;

  const LrclibCandidate({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.duration,
    required this.instrumental,
    required this.hasSyncedLyrics,
    required this.hasPlainLyrics,
  });

  bool get hasLyrics => instrumental || hasSyncedLyrics || hasPlainLyrics;

  factory LrclibCandidate.fromJson(Map<String, dynamic> json) => LrclibCandidate(
    id: (json['id'] as num?)?.toInt() ?? 0,
    trackName: json['trackName']?.toString().trim() ?? '',
    artistName: json['artistName']?.toString().trim() ?? '',
    albumName: json['albumName']?.toString().trim() ?? '',
    duration: Duration(milliseconds: (((json['duration'] as num?)?.toDouble() ?? 0) * 1000).round()),
    instrumental: json['instrumental'] == true,
    hasSyncedLyrics: (json['syncedLyrics']?.toString().trim().isNotEmpty ?? false),
    hasPlainLyrics: (json['plainLyrics']?.toString().trim().isNotEmpty ?? false),
  );
}

class LyricWord {
  final String text;
  final Duration start;
  final Duration end;

  const LyricWord({required this.text, required this.start, required this.end});

  Map<String, dynamic> toJson() => {'text': text, 'startMs': start.inMilliseconds, 'endMs': end.inMilliseconds};

  factory LyricWord.fromJson(Map<String, dynamic> json) => LyricWord(
    text: json['text']?.toString() ?? '',
    start: Duration(milliseconds: (json['startMs'] as num?)?.toInt() ?? 0),
    end: Duration(milliseconds: (json['endMs'] as num?)?.toInt() ?? 0),
  );
}

class LyricLine {
  final String text;
  final Duration? start;
  final Duration? end;
  final List<LyricWord> words;

  const LyricLine({required this.text, this.start, this.end, this.words = const []});

  Map<String, dynamic> toJson() => {
    'text': text,
    if (start != null) 'startMs': start!.inMilliseconds,
    if (end != null) 'endMs': end!.inMilliseconds,
    if (words.isNotEmpty) 'words': words.map((word) => word.toJson()).toList(),
  };

  factory LyricLine.fromJson(Map<String, dynamic> json) => LyricLine(
    text: json['text']?.toString() ?? '',
    start: json['startMs'] is num ? Duration(milliseconds: (json['startMs'] as num).toInt()) : null,
    end: json['endMs'] is num ? Duration(milliseconds: (json['endMs'] as num).toInt()) : null,
    words: (json['words'] as List? ?? const [])
        .whereType<Map>()
        .map((word) => LyricWord.fromJson(Map<String, dynamic>.from(word)))
        .toList(growable: false),
  );
}

class LyricsDocument {
  final List<LyricLine> lines;
  final LyricTimingQuality timingQuality;
  final String source;
  final bool instrumental;

  const LyricsDocument({
    required this.lines,
    required this.timingQuality,
    required this.source,
    this.instrumental = false,
  });

  bool get isEmpty => lines.every((line) => line.text.trim().isEmpty);

  Map<String, dynamic> toJson() => {
    'lines': lines.map((line) => line.toJson()).toList(),
    'timingQuality': timingQuality.name,
    'source': source,
    'instrumental': instrumental,
  };

  factory LyricsDocument.fromJson(Map<String, dynamic> json) => LyricsDocument(
    lines: (json['lines'] as List? ?? const [])
        .whereType<Map>()
        .map((line) => LyricLine.fromJson(Map<String, dynamic>.from(line)))
        .toList(growable: false),
    timingQuality: LyricTimingQuality.values.firstWhere(
      (quality) => quality.name == json['timingQuality'],
      orElse: () => LyricTimingQuality.plain,
    ),
    source: json['source']?.toString() ?? 'Unknown',
    instrumental: json['instrumental'] == true,
  );
}
