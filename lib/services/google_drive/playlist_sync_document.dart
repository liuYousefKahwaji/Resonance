import 'dart:convert';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/track_source_repository.dart';

/// Logical clocks do not depend on device wall clocks. The device suffix breaks
/// concurrent ties consistently on both platforms.
class SyncStamp implements Comparable<SyncStamp> {
  const SyncStamp(this.clock, this.device);
  final int clock;
  final String device;
  @override
  int compareTo(SyncStamp other) =>
      clock == other.clock ? device.compareTo(other.device) : clock.compareTo(other.clock);
  List<dynamic> toJson() => [clock, device];
  factory SyncStamp.fromJson(dynamic value) {
    if (value is! List ||
        value.length != 2 ||
        value[0] is! int ||
        value[0] < 0 ||
        value[0] > 9007199254740000 ||
        value[1] is! String ||
        (value[1] as String).isEmpty ||
        (value[1] as String).length > 128) {
      throw const FormatException('Invalid sync clock.');
    }
    return SyncStamp(value[0] as int, value[1] as String);
  }
}

class SyncEntry {
  const SyncEntry({
    required this.id,
    required this.videoId,
    required this.position,
    required this.stamp,
    this.removed = false,
  });
  final String id, videoId;
  final int position;
  final SyncStamp stamp;
  final bool removed;
  Map<String, dynamic> toJson() => {
    'id': id,
    'videoId': videoId,
    'position': position,
    'stamp': stamp.toJson(),
    'removed': removed,
  };
  factory SyncEntry.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        (json['id'] as String).length > 200 ||
        json['videoId'] is! String ||
        !TrackSourceRepository.isValidYoutubeVideoId(json['videoId'] as String) ||
        json['position'] is! int ||
        (json['position'] as int).abs() > 1000000 ||
        json['removed'] is! bool) {
      throw const FormatException('Invalid sync entry.');
    }
    return SyncEntry(
      id: json['id'] as String,
      videoId: json['videoId'] as String,
      position: json['position'] as int,
      stamp: SyncStamp.fromJson(json['stamp']),
      removed: json['removed'] as bool,
    );
  }
}

/// Each occurrence has its own identity: duplicates are intentional. Deletion
/// tombstones always win over an offline move; adding again creates a new ID.
/// Positions are per-entry LWW registers, so concurrent additions cannot replace
/// one another. Equal positions use stable IDs, never arrival order.
class PlaylistSyncDocument {
  PlaylistSyncDocument({
    required this.id,
    required this.name,
    required this.nameStamp,
    required Map<String, SyncEntry> entries,
  }) : entries = Map.unmodifiable(entries);
  final String id, name;
  final SyncStamp nameStamp;
  final Map<String, SyncEntry> entries;
  static const maxEntries = 30000; // Includes retained deletion markers.

  List<SyncEntry> get active {
    final result = entries.values.where((entry) => !entry.removed).toList();
    result.sort((a, b) => a.position == b.position ? a.id.compareTo(b.id) : a.position.compareTo(b.position));
    return result;
  }

