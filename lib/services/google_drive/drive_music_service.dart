import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'drive_music_models.dart';
import 'google_drive_models.dart';
import 'google_drive_service.dart';

/// Audio files, independently of Resonance's metadata-only playlist sync.
/// No bearer token or temporary playback URL is written to the library.
class DriveMusicService extends ChangeNotifier {
  DriveMusicService({GoogleDriveService? drive, FileService? files, Future<Directory> Function()? downloadDirectory})
    : drive = drive ?? GoogleDriveService.instance,
      files = files ?? FileService(),
      _downloadDirectory = downloadDirectory ?? _defaultDownloadDirectory {
    _account = this.drive.account?.id;
    _revision = this.drive.sessionRevision;
    this.drive.addListener(_accountChanged);
  }
  static final instance = DriveMusicService();
  final GoogleDriveService drive;
  final FileService files;
  final Future<Directory> Function() _downloadDirectory;
  final List<DriveMusicTransfer> transfers = [];
  final Map<int, Future<Object?> Function()> _retryActions = {};
  Future<void> _queue = Future.value();
  String? _account, _uploadFolder;
  int _revision = 0, _sequence = 0;
  int libraryRevision = 0;
  final _progressClock = Stopwatch()..start();
  int _lastProgressMs = 0;
  bool _disposed = false;
  static const _fields = 'id,name,mimeType,parents,size,modifiedTime,md5Checksum,capabilities/canDownload';
  static const _chunkSize = 1024 * 1024;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _progress() {
    if (_progressClock.elapsedMilliseconds - _lastProgressMs < 100) return;
    _lastProgressMs = _progressClock.elapsedMilliseconds;
    _notify();
  }

  static Future<Directory> _defaultDownloadDirectory() async {
    final root = Platform.isAndroid ? await getExternalStorageDirectory() : await getApplicationDocumentsDirectory();
    return Directory(p.join((root ?? await getApplicationDocumentsDirectory()).path, 'Resonance', 'Drive music'));
  }

  void _accountChanged() {
    if (_account != drive.account?.id || _revision != drive.sessionRevision) {
      for (final job in transfers) {
        if (job.state == DriveMusicTransferState.running || job.state == DriveMusicTransferState.queued) {
          job.cancelled = true;
        }
      }
      transfers.clear();
      _retryActions.clear();
      _uploadFolder = null;
      _account = drive.account?.id;
      _revision = drive.sessionRevision;
    }
    _notify();
  }

  String _owner() => drive.account?.id ?? (throw const GoogleDriveException('Connect Google Drive to continue.'));
  void _check(String owner, [DriveMusicTransfer? job]) {
    if (_disposed || _owner() != owner || job?.cancelled == true) throw const GoogleDriveCancelled();
  }

  static String _escape(String value) => value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  static Uri _uri(String path, [Map<String, String>? query]) => Uri.https('www.googleapis.com', path, query);
  static void _id(String id) {
    if (!validDriveId(id)) throw const GoogleDriveException('Invalid Drive file.');
  }

  Future<Map<String, dynamic>> _json(String method, Uri uri, String owner, {Map<String, dynamic>? body}) async {
    final response = await drive.musicRequest(
      method,
      uri,
      accountId: owner,
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      bytes: body == null ? null : utf8.encode(jsonEncode(body)),
    );
    return _responseJson(response, owner);
  }

