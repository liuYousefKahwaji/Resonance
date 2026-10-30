import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:resonance/services/google_drive/google_drive_auth.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';
import 'package:resonance/services/google_drive/google_drive_service.dart';
import 'package:resonance/services/google_drive/playlist_sync_document.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';

const manifest = PlaylistTransferManifest(
  playlistName: 'ليل / Night',
  youtubeVideoIds: ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'aaaaaaaaaaa'],
);

class FakeDriveAuth extends GoogleDriveAuth {
  @override
  GoogleDriveAccount? account = const GoogleDriveAccount(id: 'account-a', name: 'Resonance listener');
  int restores = 0, connects = 0, refreshes = 0;
  GoogleDriveAccount? nextAccount;
  @override
  Future<void> restore() async {
    restores++;
  }

  @override
  Future<void> connect() async {
    connects++;
    account = nextAccount ?? const GoogleDriveAccount(id: 'account-a', name: 'Resonance listener');
  }

  @override
  Future<String> accessToken({bool refresh = false}) async {
    if (refresh) refreshes++;
    return refresh ? 'new-token' : 'old-token';
  }

  @override
  Future<void> logout() async {
    account = null;
  }
}

Map<String, dynamic> remoteFile({
  String id = 'playlist-one',
  String parent = 'folder-a',
  String modified = '2026-10-29T12:00:00Z',
}) => {
  'id': id,
  'name': '${manifest.playlistName}${DrivePlaylist.suffix}',
  'mimeType': GoogleDriveService.playlistMime,
  'parents': [parent],
  'trashed': false,
  'modifiedTime': modified,
  'appProperties': {'trackCount': '3'},
  'size': '${DrivePlaylistCodec.encode(manifest).length}',
};

http.Response jsonResponse(Object json, {Map<String, String>? headers}) =>
    http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json; charset=utf-8', ...?headers});

