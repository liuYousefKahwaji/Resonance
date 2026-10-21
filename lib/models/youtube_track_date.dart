/// A date keeps its original precision: a year/relative label is never turned
/// into an invented day. Uploads and musical releases are distinct metadata.
class YoutubeTrackDate {
  const YoutubeTrackDate({
    this.value,
    this.year,
    this.relative,
    this.observedAt,
    this.hasTime = false,
    this.isRelease = false,
  });
  final DateTime? value;
  final int? year;
  final String? relative;
  final DateTime? observedAt;
  final bool hasTime, isRelease;

  static YoutubeTrackDate? parse(dynamic raw, {bool isRelease = false}) {
    final text = raw?.toString().trim() ?? '';
    final match = RegExp(r'^(\d{4})-?(\d{2})-?(\d{2})(?:T.*)?$').firstMatch(text);
    if (match != null) {
      final y = int.parse(match[1]!), m = int.parse(match[2]!), d = int.parse(match[3]!);
      final day = DateTime.utc(y, m, d);
      if (y < 1900 || y > 2200 || day.year != y || day.month != m || day.day != d) return null;
      final hasTime = text.contains('T');
      final value = hasTime ? DateTime.tryParse(text) : day;
      return value == null ? null : YoutubeTrackDate(value: value, hasTime: hasTime, isRelease: isRelease);
    }
    final year = int.tryParse(text);
    if (year != null && year >= 1900 && year <= 2200) return YoutubeTrackDate(year: year, isRelease: isRelease);
    final relative = RegExp(
      r'^(?:(?:Streamed|Premiered)\s+)?(today|yesterday|(?:a|an|\d+)\s+(?:second|minute|hour|day|week|month|year)s?\s+ago)$',
      caseSensitive: false,
    ).firstMatch(text);
    return relative == null
        ? null
        : YoutubeTrackDate(
            relative: relative[1]!.toLowerCase(),
            observedAt: DateTime.now().toUtc(),
            isRelease: isRelease,
          );
  }

  static YoutubeTrackDate? fromMetadata(Map<String, dynamic> json) {
    final release = parse(json['release_date'], isRelease: true);
    final upload = parse(json['upload_date'] ?? json['publishDate'] ?? json['uploadDate']);
    return fromJson(json['trackDate']) ??
        (release?.value != null ? release : null) ??
        (upload?.value != null ? upload : null) ??
        release ??
        upload ??
        parse(json['published_text']) ??
        parse(json['year'], isRelease: true);
  }

  Map<String, dynamic> toJson() => {
    if (value != null) 'value': value!.toIso8601String(),
    if (year != null) 'year': year,
    if (relative != null) 'relative': relative,
    if (observedAt != null) 'observedAt': observedAt!.toIso8601String(),
    'hasTime': hasTime,
    'isRelease': isRelease,
  };

  static YoutubeTrackDate? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final parsed = parse(raw['value'] ?? raw['year'] ?? raw['relative'], isRelease: raw['isRelease'] == true);
    if (parsed == null) return null;
    return YoutubeTrackDate(
      value: parsed.value,
      year: parsed.year,
      relative: parsed.relative,
      observedAt: DateTime.tryParse(raw['observedAt']?.toString() ?? '') ?? parsed.observedAt,
      hasTime: raw['hasTime'] == true && parsed.value != null,
      isRelease: parsed.isRelease,
    );
  }
}