  int get clock =>
      entries.values.fold(nameStamp.clock, (value, entry) => value > entry.stamp.clock ? value : entry.stamp.clock);
  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'name': name,
    'nameStamp': nameStamp.toJson(),
    'entries': [for (final key in (entries.keys.toList()..sort())) entries[key]!.toJson()],
  };
  String get fingerprint => jsonEncode(toJson());
  factory PlaylistSyncDocument.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    if (json['version'] != 1 ||
        json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        (json['id'] as String).length > 200 ||
        json['name'] is! String ||
        (json['name'] as String).trim().isEmpty ||
        (json['name'] as String).length > 200 ||
        (json['name'] as String).contains('\u0000') ||
        raw is! List ||
        raw.length > maxEntries) {
      throw const FormatException('Invalid synced playlist.');
    }
    final entries = <String, SyncEntry>{};
    for (final value in raw) {
      final entry = SyncEntry.fromJson(Map<String, dynamic>.from(value as Map));
      if (entries.containsKey(entry.id)) throw const FormatException('Duplicate sync identity.');
      entries[entry.id] = entry;
    }
    final document = PlaylistSyncDocument(
      id: json['id'] as String,
      name: json['name'] as String,
      nameStamp: SyncStamp.fromJson(json['nameStamp']),
      entries: entries,
    );
    if (document.active.length > PlaylistTransferCodec.maxPlaylistEntries) {
      throw const FormatException('Too many synced tracks.');
    }
    return document;
  }

  factory PlaylistSyncDocument.seed(String fileId, PlaylistTransferManifest manifest) => PlaylistSyncDocument(
    id: fileId,
    name: manifest.playlistName,
    nameStamp: const SyncStamp(0, 'seed'),
    entries: {
      for (var i = 0; i < manifest.youtubeVideoIds.length; i++)
        'seed:$i': SyncEntry(
          id: 'seed:$i',
          videoId: manifest.youtubeVideoIds[i],
          position: i,
          stamp: const SyncStamp(0, 'seed'),
        ),
    },
  );

  PlaylistSyncDocument merge(PlaylistSyncDocument other) {
    if (id != other.id) throw const FormatException('This playlist was replaced.');
    final merged = {...entries};
    for (final entry in other.entries.values) {
      final old = merged[entry.id];
      if (old != null && old.videoId != entry.videoId) throw const FormatException('A sync identity changed.');
      if (old == null ||
          (!old.removed && entry.removed) ||
          (old.removed == entry.removed && entry.stamp.compareTo(old.stamp) > 0)) {
        merged[entry.id] = entry;
      }
    }
    final useOtherName = other.nameStamp.compareTo(nameStamp) > 0;
    return PlaylistSyncDocument.fromJson(
      PlaylistSyncDocument(
        id: id,
        name: useOtherName ? other.name : name,
        nameStamp: useOtherName ? other.nameStamp : nameStamp,
        entries: merged,
      ).toJson(),
    );
  }

  PlaylistSyncDocument edit({
    required String device,
    required List<({String? entryId, String videoId})> tracks,
    String? renamed,
    Set<String>? observedIds,
  }) {
    final stamp = SyncStamp(clock + 1, device);
    final updated = {...entries};
    final liveIds = <String>{};
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      final key = track.entryId ?? '$device:${stamp.clock}:$i';
      liveIds.add(key);
      final old = entries[key];
      if (old != null && old.videoId != track.videoId) throw const FormatException('A sync identity changed.');
      // A stale device must not resurrect an entry deleted on another device.
      if (old?.removed == true) continue;
      if (old == null || old.position != i) {
        updated[key] = SyncEntry(id: key, videoId: track.videoId, position: i, stamp: stamp);
      }
    }
    for (final old in entries.values.where(
      (entry) =>
          !entry.removed && !liveIds.contains(entry.id) && (observedIds == null || observedIds.contains(entry.id)),
    )) {
      updated[old.id] = SyncEntry(
        id: old.id,
        videoId: old.videoId,
        position: old.position,
        stamp: stamp,
        removed: true,
      );
    }
    return PlaylistSyncDocument.fromJson(
      PlaylistSyncDocument(
        id: id,
        name: renamed ?? name,
        nameStamp: renamed == null || renamed == name ? nameStamp : stamp,
        entries: updated,
      ).toJson(),
    );
  }

  PlaylistTransferManifest manifest({Map<String, PlaylistTransferTrackMetadata> metadata = const {}}) {
    final ids = active.map((entry) => entry.videoId).toList();
    final wanted = ids.toSet();
    return PlaylistTransferManifest(
      playlistName: name,
      youtubeVideoIds: ids,
      trackMetadata: {
        for (final entry in metadata.entries)
          if (wanted.contains(entry.key)) entry.key: entry.value,
      },
    );
  }
}