void main() {
  test('sync reads use matching versions, skip unchanged bodies and reject stale writes', () async {
    var revision = 1, bodies = 0, uploads = 0;
    final doc = PlaylistSyncDocument.seed('playlist-one', manifest);
    final service = GoogleDriveService(
      auth: FakeDriveAuth(),
      clientFactory: () => MockClient((request) async {
        if (request.url.path.startsWith('/upload/')) {
          uploads++;
          expect(request.headers['If-Match'], '"$revision"');
          final part = utf8.decode(request.bodyBytes).split('\r\n\r\n')[2].split('\r\n--').first;
          expect(DrivePlaylistCodec.decodeSync(utf8.encode(part))!.id, 'playlist-one');
          return jsonResponse({'id': 'playlist-one'});
        }
        if (request.url.queryParameters['alt'] == 'media') {
          bodies++;
          expect(request.headers['If-Match'], isNull);
          return http.Response.bytes(DrivePlaylistCodec.encode(manifest, sync: doc), 200);
        }
        if (request.url.path.endsWith('/playlist-one')) {
          return jsonResponse(
            {
              ...remoteFile(),
              'parents': ['folder-a'],
            },
            headers: {'etag': '"$revision"'},
          );
        }
        final folder = request.url.queryParameters['q']!.contains("mimeType = 'application/vnd.google-apps.folder'");
        return jsonResponse({
          'files': folder
              ? [
                  {'id': 'folder-a'},
                ]
              : [remoteFile()],
        });
      }),
    );
    addTearDown(service.dispose);
    await service.refresh();
    final file = service.playlists.single;
    final snapshot = (await service.readForSync(file))!;
    expect(snapshot.document!.fingerprint, doc.fingerprint);
    expect(await service.readForSync(file, knownEtag: snapshot.etag), isNull);
    expect(bodies, 1);
    revision++;
    await expectLater(
      service.upload(manifest, replace: file, sync: doc, ifMatch: snapshot.etag),
      throwsA(isA<GoogleDriveException>().having((error) => error.statusCode, 'conflict', 412)),
    );
    expect(uploads, 0);
    final fresh = (await service.readForSync(file))!;
    await service.upload(manifest, replace: file, sync: doc, ifMatch: fresh.etag);
    expect(uploads, 1);
  });
  test('Drive names remain compatible with the original identity-only manifest checksum', () {
    final named = PlaylistTransferManifest(
      playlistName: manifest.playlistName,
      youtubeVideoIds: manifest.youtubeVideoIds,
      trackMetadata: const {'aaaaaaaaaaa': PlaylistTransferTrackMetadata(title: 'Track', artist: 'Artist')},
    );
    final bytes = DrivePlaylistCodec.encode(named);
    final decoded = DrivePlaylistCodec.decode(bytes);
    expect(decoded.trackMetadata['aaaaaaaaaaa']!.title, 'Track');
    final envelope = jsonDecode(utf8.decode(bytes)) as Map;
    expect((envelope['manifest'] as Map).containsKey('trackMetadata'), isFalse);
    expect(envelope['sha256'], jsonDecode(utf8.decode(DrivePlaylistCodec.encode(manifest)))['sha256']);
    envelope['trackMetadata']['aaaaaaaaaaa']['title'] = 'Tampered';
    expect(() => DrivePlaylistCodec.decode(utf8.encode(jsonEncode(envelope))), throwsA(isA<GoogleDriveException>()));
  });
  test('cloud roundtrip preserves Unicode names, duplicate tracks and order', () {
    final result = DrivePlaylistCodec.decode(DrivePlaylistCodec.encode(manifest));
    expect(result.playlistName, manifest.playlistName);
    expect(result.youtubeVideoIds, manifest.youtubeVideoIds);
    expect(utf8.decode(DrivePlaylistCodec.encode(manifest)), isNot(contains('localPath')));
  });

  test('cloud validation rejects tampering, newer format, invalid IDs and oversized content', () {
    final json = jsonDecode(utf8.decode(DrivePlaylistCodec.encode(manifest))) as Map;
    json['manifest']['youtubeVideoIds'][0] = 'ccccccccccc';
    expect(() => DrivePlaylistCodec.decode(utf8.encode(jsonEncode(json))), throwsA(isA<GoogleDriveException>()));
    json['version'] = 2;
    expect(() => DrivePlaylistCodec.decode(utf8.encode(jsonEncode(json))), throwsA(isA<GoogleDriveException>()));
    expect(
      () => DrivePlaylistCodec.encode(
        const PlaylistTransferManifest(playlistName: 'invalid', youtubeVideoIds: ['file:///private.mp3']),
      ),
      throwsA(isA<PlaylistTransferException>()),
    );
    expect(
      () => DrivePlaylistCodec.decode(List.filled(DrivePlaylistCodec.maxBytes + 1, 0)),
      throwsA(isA<GoogleDriveException>()),
    );
  });

  test('reuse existing app folder and follow every playlist page', () async {
    final auth = FakeDriveAuth();
    var creates = 0;
    final service = GoogleDriveService(
      auth: auth,
      clientFactory: () => MockClient((request) async {
        if (request.method == 'POST') {
          creates++;
          return jsonResponse({'id': 'unexpected'});
        }
        final query = request.url.queryParameters;
        if (query['q']!.contains("mimeType = 'application/vnd.google-apps.folder'")) {
          expect(query['q'], contains("'root' in parents"));
          return jsonResponse({
            'files': [
              {'id': 'folder-a'},
            ],
          });
        }
        expect(query['q'], contains("'folder-a' in parents"));
        return jsonResponse({
          'files': [remoteFile(id: query['pageToken'] == null ? 'one' : 'two')],
          if (query['pageToken'] == null) 'nextPageToken': 'page-two',
        });
      }),
    );
    addTearDown(service.dispose);
    await service.connect();
    expect(service.playlists.map((item) => item.id), ['one', 'two']);
    expect(service.playlists.first.name, manifest.playlistName);
    expect(service.playlists.first.trackCount, 3);
    expect(creates, 0);
    expect(auth.restores, 1);
  });

  test('first connection creates a visible ResonanceMusic folder, not appDataFolder', () async {
    var exists = false;
    final service = GoogleDriveService(
      auth: FakeDriveAuth(),
      clientFactory: () => MockClient((request) async {
        if (request.method == 'POST') {
          final metadata = jsonDecode(request.body);
          expect(metadata['name'], 'ResonanceMusic');
          expect(metadata['parents'], ['root']);
          exists = true;
          return jsonResponse({'id': 'folder-a'});
        }
        return jsonResponse({
          'files':
              request.url.queryParameters['q']!.contains("mimeType = 'application/vnd.google-apps.folder'") && exists
              ? [
                  {'id': 'folder-a'},
                ]
              : [],
        });
      }),
    );
    addTearDown(service.dispose);
    await service.connect();
    expect(exists, isTrue);
  });

  test('concurrent first-connect folders are both read instead of deleting one', () async {
    var created = false;
    final service = GoogleDriveService(
      auth: FakeDriveAuth(),
      clientFactory: () => MockClient((request) async {
        if (request.method == 'POST') {
          created = true;
          return jsonResponse({'id': 'new-folder'});
        }
        if (request.url.queryParameters['q']!.contains("mimeType = 'application/vnd.google-apps.folder'")) {
          return jsonResponse({
            'files': created
                ? [
                    {'id': 'older-folder'},
                    {'id': 'new-folder'},
                  ]
                : [],
          });
        }
        expect(request.url.queryParameters['q'], contains("'older-folder' in parents or 'new-folder' in parents"));
        return jsonResponse({'files': []});
      }),
    );
    addTearDown(service.dispose);
    await service.connect();
  });

  test('401 refreshes authorization once and retries with the new token', () async {
    final auth = FakeDriveAuth();
    var attempts = 0;
    final service = GoogleDriveService(
      auth: auth,
      clientFactory: () => MockClient((request) async {
        if (attempts++ == 0) return http.Response('expired', 401);
        if (attempts == 2) expect(request.headers['Authorization'], 'Bearer new-token');
        return jsonResponse({
          'files': request.url.queryParameters['q']!.contains("mimeType = 'application/vnd.google-apps.folder'")
              ? [
                  {'id': 'folder-a'},
                ]
              : [],
        });
      }),
    );
    addTearDown(service.dispose);
    await service.refresh();
    expect(auth.refreshes, 1);
  });

  test('opening a cloud playlist verifies folder membership before content', () async {
    var mediaGets = 0;
    final service = GoogleDriveService(
      auth: FakeDriveAuth(),
      clientFactory: () => MockClient((request) async {
        if (request.url.queryParameters['alt'] == 'media') {
          mediaGets++;
          return http.Response.bytes(DrivePlaylistCodec.encode(manifest), 200);
        }
        if (request.url.path.endsWith('/playlist-one')) return jsonResponse(remoteFile(parent: 'unrelated-folder'));
        return jsonResponse({
          'files': request.url.queryParameters['q']!.contains("mimeType = 'application/vnd.google-apps.folder'")
              ? [
                  {'id': 'folder-a'},
                ]
              : [remoteFile()],
        });
      }),
    );
    addTearDown(service.dispose);
    await service.refresh();
    await expectLater(service.openPlaylist(service.playlists.single), throwsA(isA<GoogleDriveException>()));
    expect(mediaGets, 0);
  });

  test('cloud import supplies the same manifest used by QR stream/download', () async {
    final service = GoogleDriveService(
      auth: FakeDriveAuth(),
      clientFactory: () => MockClient((request) async {
        if (request.url.queryParameters['alt'] == 'media') {
          return http.Response.bytes(DrivePlaylistCodec.encode(manifest), 200);
        }
        if (request.url.path.endsWith('/playlist-one')) return jsonResponse(remoteFile());
        return jsonResponse({
          'files': request.url.queryParameters['q']!.contains("mimeType = 'application/vnd.google-apps.folder'")
              ? [
                  {'id': 'folder-a'},
                ]
              : [remoteFile()],
        });
      }),
    );
    addTearDown(service.dispose);
    await service.refresh();
    final opened = await service.openPlaylist(service.playlists.single);
    expect(opened.youtubeVideoIds, manifest.youtubeVideoIds);
  });

  test('replacement uses If-Match and conflicts do not fall back to an unsafe overwrite', () async {
    var patches = 0;
    final service = GoogleDriveService(
      auth: FakeDriveAuth(),
      clientFactory: () => MockClient((request) async {
        if (request.url.queryParameters['alt'] == 'media') {
          return http.Response.bytes(DrivePlaylistCodec.encode(manifest), 200);
        }
        if (request.method == 'PATCH') {
          patches++;
          expect(request.headers['If-Match'], '"revision-a"');
          expect(request.headers['Content-Type'], startsWith('multipart/related;'));
          expect(request.body, contains('resonance-drive-playlist'));
          expect(request.body, isNot(contains('"parents"')));
          return http.Response('changed elsewhere', 412);
        }
        if (request.url.path.endsWith('/playlist-one')) {
          return jsonResponse(remoteFile(), headers: {'etag': '"revision-a"'});
        }
        return jsonResponse({
          'files': request.url.queryParameters['q']!.contains("mimeType = 'application/vnd.google-apps.folder'")
              ? [
                  {'id': 'folder-a'},
                ]
              : [remoteFile()],
        });
      }),
    );
    addTearDown(service.dispose);
    await service.refresh();
    await expectLater(
      service.upload(manifest, replace: service.playlists.single),
      throwsA(isA<GoogleDriveException>()),
    );
    expect(patches, 1);
    expect(service.error, contains('changed on another device'));
  });

  test('logout invalidates late HTTP results and clears all account-scoped playlists', () async {
    final response = Completer<http.Response>();
    final requested = Completer<void>();
    final service = GoogleDriveService(
      auth: FakeDriveAuth(),
      clientFactory: () => MockClient((request) async {
        requested.complete();
        return response.future;
      }),
    );
    addTearDown(service.dispose);
    final work = service.refresh();
    final outcome = expectLater(work, throwsA(isA<GoogleDriveCancelled>()));
    await requested.future;
    await service.logout();
    response.complete(
      jsonResponse({
        'files': [
          {'id': 'old-account-folder'},
        ],
      }),
    );
    await outcome;
    expect(service.connected, isFalse);
    expect(service.playlists, isEmpty);
    expect(service.busy, isFalse);
    expect(service.error, isNull);
  });

  test('persistent 401 is bounded and remote error bodies never become user messages', () async {
    final auth = FakeDriveAuth();
    var requests = 0;
    final service = GoogleDriveService(
      auth: auth,
      clientFactory: () => MockClient((request) async {
        requests++;
        return http.Response('private diagnostic token=do-not-display', 401);
      }),
    );
    addTearDown(service.dispose);
    await expectLater(service.refresh(), throwsA(isA<GoogleDriveException>()));
    expect(requests, 2);
    expect(service.error, 'Reconnect Google Drive to continue.');
  });

  test('new upload saves only the transfer envelope into the app folder', () async {
    var saved = false;
    final service = GoogleDriveService(
      auth: FakeDriveAuth(),
      clientFactory: () => MockClient((request) async {
        if (request.method == 'POST') {
          expect(request.url.path, '/upload/drive/v3/files');
          final body = utf8.decode(request.bodyBytes);
          expect(body, contains('"parents":["folder-a"]'));
          final part = body.split('\r\n\r\n')[2].split('\r\n--').first;
          final decoded = DrivePlaylistCodec.decode(utf8.encode(part));
          expect(decoded.playlistName, manifest.playlistName);
          expect(decoded.youtubeVideoIds, manifest.youtubeVideoIds);
          saved = true;
          return jsonResponse({'id': 'playlist-one'});
        }
        final folderQuery = request.url.queryParameters['q']!.contains(
          "mimeType = 'application/vnd.google-apps.folder'",
        );
        return jsonResponse({
          'files': folderQuery
              ? [
                  {'id': 'folder-a'},
                ]
              : saved
              ? [remoteFile()]
              : [],
        });
      }),
    );
    addTearDown(service.dispose);
    await service.refresh();
    await service.upload(manifest);
    expect(saved, isTrue);
    expect(service.playlists.single.name, manifest.playlistName);
  });

  test('switching accounts clears the previous library even if the new account fails to load', () async {
    final auth = FakeDriveAuth();
    final service = GoogleDriveService(
      auth: auth,
      clientFactory: () => MockClient((request) async {
        if (auth.account?.id == 'account-b') return http.Response('denied', 403);
        final folderQuery = request.url.queryParameters['q']!.contains(
          "mimeType = 'application/vnd.google-apps.folder'",
        );
        return jsonResponse({
          'files': folderQuery
              ? [
                  {'id': 'folder-a'},
                ]
              : [remoteFile()],
        });
      }),
    );
    addTearDown(service.dispose);
    await service.refresh();
    expect(service.playlists, isNotEmpty);
    auth.nextAccount = const GoogleDriveAccount(id: 'account-b', name: 'Second listener');
    await expectLater(service.connect(), throwsA(isA<GoogleDriveException>()));
    expect(service.account!.id, 'account-b');
    expect(service.playlists, isEmpty);
  });

  test('advertised oversized response is rejected before JSON parsing', () async {
    final service = GoogleDriveService(
      auth: FakeDriveAuth(),
      clientFactory: () => MockClient(
        (request) async =>
            http.Response('small', 200, headers: {'content-length': '${DrivePlaylistCodec.maxBytes + 1}'}),
      ),
    );
    addTearDown(service.dispose);
    await expectLater(service.refresh(), throwsA(isA<GoogleDriveException>()));
  });
}
