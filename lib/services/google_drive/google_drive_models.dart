import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'playlist_sync_document.dart';

class GoogleDriveException implements Exception {
  const GoogleDriveException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class GoogleDriveCancelled extends GoogleDriveException {
  const GoogleDriveCancelled() : super('Google Drive operation cancelled.');
}

class GoogleDriveAccount {
  const GoogleDriveAccount({required this.id, required this.name, this.photoUrl});
  final String id;
  final String name;
  final String? photoUrl;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'photoUrl': photoUrl};

  factory GoogleDriveAccount.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      throw const FormatException('Invalid saved Google account.');
    }
    final photo = json['photoUrl'];
    final uri = photo is String ? Uri.tryParse(photo) : null;
    return GoogleDriveAccount(id: id, name: name, photoUrl: uri?.scheme == 'https' ? photo as String : null);
  }
}

class DrivePlaylist {
  const DrivePlaylist({required this.id, required this.name, this.modifiedAt, this.trackCount, this.bytes});
  final String id;
  final String name;
  final DateTime? modifiedAt;
  final int? trackCount;
  final int? bytes;
  static const suffix = '.resonance-playlist.json';

  factory DrivePlaylist.fromJson(Map<String, dynamic> json) {
    final filename = json['name'] as String;
    final properties = json['appProperties'];
    final count = properties is Map ? int.tryParse('${properties['trackCount']}') : null;
    return DrivePlaylist(
      id: json['id'] as String,
      name: filename.endsWith(suffix) ? filename.substring(0, filename.length - suffix.length) : filename,
      modifiedAt: DateTime.tryParse('${json['modifiedTime']}'),
      trackCount: count != null && count >= 0 && count <= PlaylistTransferCodec.maxPlaylistEntries ? count : null,
      bytes: int.tryParse('${json['size']}'),
    );
  }
}

/// The cloud stores the same ordered YouTube identities as QR transfer, never
/// local paths, cookies, media URLs or audio. Duplicates remain significant.
class DrivePlaylistCodec {
  static const format = 'resonance-drive-playlist';
  static const maxBytes = PlaylistTransferCodec.maxDecompressedPayloadBytes;

  static List<int> encode(PlaylistTransferManifest manifest, {PlaylistSyncDocument? sync}) {
    PlaylistTransferCodec.validateManifest(manifest, allowEmpty: sync != null);
    if (sync != null &&
        (sync.name != manifest.playlistName ||
            jsonEncode(sync.active.map((entry) => entry.videoId).toList()) != jsonEncode(manifest.youtubeVideoIds))) {
      throw const GoogleDriveException('The synced playlist does not match its track list.');
    }
    final bytes = utf8.encode(
      jsonEncode({
        'format': format,
        'version': 1,
        // Keep the original identity checksum readable by the first Drive
        // release. Optional names live beside it, with their own checksum.
        'manifest': manifest.toJson(includeMetadata: false),
        'sha256': sha256.convert(utf8.encode(jsonEncode(manifest.toJson(includeMetadata: false)))).toString(),
        if (sync != null) ...{
          'sync': sync.toJson(),
          'syncSha256': sha256.convert(utf8.encode(jsonEncode(sync.toJson()))).toString(),
        },
        if (manifest.trackMetadata.isNotEmpty) ...{
          'trackMetadata': manifest.toJson()['trackMetadata'],
          'metadataSha256': sha256.convert(utf8.encode(jsonEncode(manifest.toJson()['trackMetadata']))).toString(),
        },
      }),
    );
    if (bytes.length > maxBytes) {
      throw const GoogleDriveException('This playlist is too large to save to Google Drive.');
    }
    return bytes;
  }

  static PlaylistTransferManifest decode(List<int> bytes) {
    if (bytes.length > maxBytes) throw const GoogleDriveException('This Google Drive playlist is too large to open.');
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map || json['format'] != format || json['version'] != 1) {
        throw const GoogleDriveException('This is not a supported Resonance playlist.');
      }
      final data = json['manifest'];
      if (data is! Map<String, dynamic> ||
          data['playlistName'] is! String ||
          data['youtubeVideoIds'] is! List ||
          (data['youtubeVideoIds'] as List).any((id) => id is! String)) {
        throw const FormatException();
      }
      if (json['trackMetadata'] != null &&
          sha256.convert(utf8.encode(jsonEncode(json['trackMetadata']))).toString() != json['metadataSha256']) {
        throw const GoogleDriveException('This Google Drive playlist is damaged or incomplete.');
      }
      final manifest = PlaylistTransferManifest.fromJson({
        ...data,
        if (json['trackMetadata'] != null) 'trackMetadata': json['trackMetadata'],
      });
      final sync = decodeSync(bytes);
      PlaylistTransferCodec.validateManifest(manifest, allowEmpty: sync != null);
      if (sync != null &&
          (sync.name != manifest.playlistName ||
              jsonEncode(sync.active.map((entry) => entry.videoId).toList()) != jsonEncode(manifest.youtubeVideoIds))) {
        throw const FormatException('Inconsistent synced playlist.');
      }
      final digest = sha256.convert(utf8.encode(jsonEncode(manifest.toJson(includeMetadata: false)))).toString();
      if (digest != json['sha256']) {
        throw const GoogleDriveException('This Google Drive playlist is damaged or incomplete.');
      }
      return manifest;
    } on FormatException {
      throw const GoogleDriveException('This Google Drive playlist could not be read.');
    }
  }

  static PlaylistSyncDocument? decodeSync(List<int> bytes) {
    if (bytes.length > maxBytes) throw const GoogleDriveException('This Google Drive playlist is too large to open.');
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map;
      if (json['sync'] == null) return null;
      if (sha256.convert(utf8.encode(jsonEncode(json['sync']))).toString() != json['syncSha256']) {
        throw const FormatException('Invalid sync checksum.');
      }
      return PlaylistSyncDocument.fromJson(Map<String, dynamic>.from(json['sync'] as Map));
    } catch (_) {
      throw const GoogleDriveException('This Google Drive playlist is damaged or incomplete.');
    }
  }
}

class DriveSyncSnapshot {
  const DriveSyncSnapshot({required this.manifest, required this.etag, this.document});
  final PlaylistTransferManifest manifest;
  final String etag;
  final PlaylistSyncDocument? document;
}
