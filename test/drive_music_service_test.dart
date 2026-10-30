import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/google_drive/drive_music_models.dart';
import 'package:resonance/services/google_drive/drive_music_service.dart';
import 'package:resonance/services/google_drive/google_drive_auth.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';
import 'package:resonance/services/google_drive/google_drive_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MusicAuth extends GoogleDriveAuth {
  @override
  GoogleDriveAccount? account = const GoogleDriveAccount(id: 'listener', name: 'Listener');
  @override
  bool musicLibraryAccess = true;
  @override
  Future<void> enableMusicLibrary() async {
    musicLibraryAccess = true;
  }

  @override
  Future<void> restore() async {}
  @override
  Future<void> connect() async {}
  @override
  Future<void> logout() async {
    account = null;
    musicLibraryAccess = false;
  }

  @override
  Future<String> accessToken({bool refresh = false}) async => refresh ? 'renewed-private-token' : 'private-token';
}

typedef Handler = Future<http.StreamedResponse> Function(http.BaseRequest request);

class RestoringMusicAuth extends MusicAuth {
  RestoringMusicAuth() {
    account = null;
  }
  @override
  Future<void> restore() async {
    account = const GoogleDriveAccount(id: 'listener', name: 'Listener');
  }
}

class MusicClient extends http.BaseClient {
  MusicClient(this.handler);
  final Handler handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
}

class MusicDrive extends GoogleDriveService {
  MusicDrive(MusicAuth auth, Handler handler) : super(auth: auth, clientFactory: () => MusicClient(handler));
  @override
  Future<String> musicUploadRoot() async => 'resonance-root';
}

http.StreamedResponse jsonResponse(Object data, [int code = 200, Map<String, String>? headers]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(data))),
      code,
      headers: {'content-type': 'application/json', ...?headers},
    );

