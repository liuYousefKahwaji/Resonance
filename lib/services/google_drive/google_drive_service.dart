import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:resonance/services/playlist_transfer_codec.dart';

import 'google_drive_auth.dart';
import 'google_drive_models.dart';
import 'playlist_sync_document.dart';

class GoogleDriveService extends ChangeNotifier {
  GoogleDriveService({required GoogleDriveAuth auth, http.Client Function()? clientFactory})
    : _auth = auth,
      _clientFactory = clientFactory ?? http.Client.new;
  static final instance = GoogleDriveService(auth: GoogleDriveAuth.platform());
  static const folderName = 'ResonanceMusic';
  static const playlistMime = 'application/vnd.resonance.playlist+json';
  final GoogleDriveAuth _auth;
  final http.Client Function() _clientFactory;
  final Set<http.Client> _requests = {};
  Future<void>? _initialization;
  Future<void> _operations = Future.value();
  bool _v2Revisions = false;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? error;
  List<DrivePlaylist> playlists = const [];
  List<String> _folderIds = const [];
  GoogleDriveAccount? get account => _auth.account;
  bool get connected => account != null;
  int get sessionRevision => _epoch;
  bool get musicLibraryAccess => _auth.musicLibraryAccess;

  Future<void> enableMusicLibrary() async {
    await initialize();
    await _run(_auth.enableMusicLibrary);
  }

  Future<String> musicUploadRoot() async {
    await initialize();
    if (_folderIds.isEmpty) await refresh();
    return _folderIds.first;
  }

  /// Private media stays authenticated in memory; callers persist only file IDs.
  Future<Map<String, String>> musicHeaders(String accountId, {bool refresh = false}) async {
    final epoch = _epoch;
    if (!connected || account?.id != accountId) {
      throw const GoogleDriveException('Connect the Google account that owns this music.');
    }
    final token = await _auth.accessToken(refresh: refresh).timeout(const Duration(seconds: 30));
    _check(epoch);
    if (account?.id != accountId) throw const GoogleDriveCancelled();
    return {'Authorization': 'Bearer $token'};
  }

