import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';
import 'package:resonance/services/google_drive/google_drive_service.dart';
import 'package:resonance/services/google_drive/playlist_sync_document.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'google_drive_test.dart' show FakeDriveAuth, jsonResponse, manifest;

/// Models the observed live Drive contract: no HTTP ETag headers, v2 JSON
/// etag, metadata If-Match writes, and a distinct media representation ETag.
class NoHeaderDrive {
  List<int> content = DrivePlaylistCodec.encode(manifest);
  int revision = 1, writes = 0, mediaReads = 0, v2Reads = 0, trashCalls = 0;
  bool trashed = false, owned = true, changeDuringRead = false, failLists = false;
  Completer<void>? started, release;
  String get tag => '"file-$revision"';
  DateTime get modified => DateTime.utc(2026, 10, 30, 0, 0, revision);
  Map<String, dynamic> get v3 => {
    'id': 'playlist-one',
    'name': 'Test${DrivePlaylist.suffix}',
    'mimeType': GoogleDriveService.playlistMime,
    'size': '${content.length}',
    'version': '$revision',
    'modifiedTime': modified.toIso8601String(),
    'trashed': trashed,
    'parents': [owned ? 'folder-a' : 'other'],
  };
  Map<String, dynamic> get v2 => {
    'id': 'playlist-one',
    'title': v3['name'],
    'etag': tag,
    'mimeType': GoogleDriveService.playlistMime,
    'fileSize': '${content.length}',
    'modifiedDate': modified.toIso8601String(),
    'labels': {'trashed': trashed},
    'parents': [
      {'id': owned ? 'folder-a' : 'other'},
    ],
  };

  Future<http.Response> handle(http.Request request) async {
    if (request.url.queryParameters['alt'] == 'media') {
      mediaReads++;
      if (request.headers.containsKey('If-Match')) return http.Response('media etag differs', 412);
      final bytes = content.toList();
      if (changeDuringRead) {
        changeDuringRead = false;
        revision++;
      }
      return http.Response.bytes(bytes, 200);
    }
    if (request.method == 'PUT' || request.url.path.endsWith('/trash')) {
      if (request.headers['If-Match'] != tag) return http.Response('stale', 412);
      if (request.url.path.endsWith('/trash')) {
        expect(request.method, 'POST');
        trashCalls++;
        trashed = true;
        revision++;
      } else {
        expect(request.url.path, '/upload/drive/v2/files/playlist-one');
        final parts = utf8.decode(request.bodyBytes).split('\r\n\r\n');
        final metadata = jsonDecode(parts[1].split('\r\n--').first) as Map;
        expect(metadata['title'], endsWith(DrivePlaylist.suffix));
        expect(metadata.containsKey('name'), isFalse);
        expect(metadata['properties'], isA<List>());
        content = utf8.encode(parts[2].split('\r\n--').first);
        DrivePlaylistCodec.decode(content);
        writes++;
        revision++;
      }
      return jsonResponse({'id': 'playlist-one'});
    }
    if (request.url.path == '/drive/v2/files/playlist-one') {
      v2Reads++;
      return jsonResponse(v2);
    }
    if (request.url.path == '/drive/v3/files/playlist-one') {
      started?.complete();
      started = null;
      await release?.future;
      return jsonResponse(v3);
    }
    expect(request.url.path, '/drive/v3/files');
    if (failLists) return http.Response('offline', 503);
    final folder = request.url.queryParameters['q']!.contains("mimeType = 'application/vnd.google-apps.folder'");
    return jsonResponse({
      'files': folder
          ? [
              {'id': 'folder-a'},
            ]
          : trashed
          ? []
          : [v3],
    });
  }

  GoogleDriveService service() => GoogleDriveService(auth: FakeDriveAuth(), clientFactory: () => MockClient(handle));
}