  Future<Map<String, dynamic>> _responseJson(http.StreamedResponse response, String owner) async {
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      _check(owner);
      if (bytes.length + chunk.length > 1024 * 1024) {
        throw const GoogleDriveException('The Google Drive response is too large.');
      }
      bytes.addAll(chunk);
    }
    _success(response.statusCode);
    return bytes.isEmpty ? {} : Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  }

  static void _success(int code) {
    if (code >= 200 && code < 300) return;
    throw GoogleDriveException(switch (code) {
      401 => 'Reconnect Google Drive to continue.',
      403 => 'Google Drive cannot access this audio. Check its download permissions and your available storage.',
      404 => 'This Drive file was moved, deleted, or is no longer available.',
      429 => 'Google Drive is busy. Wait a moment and try again.',
      _ => 'Could not transfer this Drive audio. Check your connection and try again.',
    }, statusCode: code);
  }

  static DriveMusicItem _item(Map<String, dynamic> json) {
    final item = DriveMusicItem.fromJson(json);
    _id(item.id);
    return item;
  }

  Future<DriveMusicItem> metadata(String id) async {
    _id(id);
    final owner = _owner();
    final value = await _json(
      'GET',
      _uri('/drive/v3/files/$id', {'fields': '$_fields,trashed', 'supportsAllDrives': 'true'}),
      owner,
    );
    if (value['trashed'] == true) {
      throw const GoogleDriveException('This Drive file was moved, deleted, or is no longer available.');
    }
    return _item(value);
  }

  /// Discovery scans audio metadata in pages. Folder names are hydrated only
  /// for discovered parents; no recursion through every unrelated Drive folder.
  Future<DriveMusicPage> discover({String? pageToken, String query = ''}) async {
    final audio = "(mimeType contains 'audio/' or mimeType = 'application/octet-stream' or mimeType = 'video/webm')";
    return _list(
      "trashed = false and $audio${query.trim().isEmpty ? '' : " and name contains '${_escape(query.trim())}'"}",
      pageToken,
    );
  }

  Future<DriveMusicPage> folder(String id, {String? pageToken, String query = ''}) async {
    _id(id);
    return _list(
      "trashed = false and '$id' in parents${query.trim().isEmpty ? '' : " and name contains '${_escape(query.trim())}'"}",
      pageToken,
    );
  }

  Future<DriveMusicPage> _list(String query, String? token) async {
    final owner = _owner();
    final response = await _json(
      'GET',
      _uri('/drive/v3/files', {
        'q': query,
        'fields': 'nextPageToken,files($_fields)',
        'pageSize': '200',
        'orderBy': 'folder,name',
        'supportsAllDrives': 'true',
        'includeItemsFromAllDrives': 'true',
        if (token != null) 'pageToken': token,
      }),
      owner,
    );
    final items = (response['files'] as List? ?? [])
        .whereType<Map>()
        .map((e) => _item(Map<String, dynamic>.from(e)))
        .where((e) => e.isFolder || e.isAudio)
        .toList();
    return DriveMusicPage(items, nextPageToken: response['nextPageToken'] as String?);
  }

  Future<ResolvedYoutubeStream> resolve(String url) async {
    final ref = DriveMusicRef.parse(url);
    if (ref == null) throw const GoogleDriveException('Invalid Drive file.');
    await drive.initialize();
    final headers = await drive.musicHeaders(ref.accountId);
    return ResolvedYoutubeStream(
      uri: _uri('/drive/v3/files/${ref.fileId}', {'alt': 'media'}),
      headers: headers,
      accessRevision: drive.sessionRevision,
    );
  }

  Future<void> cacheNames(Iterable<DriveMusicItem> items, {String artist = 'Google Drive'}) async {
    final owner = _owner();
    await MetadataCacheService.setStreams({
      for (final item in items)
        if (item.isAudio) item.streamUrl(owner): CachedTrackMetadata(title: item.title, artist: artist),
    });
  }

  Future<int> addStreams(List<DriveMusicItem> items, String name) async {
    final owner = _owner();
    final audio = items.where((e) => e.isAudio && e.canDownload).toList();
    if (audio.isEmpty) throw const GoogleDriveException('No playable audio was found in this folder.');
    await cacheNames(audio, artist: name);
    _check(owner);
    return (await files.createImportedPlaylist(name, audio.map((e) => e.streamUrl(owner)).toList())).number;
  }

  void cancel(DriveMusicTransfer job) {
    job.cancelled = true;
    if (job.state == DriveMusicTransferState.queued) job.state = DriveMusicTransferState.cancelled;
    _notify();
  }

  void clearFinished() {
    transfers.removeWhere(
      (e) => e.state != DriveMusicTransferState.queued && e.state != DriveMusicTransferState.running,
    );
    _retryActions.removeWhere((id, _) => !transfers.any((job) => job.id == id));
    _notify();
  }

  Future<Object?> retry(DriveMusicTransfer job) => _retryActions[job.id]?.call() ?? Future.value(null);
  Future<T> _enqueue<T>(DriveMusicTransfer job, Future<T> Function(String owner) operation) {
    final owner = _owner();
    final revision = drive.sessionRevision;
    transfers.add(job);
    _notify();
    final result = _queue.then((_) async {
      try {
        _check(owner, job);
        if (revision != drive.sessionRevision) throw const GoogleDriveCancelled();
        job.state = DriveMusicTransferState.running;
        _notify();
        final value = await operation(owner);
        _check(owner, job);
        job.state = DriveMusicTransferState.complete;
        if (job.upload) libraryRevision++;
        return value;
      } catch (error) {
        job.state = error is GoogleDriveCancelled || job.cancelled
            ? DriveMusicTransferState.cancelled
            : DriveMusicTransferState.failed;
        job.error = error is GoogleDriveException
            ? error.message
            : 'Could not transfer this Drive audio. Check your connection and try again.';
        rethrow;
      } finally {
        _notify();
      }
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<String> download(DriveMusicItem item, {int? playlistNumber}) {
    final job = DriveMusicTransfer(id: ++_sequence, name: item.name, upload: false)..total = item.bytes;
    _retryActions[job.id] = () => download(item, playlistNumber: playlistNumber);
    return _enqueue(job, (owner) async {
      if (!item.isAudio || !item.canDownload) {
        throw const GoogleDriveException('This Drive audio cannot be downloaded.');
      }
      final current = await metadata(item.id);
      _check(owner, job);
      if (!current.isAudio || !current.canDownload) {
        throw const GoogleDriveException('This Drive audio cannot be downloaded.');
      }
      final directory = Directory(
        p.join((await _downloadDirectory()).path, sha256.convert(utf8.encode(owner)).toString().substring(0, 16)),
      );
      await directory.create(recursive: true);
      final safeName = current.name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
      final extension = p.extension(safeName);
      final stem = p.basenameWithoutExtension(safeName);
      final name = '${stem.substring(0, min(stem.length, 100))} [${current.id}]$extension';
      final destination = File(p.join(directory.path, name));
      final partial = File('${destination.path}.part');
      final stamp = File('${partial.path}.json');
      final signature = jsonEncode({
        'id': current.id,
        'size': current.bytes,
        'md5': current.md5,
        'modified': current.modifiedAt?.toIso8601String(),
      });
      if (await destination.exists() && await _validAudio(destination, current)) {
        job.transferred = await destination.length();
      } else {
        if (await partial.exists() && (!await stamp.exists() || await stamp.readAsString() != signature)) {
          await partial.delete();
        }
        await stamp.writeAsString(signature, flush: true);
        Object? lastError;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            _check(owner, job);
            var offset = await partial.exists() ? await partial.length() : 0;
            if (current.bytes != null && offset > current.bytes!) {
              await partial.delete();
              offset = 0;
            }
            if (offset == 0 || current.bytes == null || offset != current.bytes) {
              final response = await drive.musicRequest(
                'GET',
                _uri('/drive/v3/files/${current.id}', {'alt': 'media'}),
                accountId: owner,
                headers: {if (offset > 0) 'Range': 'bytes=$offset-'},
              );
              if (response.statusCode != 200 && response.statusCode != 206) {
                await response.stream.drain<void>();
                _success(response.statusCode);
              }
              if (response.statusCode == 206) {
                final range = response.headers['content-range'];
                if (range == null || !range.startsWith('bytes $offset-')) {
                  await response.stream.drain<void>();
                  throw const GoogleDriveException('Google Drive returned an invalid audio range.');
                }
              } else {
                offset = 0;
              }
              final sink = partial.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
              job.total = current.bytes ?? (response.contentLength == null ? null : offset + response.contentLength!);
              job.transferred = offset;
              try {
                await for (final chunk in response.stream) {
                  _check(owner, job);
                  job.transferred += chunk.length;
                  if (job.total != null && job.transferred > job.total!) {
                    throw const GoogleDriveException('Google Drive returned an invalid audio size.');
                  }
                  sink.add(chunk);
                  await sink.flush();
                  _progress();
                }
              } finally {
                await sink.close();
              }
            }
            if (!await _validAudio(partial, current)) {
              if (await partial.exists()) await partial.delete();
              throw const GoogleDriveException('The Drive audio download was incomplete. Try again.');
            }
            _check(owner, job);
            if (await destination.exists()) await destination.delete();
            await partial.rename(destination.path);
            if (await stamp.exists()) await stamp.delete();
            lastError = null;
            break;
          } catch (error) {
            lastError = error;
            if (error is GoogleDriveCancelled ||
                (error is GoogleDriveException && error.statusCode != null && error.statusCode! < 500)) {
              rethrow;
            }
            if (attempt < 2) await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          }
        }
        if (lastError != null) throw lastError;
      }
      _check(owner, job);
      job.transferred = await destination.length();
      job.localPath = destination.path;
      final url = current.streamUrl(owner);
      if (playlistNumber == null) {
        final active = await files.getActivePlaylistNumber();
        if ((await files.readPlaylistTracks(active)).contains(url)) {
          await files.replaceStreamWithDownload(active, url, destination.path);
        } else {
          await files.addToPlaylist(active, destination.path);
        }
      } else {
        await files.replaceStreamWithDownload(playlistNumber, url, destination.path);
      }
      return destination.path;
    });
  }

  Future<bool> _validAudio(File file, DriveMusicItem item) async {
    final size = await file.length();
    if (size == 0 || (item.bytes != null && size != item.bytes)) return false;
    if (item.md5 != null && (await md5.bind(file.openRead()).first).toString() != item.md5) return false;
    return true;
  }

  Future<String> _ensureUploadFolder(String owner) async {
    if (_uploadFolder != null) return _uploadFolder!;
    final root = await drive.musicUploadRoot();
    _check(owner);
    final found = await _json(
      'GET',
      _uri('/drive/v3/files', {
        'q':
            "trashed = false and '$root' in parents and mimeType = '$driveFolderMime' and appProperties has { key='resonanceAudio' and value='1' }",
        'fields': 'files(id)',
        'pageSize': '100',
      }),
      owner,
    );
    final folders = found['files'] as List? ?? [];
    if (folders.isNotEmpty) return _uploadFolder = (folders.first as Map)['id'] as String;
    final created = await _json(
      'POST',
      _uri('/drive/v3/files', {'fields': 'id'}),
      owner,
      body: {
        'name': 'Audio',
        'mimeType': driveFolderMime,
        'parents': [root],
        'appProperties': {'resonanceAudio': '1'},
      },
    );
    return _uploadFolder = created['id'] as String;
  }

  Future<DriveMusicItem> upload(String path) {
    final job = DriveMusicTransfer(id: ++_sequence, name: p.basename(path), upload: true);
    _retryActions[job.id] = () => upload(path);
    return _enqueue(job, (owner) async {
      final file = File(path);
      final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
      if (!driveAudioExtensions.contains(extension) || !await file.exists()) {
        throw const GoogleDriveException('Choose a supported local audio file.');
      }
      final stat = await file.stat();
      if (stat.size == 0) throw const GoogleDriveException('This audio file is empty.');
      job.total = stat.size;
      final digest = (await md5.bind(file.openRead()).first).toString();
      _check(owner, job);
      final folder = await _ensureUploadFolder(owner);
      final matches = await _json(
        'GET',
        _uri('/drive/v3/files', {
          'q': "trashed = false and '$folder' in parents and name = '${_escape(job.name)}'",
          'fields': 'files($_fields)',
          'pageSize': '100',
        }),
        owner,
      );
      for (final value in matches['files'] as List? ?? []) {
        final existing = _item(Map<String, dynamic>.from(value as Map));
        if (existing.bytes == stat.size && existing.md5 == digest) {
          job.transferred = stat.size;
          return existing;
        }
      }
      final mime = switch (extension) {
        'mp3' => 'audio/mpeg',
        'm4a' => 'audio/mp4',
        'wav' => 'audio/wav',
        'webm' => 'audio/webm',
        _ => 'audio/$extension',
      };
      final begin = await drive.musicRequest(
        'POST',
        _uri('/upload/drive/v3/files', {'uploadType': 'resumable', 'fields': _fields}),
        accountId: owner,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'X-Upload-Content-Type': mime,
          'X-Upload-Content-Length': '${stat.size}',
        },
        bytes: utf8.encode(
          jsonEncode({
            'name': job.name,
            'mimeType': mime,
            'parents': [folder],
          }),
        ),
      );
      final location = begin.headers['location'];
      await begin.stream.drain<void>();
      _success(begin.statusCode);
      final session = location == null ? null : Uri.tryParse(location);
      if (session == null ||
          session.scheme != 'https' ||
          session.host != 'www.googleapis.com' ||
          !session.path.startsWith('/upload/drive/v3/files')) {
        throw const GoogleDriveException('Google Drive could not start this upload. Try again.');
      }
      final input = await file.open();
      try {
        var offset = 0, retries = 0;
        while (offset < stat.size) {
          _check(owner, job);
          final current = await file.stat();
          if (current.size != stat.size || current.modified != stat.modified) {
            throw const GoogleDriveException('This audio file changed during upload. Try again.');
          }
          await input.setPosition(offset);
          final chunk = await input.read(min(_chunkSize, stat.size - offset));
          if (chunk.isEmpty) throw const GoogleDriveException('This audio file changed during upload. Try again.');
          http.StreamedResponse response;
          try {
            response = await drive.musicRequest(
              'PUT',
              session,
              accountId: owner,
              headers: {
                'Content-Type': mime,
                'Content-Range': 'bytes $offset-${offset + chunk.length - 1}/${stat.size}',
              },
              bytes: chunk,
            );
            if (response.statusCode >= 500) {
              await response.stream.drain<void>();
              throw const SocketException('Drive upload interrupted');
            }
          } on GoogleDriveCancelled {
            rethrow;
          } catch (_) {
            if (++retries > 3) rethrow;
            await Future<void>.delayed(Duration(milliseconds: 500 * retries));
            _check(owner, job);
            response = await drive.musicRequest(
              'PUT',
              session,
              accountId: owner,
              headers: {'Content-Range': 'bytes */${stat.size}'},
              bytes: const [],
            );
          }
          if (response.statusCode == 308) {
            final range = response.headers['range'];
            final match = range == null ? null : RegExp(r'^bytes=0-(\d+)$').firstMatch(range);
            final next = match == null ? 0 : int.parse(match.group(1)!) + 1;
            await response.stream.drain<void>();
            if (next < offset || next > offset + chunk.length) {
              throw const GoogleDriveException('Google Drive returned an invalid upload range.');
            }
            if (next == offset && ++retries > 3) {
              throw const GoogleDriveException('Google Drive could not finish this upload. Try again.');
            }
            offset = next;
            job.transferred = offset;
            _progress();
          } else {
            final value = _item(await _responseJson(response, owner));
            if (value.bytes != stat.size || value.md5 != digest) {
              throw const GoogleDriveException('Google Drive could not verify the uploaded audio. Try again.');
            }
            job.transferred = stat.size;
            return value;
          }
        }
        throw const GoogleDriveException('Google Drive could not finish this upload. Try again.');
      } finally {
        await input.close();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in transfers) {
      job.cancelled = true;
    }
    drive.removeListener(_accountChanged);
    super.dispose();
  }
}