Map<String, dynamic> audioJson(List<int> bytes, {String id = 'track-a', String name = 'Night Drive.mp3'}) => {
  'id': id,
  'name': name,
  'mimeType': 'audio/mpeg',
  'parents': ['music-folder'],
  'size': '${bytes.length}',
  'md5Checksum': md5.convert(bytes).toString(),
  'modifiedTime': '2026-10-30T00:00:00Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FileService files;
  late MusicAuth auth;
  final services = <DriveMusicService>[];
  final drives = <GoogleDriveService>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('resonance-drive-audio-');
    files = FileService(documentsPathOverride: directory.path);
    auth = MusicAuth();
    await files.createImportedPlaylist('Local', []);
  });
  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    for (final drive in drives) {
      drive.dispose();
    }
    drives.clear();
    await MetadataCacheService.flush();
    await directory.delete(recursive: true);
  });
  DriveMusicService service(Handler handler) {
    final drive = MusicDrive(auth, handler);
    drives.add(drive);
    final result = DriveMusicService(drive: drive, files: files, downloadDirectory: () async => directory);
    services.add(result);
    return result;
  }

  test('discovery is paginated, escapes search and ignores unsupported files', () async {
    final music = service((request) async {
      expect(request.headers['Authorization'], 'Bearer private-token');
      expect(request.url.queryParameters['q'], contains("name contains 'l\\'amour'"));
      expect(request.url.queryParameters['pageToken'], 'next');
      return jsonResponse({
        'files': [
          audioJson([1]),
          {'id': 'image', 'name': 'Cover.jpg', 'mimeType': 'image/jpeg'},
        ],
        'nextPageToken': 'later',
      });
    });
    final page = await music.discover(query: "l'amour", pageToken: 'next');
    expect(page.items.single.id, 'track-a');
    expect(page.nextPageToken, 'later');
  });

  test('a restored Drive reference waits for the saved account to load', () async {
    auth = RestoringMusicAuth();
    final music = service((_) async => throw StateError('No HTTP extraction needed'));
    final stream = await music.resolve(const DriveMusicRef('listener', 'track-a').url);
    expect(stream.headers['Authorization'], 'Bearer private-token');
    expect(auth.account?.id, 'listener');
  });

  test('private playback resolves fresh authorization without persisting a bearer token', () async {
    final music = service((_) async => throw StateError('No network call is needed for playback headers'));
    const item = DriveMusicItem(id: 'track-a', name: 'Song.mp3', mimeType: 'audio/mpeg');
    final number = await music.addStreams([item], 'Cloud');
    final urls = await files.readPlaylistTracks(number);
    expect(urls.single, item.streamUrl('listener'));
    expect(urls.single, isNot(contains('token')));
    final stream = await music.resolve(urls.single);
    expect(stream.headers['Authorization'], 'Bearer private-token');
    expect(stream.uri.queryParameters, {'alt': 'media'});
    auth.account = const GoogleDriveAccount(id: 'another-account', name: 'Other');
    await expectLater(music.resolve(urls.single), throwsA(isA<GoogleDriveException>()));
  });

  test('an interrupted download resumes with Range and replaces surviving stream occurrences', () async {
    final bytes = List<int>.generate(40, (i) => i);
    final item = DriveMusicItem.fromJson(audioJson(bytes));
    var requests = 0;
    final music = service((request) async {
      if (request.url.queryParameters['alt'] != 'media') return jsonResponse(audioJson(bytes));
      if (++requests == 1) {
        Stream<List<int>> interrupted() async* {
          yield bytes.sublist(0, 12);
          throw const SocketException('fixture interruption');
        }

        return http.StreamedResponse(interrupted(), 200, contentLength: bytes.length);
      }
      expect(request.headers['Range'], 'bytes=12-');
      return http.StreamedResponse(
        Stream.value(bytes.sublist(12)),
        206,
        contentLength: 28,
        headers: {'content-range': 'bytes 12-39/40'},
      );
    });
    final number = await music.addStreams([item, item], 'Cloud');
    final path = await music.download(item, playlistNumber: number);
    expect(await File(path).readAsBytes(), bytes);
    expect(await files.readPlaylistTracks(number), [path, path]);
    expect(music.transfers.single.state, DriveMusicTransferState.complete);
    expect(requests, 2);
  });

  test('an incorrect range cannot append corrupt audio to an existing partial download', () async {
    final bytes = List<int>.generate(20, (i) => i);
    var requests = 0;
    final music = service((request) async {
      if (request.url.queryParameters['alt'] != 'media') return jsonResponse(audioJson(bytes));
      if (++requests == 1) {
        Stream<List<int>> interrupted() async* {
          yield bytes.sublist(0, 5);
          throw const SocketException('interrupted');
        }

        return http.StreamedResponse(interrupted(), 200);
      }
      return http.StreamedResponse(Stream.value(bytes.sublist(5)), 206, headers: {'content-range': 'bytes 1-15/20'});
    });
    final number = await music.addStreams([DriveMusicItem.fromJson(audioJson(bytes))], 'Cloud');
    await expectLater(
      music.download(DriveMusicItem.fromJson(audioJson(bytes)), playlistNumber: number),
      throwsA(isA<GoogleDriveException>()),
    );
    expect(await files.readPlaylistTracks(number), [DriveMusicRef('listener', 'track-a').url]);
    expect(music.transfers.single.state, DriveMusicTransferState.failed);
  });

  test('upload recovers an acknowledged chunk after a lost response and verifies final bytes', () async {
    final bytes = Uint8List(1024 * 1024 + 17);
    bytes[0] = 42;
    bytes.last = 8;
    final file = await File('${directory.path}/Song.mp3').writeAsBytes(bytes);
    final sent = <int>[];
    var queries = 0, writes = 0;
    final music = service((request) async {
      if (request.method == 'GET' && request.url.path.endsWith('/files')) {
        if (request.url.queryParameters['q']!.contains('resonanceAudio')) {
          return jsonResponse({
            'files': [
              {'id': 'audio-folder'},
            ],
          });
        }
        return jsonResponse({'files': []});
      }
      if (request.method == 'POST') {
        final metadata = jsonDecode(utf8.decode(await request.finalize().toBytes())) as Map;
        expect(metadata['parents'], ['audio-folder']);
        return http.StreamedResponse(
          const Stream.empty(),
          200,
          headers: {'location': 'https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture'},
        );
      }
      expect(request.method, 'PUT');
      if (request.headers['Content-Range'] == 'bytes */${bytes.length}') {
        queries++;
        return http.StreamedResponse(const Stream.empty(), 308, headers: {'range': 'bytes=0-${sent.length - 1}'});
      }
      writes++;
      sent.addAll(await request.finalize().toBytes());
      if (writes == 1) throw const SocketException('response lost after server accepted bytes');
      return jsonResponse(audioJson(bytes, name: 'Song.mp3'));
    });
    final uploaded = await music.upload(file.path);
    expect(uploaded.md5, md5.convert(bytes).toString());
    expect(sent, bytes);
    expect(queries, 1);
    expect(writes, 2);
    expect(await file.readAsBytes(), bytes);
    expect(music.transfers.single.progress, 1);
  });

  test('identical existing audio is reused without another upload', () async {
    final bytes = [1, 2, 3];
    final file = await File('${directory.path}/Song.mp3').writeAsBytes(bytes);
    final music = service((request) async {
      expect(request.method, 'GET');
      return request.url.queryParameters['q']!.contains('resonanceAudio')
          ? jsonResponse({
              'files': [
                {'id': 'audio-folder'},
              ],
            })
          : jsonResponse({
              'files': [audioJson(bytes, name: 'Song.mp3')],
            });
    });
    expect((await music.upload(file.path)).id, 'track-a');
    expect(music.transfers.single.state, DriveMusicTransferState.complete);
  });

  test('upload cannot forward authorization to an unexpected resumable URL', () async {
    final file = await File('${directory.path}/Song.mp3').writeAsBytes([1, 2, 3]);
    final music = service((request) async {
      if (request.method == 'GET') {
        return request.url.queryParameters['q']!.contains('resonanceAudio')
            ? jsonResponse({
                'files': [
                  {'id': 'audio-folder'},
                ],
              })
            : jsonResponse({'files': []});
      }
      expect(request.method, 'POST');
      return http.StreamedResponse(
        const Stream.empty(),
        200,
        headers: {'location': 'https://untrusted.example/upload'},
      );
    });
    await expectLater(music.upload(file.path), throwsA(isA<GoogleDriveException>()));
  });

  test('account logout interrupts a download before it can change a local playlist', () async {
    final bytes = [1, 2, 3, 4];
    final paused = Completer<void>(), release = Completer<void>();
    final music = service((request) async {
      if (request.url.queryParameters['alt'] != 'media') return jsonResponse(audioJson(bytes));
      Stream<List<int>> body() async* {
        yield [1, 2];
        paused.complete();
        await release.future;
        yield [3, 4];
      }

      return http.StreamedResponse(body(), 200, contentLength: 4);
    });
    final item = DriveMusicItem.fromJson(audioJson(bytes));
    final number = await music.addStreams([item], 'Cloud');
    final download = music.download(item, playlistNumber: number);
    final failure = expectLater(download, throwsA(isA<GoogleDriveCancelled>()));
    await paused.future;
    await music.drive.logout();
    release.complete();
    await failure;
    expect(await files.readPlaylistTracks(number), [item.streamUrl('listener')]);
  });
}