  /// Streaming transport for audio and resumable upload chunks. Unlike playlist
  /// JSON this must not buffer an entire file or impose the playlist byte cap.
  Future<http.StreamedResponse> musicRequest(
    String method,
    Uri uri, {
    required String accountId,
    Map<String, String> headers = const {},
    List<int>? bytes,
  }) async {
    if (uri.scheme != 'https' ||
        uri.host != 'www.googleapis.com' ||
        uri.hasPort ||
        (!uri.path.startsWith('/drive/v3/files') && !uri.path.startsWith('/upload/drive/v3/files'))) {
      throw const GoogleDriveException('Invalid Google Drive request.');
    }
    final epoch = _epoch;
    for (var attempt = 0; attempt < 2; attempt++) {
      final authorization = await musicHeaders(accountId, refresh: attempt > 0);
      _check(epoch);
      final client = _clientFactory();
      _requests.add(client);
      var handedOff = false;
      try {
        final request = http.Request(method, uri)
          ..followRedirects = false
          ..headers.addAll({...headers, ...authorization});
        if (bytes != null) request.bodyBytes = bytes;
        final response = await client.send(request).timeout(const Duration(seconds: 25));
        _check(epoch);
        if (response.statusCode == 401 && attempt == 0) continue;
        Stream<List<int>> body() async* {
          try {
            await for (final chunk in response.stream.timeout(const Duration(seconds: 25))) {
              _check(epoch);
              if (account?.id != accountId) throw const GoogleDriveCancelled();
              yield chunk;
            }
          } finally {
            _requests.remove(client);
            client.close();
          }
        }

        handedOff = true;
        return http.StreamedResponse(
          body(),
          response.statusCode,
          headers: response.headers,
          contentLength: response.contentLength,
        );
      } finally {
        if (!handedOff) {
          _requests.remove(client);
          client.close();
        }
      }
    }
    throw const GoogleDriveException('Reconnect Google Drive to continue.');
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _run(() async {
        await _auth.restore();
      });
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _check(int epoch) {
    if (_disposed || epoch != _epoch) throw const GoogleDriveCancelled();
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final epoch = _epoch;
    final operation = _operations.then((_) {
      _check(epoch);
      return _execute(action, epoch);
    });
    _operations = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<T> _execute<T>(Future<T> Function() action, int epoch) async {
    busy = true;
    error = null;
    _notify();
    try {
      final result = await action();
      _check(epoch);
      return result;
    } catch (exception) {
      if (epoch != _epoch || exception is GoogleDriveCancelled) throw const GoogleDriveCancelled();
      final message = switch (exception) {
        GoogleDriveException() => exception.message,
        PlaylistTransferException() => exception.message,
        GoogleSignInException(code: GoogleSignInExceptionCode.canceled) => null,
        GoogleSignInException(code: GoogleSignInExceptionCode.clientConfigurationError) =>
          'Google Drive is not configured correctly in this build yet.',
        SocketException() ||
        http.ClientException() ||
        TimeoutException() => 'Could not reach Google Drive. Check your connection and try again.',
        _ => 'Could not complete this Google Drive operation. Please try again.',
      };
      error = message;
      if (message == null) throw const GoogleDriveCancelled();
      if (exception is GoogleDriveException) rethrow;
      throw GoogleDriveException(message);
    } finally {
      if (epoch == _epoch) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> connect() async {
    await initialize();
    await _run(() async {
      final epoch = _epoch;
      final previousAccount = account?.id;
      await _auth.connect();
      _check(epoch);
      if (previousAccount != account?.id) {
        playlists = const [];
        _folderIds = const [];
      }
      _notify();
      await _refresh();
    });
  }

  Future<void> refresh() async {
    await initialize();
    await _run(_refresh);
  }

  /// The same OAuth project must own both platform clients. drive.file sees
  /// folders/files created by this app across devices, not unrelated Drive data.
  Future<void> _refresh() async {
    final epoch = _epoch;
    if (!connected) throw const GoogleDriveException('Connect Google Drive to continue.');
    final folders = await _findFolders();
    _check(epoch);
    _folderIds = folders;
    if (_folderIds.isEmpty) {
      final folder = await _json(
        'POST',
        '/drive/v3/files',
        query: {'fields': 'id'},
        body: {
          'name': folderName,
          'mimeType': 'application/vnd.google-apps.folder',
          'parents': ['root'],
        },
      );
      _check(epoch);
      final created = folder['id'] as String;
      // Concurrent first connects can both create a folder. Keep both readable
      // and choose the oldest as the write target; never delete user content.
      final discovered = await _findFolders();
      _check(epoch);
      _folderIds = discovered;
      if (!_folderIds.contains(created)) _folderIds = [..._folderIds, created];
    }
    final files = await _list({
      'q':
          "trashed = false and (${_folderIds.map((id) => "'${_escape(id)}' in parents").join(' or ')}) and (mimeType = '$playlistMime' or name contains '${DrivePlaylist.suffix}')",
      'fields': 'nextPageToken,files(id,name,mimeType,modifiedTime,size,appProperties)',
      'orderBy': 'modifiedTime desc,name',
    });
    _check(epoch);
    playlists = List.unmodifiable(
      files.where((file) => file['id'] is String && file['name'] is String).map(DrivePlaylist.fromJson),
    );
  }

  Future<List<String>> _findFolders() async {
    final folders = await _list({
      'q':
          "trashed = false and 'root' in parents and mimeType = 'application/vnd.google-apps.folder' and name = '$folderName'",
      'fields': 'nextPageToken,files(id,isAppAuthorized)',
      'orderBy': 'createdTime',
    });
    // Broad read permission must not turn an unrelated same-name user folder
    // into a write target for the existing playlist/sync subsystem.
    return folders
        .where((folder) => folder['isAppAuthorized'] != false)
        .map((folder) => folder['id'] as String)
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _list(Map<String, String> query) async {
    final result = <Map<String, dynamic>>[];
    String? page;
    final seen = <String>{};
    do {
      final json = await _json(
        'GET',
        '/drive/v3/files',
        query: {...query, 'pageSize': '100', if (page != null) 'pageToken': page},
      );
      final files = json['files'];
      if (files is! List) throw const GoogleDriveException('Google Drive returned an unreadable playlist list.');
      result.addAll(files.map((file) => Map<String, dynamic>.from(file as Map)));
      page = json['nextPageToken'] as String?;
      if (page != null && (!seen.add(page) || seen.length > 100)) {
        throw const GoogleDriveException('Google Drive returned too many playlist pages. Please try again.');
      }
    } while (page != null);
    return result;
  }

  Future<PlaylistTransferManifest> openPlaylist(DrivePlaylist playlist) async =>
      (await openSnapshot(playlist)).manifest;

  Future<DriveSyncSnapshot> openSnapshot(DrivePlaylist playlist) async {
    await initialize();
    return _run(() async {
      final etag = await _ownedFile(playlist.id);
      return _readSnapshot(playlist.id, etag);
    });
  }

  /// Conditional metadata reads avoid downloading unchanged playlist content.
  Future<DriveSyncSnapshot?> readForSync(DrivePlaylist playlist, {String? knownEtag}) async {
    await initialize();
    return _run(() async {
      if (_folderIds.isEmpty) await _refresh();
      final tag = (await _ownedFile(playlist.id, requireRevision: true))!;
      if (tag == knownEtag) return null;
      return _readSnapshot(playlist.id, tag);
    });
  }

  Future<DriveSyncSnapshot> _readSnapshot(String id, String? revision) async {
    // Drive's metadata ETag is not the media representation's ETag. A valid
    // metadata If-Match on alt=media can return 412. Verify the version around
    // the atomic media response instead; never combine bytes from two versions.
    final response = await _request('GET', '/drive/v3/files/${Uri.encodeComponent(id)}', query: {'alt': 'media'});
    if (revision != null && await _ownedFile(id, requireRevision: true) != revision) {
      throw const GoogleDriveException(
        'This playlist changed on another device. Refresh before replacing it.',
        statusCode: 412,
      );
    }
    return DriveSyncSnapshot(
      manifest: DrivePlaylistCodec.decode(response.bodyBytes),
      etag: revision ?? '',
      document: DrivePlaylistCodec.decodeSync(response.bodyBytes),
    );
  }

  Future<DrivePlaylist> upload(
    PlaylistTransferManifest manifest, {
    DrivePlaylist? replace,
    PlaylistSyncDocument? sync,
    String? ifMatch,
  }) async {
    await initialize();
    return _run(() async {
      if (_folderIds.isEmpty) await _refresh();
      String? etag;
      if (replace != null) {
        etag = await _ownedFile(replace.id, expectedModifiedAt: replace.modifiedAt, requireRevision: true);
        if (ifMatch != null && etag != ifMatch) {
          throw const GoogleDriveException(
            'This playlist changed on another device. Refresh before replacing it.',
            statusCode: 412,
          );
        }
      }
      var document = sync;
      if (replace != null && document == null) {
        final old = (await _readSnapshot(replace.id, etag)).document;
        if (old != null) {
          final available = <String, Queue<SyncEntry>>{};
          for (final entry in old.active) {
            (available[entry.videoId] ??= Queue()).add(entry);
          }
          document = old.edit(
            device: 'replace-${Random.secure().nextInt(1 << 32)}-${DateTime.now().microsecondsSinceEpoch}',
            renamed: manifest.playlistName,
            tracks: [
              for (final id in manifest.youtubeVideoIds)
                (videoId: id, entryId: available[id]?.isNotEmpty == true ? available[id]!.removeFirst().id : null),
            ],
          );
        }
      }
      final bytes = DrivePlaylistCodec.encode(manifest, sync: document);
      final v2 = etag?.startsWith('v2:') == true;
      final metadata = {
        v2 ? 'title' : 'name': '${manifest.playlistName.trim()}${DrivePlaylist.suffix}',
        'mimeType': playlistMime,
        if (v2)
          'properties': [
            {'key': 'resonanceKind', 'value': 'playlist', 'visibility': 'PRIVATE'},
            {'key': 'trackCount', 'value': '${manifest.youtubeVideoIds.length}', 'visibility': 'PRIVATE'},
          ]
        else
          'appProperties': {'resonanceKind': 'playlist', 'trackCount': '${manifest.youtubeVideoIds.length}'},
        if (replace == null) 'parents': [_folderIds.first],
      };
      final boundary = 'resonance_${Random.secure().nextInt(1 << 32)}';
      final body = <int>[
        ...utf8.encode(
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${jsonEncode(metadata)}\r\n',
        ),
        ...utf8.encode('--$boundary\r\nContent-Type: $playlistMime\r\n\r\n'),
        ...bytes,
        ...utf8.encode('\r\n--$boundary--\r\n'),
      ];
      final uploaded = await _request(
        replace == null
            ? 'POST'
            : v2
            ? 'PUT'
            : 'PATCH',
        '/upload/drive/${v2 ? 'v2' : 'v3'}/files${replace == null ? '' : '/${Uri.encodeComponent(replace.id)}'}',
        query: {'uploadType': 'multipart', 'fields': 'id'},
        bytes: body,
        headers: {
          'Content-Type': 'multipart/related; boundary=$boundary',
          if (etag != null) 'If-Match': v2 ? etag.substring(3) : etag,
        },
      );
      final uploadedId = (jsonDecode(uploaded.body) as Map)['id'] as String;
      final saved = DrivePlaylist(
        id: uploadedId,
        name: manifest.playlistName,
        trackCount: manifest.youtubeVideoIds.length,
      );
      // A committed write must not be reported as failed if a subsequent list
      // refresh loses the connection. Update locally; refresh is independent.
      playlists = List.unmodifiable([saved, ...playlists.where((item) => item.id != uploadedId)]);
      return saved;
    });
  }

  /// Reversible deletion. Membership and revision checks are identical to
  /// replacement; this never permanently deletes a file or local audio.
  Future<void> trashPlaylist(DrivePlaylist playlist) async {
    await initialize();
    await _run(() async {
      if (_folderIds.isEmpty) await _refresh();
      final revision = (await _ownedFile(playlist.id, expectedModifiedAt: playlist.modifiedAt, requireRevision: true))!;
      final v2 = revision.startsWith('v2:');
      await _request(
        v2 ? 'POST' : 'PATCH',
        '/drive/${v2 ? 'v2' : 'v3'}/files/${Uri.encodeComponent(playlist.id)}${v2 ? '/trash' : ''}',
        query: {'fields': 'id'},
        bytes: v2 ? null : utf8.encode('{"trashed":true}'),
        headers: {'If-Match': v2 ? revision.substring(3) : revision, 'Content-Type': 'application/json'},
      );
      playlists = List.unmodifiable(playlists.where((item) => item.id != playlist.id));
    });
  }

  /// Read membership again before any content access or replacement, rather
  /// than trusting a stale list entry or an arbitrary cloud file ID.
  Future<String?> _ownedFile(String id, {DateTime? expectedModifiedAt, bool requireRevision = false}) async {
    if (_v2Revisions && requireRevision) return _ownedV2File(id, expectedModifiedAt: expectedModifiedAt);
    final response = await _request(
      'GET',
      '/drive/v3/files/${Uri.encodeComponent(id)}',
      query: {'fields': 'parents,trashed,name,mimeType,size,modifiedTime'},
    );
    final metadata = jsonDecode(response.body) as Map<String, dynamic>;
    final parents = metadata['parents'];
    final name = metadata['name'];
    if (metadata['trashed'] == true ||
        parents is! List ||
        !parents.any(_folderIds.contains) ||
        (metadata['mimeType'] != playlistMime && (name is! String || !name.endsWith(DrivePlaylist.suffix)))) {
      throw const GoogleDriveException(
        'This playlist is no longer in ResonanceMusic. Refresh and try again.',
        statusCode: 404,
      );
    }
    final size = int.tryParse('${metadata['size']}');
    if (size != null && size > DrivePlaylistCodec.maxBytes) {
      throw const GoogleDriveException('This Google Drive playlist is too large to open.');
    }
    if (expectedModifiedAt != null && DateTime.tryParse('${metadata['modifiedTime']}') != expectedModifiedAt) {
      throw const GoogleDriveException('This playlist changed on another device. Refresh before replacing it.');
    }
    final etag = response.headers['etag'];
    if (etag != null && etag.isNotEmpty && !etag.startsWith('W/')) return etag;
    if (!requireRevision) return null;
    _v2Revisions = true;
    return _ownedV2File(id, expectedModifiedAt: expectedModifiedAt);
  }

  Future<String> _ownedV2File(String id, {DateTime? expectedModifiedAt}) async {
    final metadata = await _json(
      'GET',
      '/drive/v2/files/${Uri.encodeComponent(id)}',
      query: {'fields': 'etag,title,mimeType,parents/id,labels/trashed,fileSize,modifiedDate'},
    );
    final parents = metadata['parents'];
    final name = metadata['title'];
    if (metadata['labels'] is! Map ||
        (metadata['labels'] as Map)['trashed'] == true ||
        parents is! List ||
        !parents.any((parent) => parent is Map && _folderIds.contains(parent['id'])) ||
        (metadata['mimeType'] != playlistMime && (name is! String || !name.endsWith(DrivePlaylist.suffix)))) {
      throw const GoogleDriveException(
        'This playlist is no longer in ResonanceMusic. Refresh and try again.',
        statusCode: 404,
      );
    }
    final size = int.tryParse('${metadata['fileSize']}');
    if (size != null && size > DrivePlaylistCodec.maxBytes) {
      throw const GoogleDriveException('This Google Drive playlist is too large to open.');
    }
    if (expectedModifiedAt != null && DateTime.tryParse('${metadata['modifiedDate']}') != expectedModifiedAt) {
      throw const GoogleDriveException(
        'This playlist changed on another device. Refresh before replacing it.',
        statusCode: 412,
      );
    }
    final etag = metadata['etag'];
    if (etag is! String || etag.isEmpty || etag.startsWith('W/')) {
      throw const GoogleDriveException('Google Drive could not verify this playlist version. Refresh and try again.');
    }
    return 'v2:$etag';
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final response = await _request(
      method,
      path,
      query: query,
      bytes: body == null ? null : utf8.encode(jsonEncode(body)),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
    );
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, String>? query,
    List<int>? bytes,
    Map<String, String>? headers,
  }) async {
    final epoch = _epoch;
    for (var attempt = 0; attempt < 2; attempt++) {
      _check(epoch);
      final token = await _auth.accessToken(refresh: attempt > 0).timeout(const Duration(seconds: 30));
      _check(epoch);
      final client = _clientFactory();
      _requests.add(client);
      try {
        final request = http.Request(method, Uri.https('www.googleapis.com', path, query))
          ..followRedirects = false
          ..headers.addAll({...?headers, 'Authorization': 'Bearer $token'});
        if (bytes != null) request.bodyBytes = bytes;
        final streamed = await client.send(request).timeout(const Duration(seconds: 25));
        final contentLength = streamed.contentLength;
        if (contentLength != null && contentLength > DrivePlaylistCodec.maxBytes) {
          throw const GoogleDriveException('The Google Drive response is too large.');
        }
        final data = await (() async {
          final result = <int>[];
          await for (final chunk in streamed.stream.timeout(const Duration(seconds: 15))) {
            _check(epoch);
            if (result.length + chunk.length > DrivePlaylistCodec.maxBytes) {
              throw const GoogleDriveException('The Google Drive response is too large.');
            }
            result.addAll(chunk);
          }
          return result;
        })().timeout(const Duration(seconds: 30));
        _check(epoch);
        final response = http.Response.bytes(data, streamed.statusCode, headers: streamed.headers);
        if (response.statusCode == 401 && attempt == 0) continue;
        if (response.statusCode >= 200 && response.statusCode < 300) return response;
        throw GoogleDriveException(switch (response.statusCode) {
          401 => 'Reconnect Google Drive to continue.',
          403 => 'Google Drive access was denied. Check Drive permissions and available storage.',
          404 => 'This Google Drive playlist or folder was moved or deleted. Refresh and try again.',
          409 || 412 => 'This playlist changed on another device. Refresh before replacing it.',
          429 => 'Google Drive is busy. Wait a moment and try again.',
          _ => 'Google Drive could not complete the request. Please try again.',
        }, statusCode: response.statusCode);
      } finally {
        _requests.remove(client);
        client.close();
      }
    }
    throw const GoogleDriveException('Reconnect Google Drive to continue.');
  }

  Future<void> logout() async {
    ++_epoch;
    for (final client in _requests.toList()) {
      client.close();
    }
    _requests.clear();
    playlists = const [];
    _folderIds = const [];
    error = null;
    busy = true;
    _notify();
    try {
      await _auth.logout();
    } finally {
      busy = false;
      _notify();
    }
  }

  static String _escape(String value) => value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    for (final client in _requests) {
      client.close();
    }
    _requests.clear();
    super.dispose();
  }
}
