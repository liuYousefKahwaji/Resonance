import 'package:resonance/services/library_catalog.dart';

enum SmartField {
  title,
  artist,
  favorite,
  offline,
  stream,
  addedDays,
  durationSeconds,
  lastPlayedDays,
  playCount,
  playlist,
}

class SmartRule {
  const SmartRule(this.field, this.value, {this.negate = false});
  final SmartField field;
  final String value;
  final bool negate;
  Map<String, dynamic> toJson() => {'field': field.name, 'value': value, 'negate': negate};
  factory SmartRule.fromJson(Map<String, dynamic> json) => SmartRule(
    SmartField.values.byName(json['field'] as String),
    json['value'] as String,
    negate: json['negate'] == true,
  );
  bool matches(LibraryTrack track, Map<String, dynamic>? stats, DateTime now) {
    final count = int.tryParse(value) ?? 0;
    final last = DateTime.tryParse('${stats?['lastPlayed'] ?? ''}');
    final result = switch (field) {
      SmartField.title => track.title.toLowerCase().contains(value.toLowerCase()),
      SmartField.artist => track.artist.toLowerCase().contains(value.toLowerCase()),
      SmartField.favorite => track.favorite,
      SmartField.offline => track.available,
      SmartField.stream => track.stream,
      SmartField.addedDays => track.addedAt != null && track.addedAt!.isAfter(now.subtract(Duration(days: count))),
      SmartField.durationSeconds => (track.durationSeconds ?? -1) >= count,
      SmartField.lastPlayedDays => last != null && last.isBefore(now.subtract(Duration(days: count))),
      SmartField.playCount => (stats?['plays'] as num? ?? 0) >= count,
      SmartField.playlist => track.playlists.contains(count),
    };
    return negate ? !result : result;
  }
}

class SmartPlaylist {
  const SmartPlaylist({
    required this.id,
    required this.name,
    required this.rules,
    this.matchAny = false,
    this.sort = 'title',
    this.descending = false,
    this.limit,
    this.includeNeverPlayed = false,
    this.exclusions = const {},
  });
  final String id, name, sort;
  final List<SmartRule> rules;
  final bool matchAny, descending, includeNeverPlayed;
  final int? limit;
  final Set<String> exclusions;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'rules': rules.map((rule) => rule.toJson()).toList(),
    'matchAny': matchAny,
    'sort': sort,
    'descending': descending,
    'limit': limit,
    'includeNeverPlayed': includeNeverPlayed,
    'exclusions': exclusions.toList(),
  };
  factory SmartPlaylist.fromJson(Map<String, dynamic> json) => SmartPlaylist(
    id: json['id'] as String,
    name: json['name'] as String,
    rules: [for (final rule in json['rules'] as List) SmartRule.fromJson(Map<String, dynamic>.from(rule as Map))],
    matchAny: json['matchAny'] == true,
    sort: json['sort'] as String? ?? 'title',
    descending: json['descending'] == true,
    limit: (json['limit'] as num?)?.toInt(),
    includeNeverPlayed: json['includeNeverPlayed'] == true,
    exclusions: (json['exclusions'] as List? ?? []).cast<String>().toSet(),
  );
  List<LibraryTrack> evaluate(
    List<LibraryTrack> tracks,
    Map<String, Map<String, dynamic>> statistics, {
    DateTime? now,
  }) {
    final seen = <String>{};
    final result = tracks.where((track) {
      if (!seen.add(track.id) || exclusions.contains(track.id)) return false;
      bool matches(SmartRule rule) {
        if (rule.field == SmartField.lastPlayedDays &&
            !rule.negate &&
            includeNeverPlayed &&
            statistics[track.id]?['lastPlayed'] == null) {
          return true;
        }
        return rule.matches(track, statistics[track.id], now ?? DateTime.now());
      }

      return matchAny ? rules.any(matches) : rules.every(matches);
    }).toList();
    result.sort((a, b) {
      final compared = switch (sort) {
        'artist' => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
        'added' => (a.addedAt ?? DateTime(1970)).compareTo(b.addedAt ?? DateTime(1970)),
        'plays' => (statistics[a.id]?['plays'] as num? ?? 0).compareTo(statistics[b.id]?['plays'] as num? ?? 0),
        _ => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      };
      final stable = compared == 0 ? a.id.compareTo(b.id) : compared;
      return descending ? -stable : stable;
    });
    return limit == null ? result : result.take(limit!.clamp(1, 100000)).toList();
  }
}