void main() {
  test('realistic missing-header responses sync and unchanged polls skip content', () async {
    final backend = NoHeaderDrive();
    final drive = backend.service();
    addTearDown(drive.dispose);
    await drive.refresh();
    final snapshot = (await drive.readForSync(drive.playlists.single))!;
    expect(snapshot.etag, startsWith('v2:'));
    expect(snapshot.manifest.youtubeVideoIds, manifest.youtubeVideoIds);
    final reads = backend.mediaReads, versions = backend.v2Reads;
    expect(await drive.readForSync(drive.playlists.single, knownEtag: snapshot.etag), isNull);
    expect(backend.mediaReads, reads);
    expect(backend.v2Reads, versions + 1);
  });

  test('missing-header replacement succeeds and stale saves retain the newer data', () async {
    final backend = NoHeaderDrive();
    final drive = backend.service();
    addTearDown(drive.dispose);
    await drive.refresh();
    final file = drive.playlists.single;
    final before = (await drive.readForSync(file))!;
    const updated = PlaylistTransferManifest(playlistName: 'Updated', youtubeVideoIds: ['ccccccccccc']);
    await drive.upload(updated, replace: file, ifMatch: before.etag);
    expect(DrivePlaylistCodec.decode(backend.content).youtubeVideoIds, updated.youtubeVideoIds);
    await expectLater(
      drive.upload(
        manifest,
        replace: DrivePlaylist(id: file.id, name: file.name),
        ifMatch: before.etag,
      ),
      throwsA(isA<GoogleDriveException>().having((e) => e.statusCode, 'stale', 412)),
    );
    expect(backend.writes, 1);
    expect(DrivePlaylistCodec.decode(backend.content).playlistName, 'Updated');
  });

  test('a changed version across the media read is retried rather than applied', () async {
    final backend = NoHeaderDrive();
    final drive = backend.service();
    addTearDown(drive.dispose);
    await drive.refresh();
    backend.changeDuringRead = true;
    await expectLater(
      drive.readForSync(drive.playlists.single),
      throwsA(isA<GoogleDriveException>().having((e) => e.statusCode, 'changed', 412)),
    );
    expect((await drive.readForSync(drive.playlists.single))!.etag, 'v2:${backend.tag}');
    expect(backend.writes, 0);
  });

  test('manual replacement retains sync identities and deletion history', () async {
    final backend = NoHeaderDrive();
    final seed = PlaylistSyncDocument.seed('playlist-one', manifest);
    backend.content = DrivePlaylistCodec.encode(manifest, sync: seed);
    final drive = backend.service();
    addTearDown(drive.dispose);
    await drive.refresh();
    const updated = PlaylistTransferManifest(playlistName: 'Updated', youtubeVideoIds: ['aaaaaaaaaaa', 'ccccccccccc']);
    await drive.upload(updated, replace: drive.playlists.single);
    final doc = DrivePlaylistCodec.decodeSync(backend.content)!;
    expect(doc.active.map((entry) => entry.videoId), updated.youtubeVideoIds);
    expect(doc.active.first.id, seed.active.first.id);
    expect(doc.entries.values.any((entry) => entry.removed), isTrue);
  });

  test('trash is reversible, version guarded, folder scoped and updates the local list', () async {
    final backend = NoHeaderDrive();
    final drive = backend.service();
    addTearDown(drive.dispose);
    await drive.refresh();
    final file = drive.playlists.single;
    backend.owned = false;
    await expectLater(drive.trashPlaylist(file), throwsA(isA<GoogleDriveException>()));
    expect(backend.trashCalls, 0);
    backend.owned = true;
    backend.revision++;
    await expectLater(drive.trashPlaylist(file), throwsA(isA<GoogleDriveException>()));
    expect(backend.trashCalls, 0);
    await drive.refresh();
    await drive.trashPlaylist(drive.playlists.single);
    expect(backend.trashed, isTrue);
    expect(backend.trashCalls, 1);
    expect(drive.playlists, isEmpty);
  });

  test('overlapping read and refresh are queued instead of failing as busy', () async {
    final backend = NoHeaderDrive();
    final drive = backend.service();
    addTearDown(drive.dispose);
    await drive.refresh();
    backend.started = Completer<void>();
    backend.release = Completer<void>();
    final begun = backend.started!.future;
    final read = drive.readForSync(drive.playlists.single);
    await begun;
    final refresh = drive.refresh();
    backend.release!.complete();
    backend.release = null;
    await Future.wait([read, refresh]);
    expect(drive.error, isNull);
    expect(drive.playlists, hasLength(1));
  });

  test('a committed replacement is successful even when listing is temporarily unavailable', () async {
    final backend = NoHeaderDrive();
    final drive = backend.service();
    addTearDown(drive.dispose);
    await drive.refresh();
    final target = drive.playlists.single;
    backend.failLists = true;
    const update = PlaylistTransferManifest(playlistName: 'Saved', youtubeVideoIds: ['ccccccccccc']);
    final saved = await drive.upload(update, replace: target);
    expect(saved.name, 'Saved');
    expect(backend.writes, 1);
    expect(drive.playlists.single.name, 'Saved');
    await expectLater(drive.refresh(), throwsA(isA<GoogleDriveException>()));
    expect(DrivePlaylistCodec.decode(backend.content).playlistName, 'Saved');
  });
}
