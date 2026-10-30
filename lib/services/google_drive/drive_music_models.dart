import 'package:path/path.dart' as p;

const driveAudioExtensions = ['mp3', 'wav', 'm4a', 'ogg', 'opus', 'webm', 'aac', 'flac'];
const driveFolderMime = 'application/vnd.google-apps.folder';
bool validDriveId(String id) => RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(id);

class DriveMusicRef {
  const DriveMusicRef(this.accountId, this.fileId);
  final String accountId, fileId;
  String get url => Uri.https('drive.google.com', '/file/d/$fileId/view', {'resonanceAccount': accountId}).toString();
  static DriveMusicRef? parse(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host != 'drive.google.com') return null;
    final parts = uri.pathSegments;
    final account = uri.queryParameters['resonanceAccount'];
    if (parts.length != 4 ||
        parts[0] != 'file' ||
        parts[1] != 'd' ||
        parts[3] != 'view' ||
        !validDriveId(parts[2]) ||
        account == null ||
        account.isEmpty ||
        account.length > 256) {
      return null;
    }
    return DriveMusicRef(account, parts[2]);
  }
}

class DriveMusicItem {
  const DriveMusicItem({
    required this.id,
    required this.name,
    required this.mimeType,
    this.parents = const [],
    this.bytes,
    this.modifiedAt,
    this.md5,
    this.canDownload = true,
  });
  final String id, name, mimeType;
  final List<String> parents;
  final int? bytes;
  final DateTime? modifiedAt;
  final String? md5;
  final bool canDownload;
  bool get isFolder => mimeType == driveFolderMime;
  bool get isAudio => !isFolder && driveAudioExtensions.contains(p.extension(name).replaceFirst('.', '').toLowerCase());
  String get title => p.basenameWithoutExtension(name);
  String streamUrl(String accountId) => DriveMusicRef(accountId, id).url;
  factory DriveMusicItem.fromJson(Map<String, dynamic> json) => DriveMusicItem(
    id: json['id'] as String,
    name: json['name'] as String,
    mimeType: json['mimeType'] as String? ?? '',
    parents: (json['parents'] as List? ?? []).whereType<String>().toList(),
    bytes: int.tryParse('${json['size']}'),
    modifiedAt: DateTime.tryParse('${json['modifiedTime']}'),
    md5: json['md5Checksum'] as String?,
    canDownload: (json['capabilities'] as Map?)?['canDownload'] != false,
  );
}

class DriveMusicPage {
  const DriveMusicPage(this.items, {this.nextPageToken});
  final List<DriveMusicItem> items;
  final String? nextPageToken;
}

enum DriveMusicTransferState { queued, running, complete, failed, cancelled }

class DriveMusicTransfer {
  DriveMusicTransfer({required this.id, required this.name, required this.upload});
  final int id;
  final String name;
  final bool upload;
  DriveMusicTransferState state = DriveMusicTransferState.queued;
  int transferred = 0;
  int? total;
  String? error, localPath;
  bool cancelled = false;
  double? get progress => total == null || total == 0 ? null : (transferred / total!).clamp(0, 1);
}
