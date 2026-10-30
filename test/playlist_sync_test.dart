import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/screens/settings/google_drive_playlists_screen.dart';
import 'package:resonance/services/google_drive/google_drive_auth.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';
import 'package:resonance/services/google_drive/google_drive_service.dart';
import 'package:resonance/services/google_drive/playlist_sync_document.dart';
import 'package:resonance/services/google_drive/playlist_sync_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/playlist_transfer_codec.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'google_drive_ui_test.dart' show app;

const a = 'aaaaaaaaaaa', b = 'bbbbbbbbbbb', c = 'ccccccccccc', d = 'ddddddddddd';
const initial = PlaylistTransferManifest(playlistName: 'Shared', youtubeVideoIds: [a, b, a]);
String url(String id) => TrackSourceRepository.canonicalUrlFor(id);
List<({String? entryId, String videoId})> retain(PlaylistSyncDocument doc) =>
    doc.active.map((entry) => (entryId: entry.id, videoId: entry.videoId)).toList();

class _Auth extends GoogleDriveAuth {
  @override
  GoogleDriveAccount? account = const GoogleDriveAccount(id: 'account', name: 'Listener');
  @override
  Future<void> restore() async {}
  @override
  Future<void> connect() async {}
  @override
  Future<String> accessToken({bool refresh = false}) async => 'mock';
  @override
  Future<void> logout() async {
    account = null;
  }
}

class _EmptyImportFiles extends FileService {
  int imports = 0;
  @override
  Future<({int number, String displayName})> createImportedPlaylist(String name, List<String> tracks) async {
    expect(tracks, isEmpty);
    imports++;
    return (number: 99, displayName: name);
  }
}

class _Cloud extends GoogleDriveService {
  _Cloud() : super(auth: _Auth());
  PlaylistTransferManifest content = initial;
  PlaylistSyncDocument? document;
  int revision = 0, writes = 0, reads = 0, bodies = 0, session = 0;
  bool offline = false, conflictOnce = false;
  GoogleDriveException? readFailure;
  Completer<void>? reading, release;
  @override
  int get sessionRevision => session;
  @override
  Future<void> initialize() async {}
  @override
  Future<DriveSyncSnapshot> openSnapshot(DrivePlaylist playlist) async => (await readForSync(playlist))!;
  @override
  Future<void> refresh() async {
    playlists = [DrivePlaylist(id: 'cloud-file', name: content.playlistName)];
    notifyListeners();
  }

  @override
  Future<DriveSyncSnapshot?> readForSync(DrivePlaylist playlist, {String? knownEtag}) async {
    reads++;
    if (readFailure != null) throw readFailure!;
    if (offline) throw const GoogleDriveException('Offline');
    reading?.complete();
    reading = null;
    await release?.future;
    if (knownEtag == '$revision') return null;
    bodies++;
    return DriveSyncSnapshot(manifest: content, etag: '$revision', document: document);
  }

  @override
  Future<DrivePlaylist> upload(
    PlaylistTransferManifest manifest, {
    DrivePlaylist? replace,
    PlaylistSyncDocument? sync,
    String? ifMatch,
  }) async {
    if (conflictOnce) {
      conflictOnce = false;
      document = document!.edit(device: 'other', tracks: [...retain(document!), (entryId: null, videoId: c)]);
      content = document!.manifest();
      revision++;
    }
    if (ifMatch != '$revision') throw const GoogleDriveException('Conflict', statusCode: 412);
    content = manifest;
    document = sync;
    revision++;
    writes++;
    return DrivePlaylist(id: 'cloud-file', name: manifest.playlistName);
  }

  void remote(PlaylistSyncDocument doc) {
    document = doc;
    content = doc.manifest();
    revision++;
  }

  @override
  Future<void> logout() async {
    session++;
    await super.logout();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final disposed = <PlaylistSyncService>{};
  void disposeSync(PlaylistSyncService service) {
    if (disposed.add(service)) service.dispose();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MetadataCacheService.flush();
    await MetadataCacheService.reloadAfterRestore();
  });

  test('merge converges across concurrent additions, moves, deletion and rename; duplicates survive', () {
    final seed = PlaylistSyncDocument.seed('file', initial);
    final left = seed.edit(
      device: 'phone',
      tracks: [retain(seed)[2], retain(seed)[0], (entryId: null, videoId: c)],
      renamed: 'Phone',
    );
    final right = seed.edit(
      device: 'windows',
      tracks: [...retain(seed), (entryId: null, videoId: d)],
      renamed: 'Desktop',
    );
    final merged = left.merge(right);
    expect(merged.fingerprint, right.merge(left).fingerprint);
    expect(merged.merge(left).fingerprint, merged.fingerprint);
    expect(merged.active.where((entry) => entry.videoId == a).length, 2);
    expect(merged.active.any((entry) => entry.videoId == b), isFalse);
    expect(merged.active.map((entry) => entry.videoId), containsAll([c, d]));
    expect(merged.name, 'Desktop');
    expect(merged.merge(seed).fingerprint, merged.fingerprint);
  });

  test('sync envelope retains original core, validates journal and supports an emptied playlist', () {
    final seed = PlaylistSyncDocument.seed('file', initial);
    final bytes = DrivePlaylistCodec.encode(initial, sync: seed);
    expect(DrivePlaylistCodec.decode(bytes).youtubeVideoIds, initial.youtubeVideoIds);
    expect(DrivePlaylistCodec.decodeSync(bytes)!.fingerprint, seed.fingerprint);
    final raw = jsonDecode(utf8.decode(bytes)) as Map;
    raw['sync']['name'] = 'tampered';
    expect(() => DrivePlaylistCodec.decode(utf8.encode(jsonEncode(raw))), throwsA(isA<GoogleDriveException>()));
    final empty = seed.edit(device: 'phone', tracks: []);
    expect(
      DrivePlaylistCodec.decode(DrivePlaylistCodec.encode(empty.manifest(), sync: empty)).youtubeVideoIds,
      isEmpty,
    );
    expect(() => DrivePlaylistCodec.encode(initial, sync: empty), throwsA(isA<GoogleDriveException>()));
  });

  Future<({Directory dir, FileService files, int number, _Cloud cloud, PlaylistSyncService sync})> fixture({
    List<String>? tracks,
    SyncDownload? download,
    PlaylistSyncMode mode = PlaylistSyncMode.stream,
  }) async {
    final dir = await Directory.systemTemp.createTemp('resonance-playlist-sync-');
    final files = FileService(documentsPathOverride: dir.path);
    final created = await files.createImportedPlaylist('Shared', tracks ?? initial.youtubeVideoIds.map(url).toList());
    final cloud = _Cloud();
    final sync = PlaylistSyncService(drive: cloud, files: files, download: download, debounce: const Duration(days: 1));
    await sync.start(polling: false);
    await sync.link(
      number: created.number,
      remote: const DrivePlaylist(id: 'cloud-file', name: 'Shared'),
      mode: mode,
    );
    addTearDown(() async {
      disposeSync(sync);
      cloud.dispose();
      await MetadataCacheService.flush();
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return (dir: dir, files: files, number: created.number, cloud: cloud, sync: sync);
  }

  test('initial link preserves order/duplicates and unchanged polls avoid downloading the document', () async {
    final f = await fixture();
    await f.sync.syncNow();
    expect(await f.files.readPlaylistTracks(f.number), initial.youtubeVideoIds.map(url));
    expect(f.cloud.document!.active.length, 3);
    await f.sync.syncNow(); // Learn the post-upload ETag.
    final bodies = f.cloud.bodies;
    await f.sync.syncNow();
    expect(f.cloud.bodies, bodies);
    expect(f.cloud.writes, 1);
    expect(f.sync.playlists.single.status, PlaylistSyncStatus.synced);
  });

  test('interrupted apply journal recovers occurrence IDs without duplicating newly received tracks', () async {
    final f = await fixture();
    await f.sync.syncNow();
    final received = f.cloud.document!.edit(
      device: 'other',
      tracks: [...retain(f.cloud.document!), (entryId: null, videoId: c)],
      renamed: 'Recovered name',
    );
    f.cloud.remote(received);
    final link = f.sync.playlists.single;
    link.pendingApply = {
      'document': received.toJson(),
      'expectedTracks': initial.youtubeVideoIds.map(url).toList(),
      'expectedName': 'Shared',
      'name': 'Recovered name',
      'tracks': received.active.map((entry) => url(entry.videoId)).toList(),
      'entries': received.active
          .map((entry) => LocalSyncEntry(entry.id, entry.videoId, url(entry.videoId)).toJson())
          .toList(),
    };
    final preferences = await SharedPreferences.getInstance();
    final saved = jsonDecode(preferences.getString(PlaylistSyncService.storageKey)!) as Map;
    saved['links'] = [link.toJson()];
    await preferences.setString(PlaylistSyncService.storageKey, jsonEncode(saved));
    await f.files.replacePlaylistTracks(f.number, received.active.map((entry) => url(entry.videoId)).toList());
    disposeSync(f.sync);
    final restored = PlaylistSyncService(drive: f.cloud, files: f.files, debounce: const Duration(days: 1));
    addTearDown(restored.dispose);
    await restored.start(polling: false);
    await restored.syncNow();
    expect(await f.files.readPlaylistTracks(f.number), received.active.map((entry) => url(entry.videoId)));
    expect(f.cloud.content.youtubeVideoIds.length, 4);
    expect(f.cloud.content.youtubeVideoIds.where((id) => id == c).length, 1);
    expect((await f.files.getPlaylistNames())[f.number], 'Recovered name');
  });

  test('partially downloaded imports never delete unseen cloud entries', () async {
    final f = await fixture(tracks: [url(a)]);
    await f.sync.syncNow();
    expect(f.cloud.document!.active.length, 3);
    expect(await f.files.readPlaylistTracks(f.number), initial.youtubeVideoIds.map(url));
  });

  test('offline changes persist through restart and merge remote additions without resurrecting deletions', () async {
    final f = await fixture();
    await f.sync.syncNow();
    final remote = f.cloud.document!.edit(
      device: 'other',
      tracks: [...retain(f.cloud.document!), (entryId: null, videoId: c)],
    );
    f.cloud.remote(remote);
    await f.files.replacePlaylistTracks(f.number, [url(a), url(a), url(d)]);
    await f.files.renamePlaylist(f.number, 'Renamed offline');
    f.cloud.offline = true;
    await f.sync.syncNow();
    expect(f.sync.playlists.single.status, PlaylistSyncStatus.attention);
    disposeSync(f.sync);
    f.cloud.offline = false;
    final restored = PlaylistSyncService(drive: f.cloud, files: f.files, debounce: const Duration(days: 1));
    addTearDown(restored.dispose);
    await restored.start(polling: false);
    await restored.syncNow();
    final tracks = await f.files.readPlaylistTracks(f.number);
    expect(tracks.where((track) => track == url(a)).length, 2);
    expect(tracks, containsAll([url(c), url(d)]));
    expect(tracks, isNot(contains(url(b))));
    expect(f.cloud.content.playlistName, 'Renamed offline');
    expect(f.cloud.content.youtubeVideoIds.length, 4);
  });

  test('optimistic write conflicts refetch and merge instead of losing another device addition', () async {
    final f = await fixture();
    await f.sync.syncNow();
    await f.files.appendTrack(f.number, url(d));
    f.cloud.conflictOnce = true;
    await f.sync.syncNow();
    expect(f.cloud.content.youtubeVideoIds, containsAll([a, b, c, d]));
    expect(f.cloud.content.youtubeVideoIds.length, 5);
    expect(f.sync.playlists.single.status, PlaylistSyncStatus.synced);
  });

  test('edits made during a cloud read survive and sync on the next pass', () async {
    final f = await fixture();
    await f.sync.syncNow();
    f.cloud.reading = Completer<void>();
    f.cloud.release = Completer<void>();
    final read = f.cloud.reading!.future;
    final work = f.sync.syncNow();
    await read;
    await f.files.appendTrack(f.number, url(c));
    f.cloud.release!.complete();
    f.cloud.release = null;
    await work;
    expect(await f.files.readPlaylistTracks(f.number), contains(url(c)));
    await f.sync.syncNow();
    expect(f.cloud.content.youtubeVideoIds, contains(c));
  });

  test('download mode queues missing audio once, keeps unmatched files and never deletes audio', () async {
    final queued = <YoutubeTrack>[];
    final f = await fixture(
      tracks: [url(a), '/local/unmatched.mp3'],
      mode: PlaylistSyncMode.download,
      download: (track, playlist) async {
        queued.add(track);
        return null;
      },
    );
    await f.sync.syncNow();
    await f.sync.syncNow();
    expect(queued.map((track) => TrackSourceRepository.videoIdFromUrlOrId(track.url)).toSet(), {a, b});
    expect(queued.length, 2);
    expect(await f.files.readPlaylistTracks(f.number), contains('/local/unmatched.mp3'));
    final audio = File('${f.dir.path}/kept.mp3');
    await audio.writeAsString('audio');
    f.cloud.remote(f.cloud.document!.edit(device: 'other', tracks: []));
    await f.sync.syncNow();
    expect(await f.files.readPlaylistTracks(f.number), ['/local/unmatched.mp3']);
    expect(await audio.exists(), isTrue);
  });

  test('new remote additions appear as streams while their automatic downloads are pending', () async {
    final completion = Completer<String?>();
    final queued = <String>[];
    final f = await fixture(
      mode: PlaylistSyncMode.download,
      download: (track, _) {
        final id = TrackSourceRepository.videoIdFromUrlOrId(track.url)!;
        queued.add(id);
        return id == c ? completion.future : Future.value(null);
      },
    );
    await f.sync.syncNow();
    f.cloud.remote(
      f.cloud.document!.edit(device: 'phone', tracks: [...retain(f.cloud.document!), (entryId: null, videoId: c)]),
    );
    await f.sync.syncNow();
    expect(await f.files.readPlaylistTracks(f.number), contains(url(c)));
    expect(queued.where((id) => id == c), hasLength(1));
    await f.sync.syncNow();
    expect(queued.where((id) => id == c), hasLength(1));
    completion.complete(null);
  });

  test('Download preference survives restart and missing downloads are queued again', () async {
    final f = await fixture(mode: PlaylistSyncMode.download, download: (_, __) async => null);
    await f.sync.syncNow();
    disposeSync(f.sync);
    final queued = <String>[];
    final restored = PlaylistSyncService(
      drive: f.cloud,
      files: f.files,
      debounce: const Duration(days: 1),
      download: (track, _) async {
        queued.add(track.url);
        return null;
      },
    );
    addTearDown(restored.dispose);
    await restored.start(polling: false);
    await restored.syncNow();
    expect(restored.playlists.single.mode, PlaylistSyncMode.download);
    expect(queued.toSet(), {url(a), url(b)});
    expect(await f.files.readPlaylistTracks(f.number), initial.youtubeVideoIds.map(url));
  });

  test('logout cancels in-flight local application and another account cannot see bindings', () async {
    final f = await fixture();
    await f.sync.syncNow();
    f.cloud.remote(f.cloud.document!.edit(device: 'other', tracks: [(entryId: null, videoId: c)]));
    f.cloud.reading = Completer<void>();
    f.cloud.release = Completer<void>();
    final read = f.cloud.reading!.future;
    final work = f.sync.syncNow();
    await read;
    await f.cloud.logout();
    f.cloud.release!.complete();
    f.cloud.release = null;
    await work;
    expect(await f.files.readPlaylistTracks(f.number), initial.youtubeVideoIds.map(url));
    expect(f.sync.playlists, isEmpty);
  });

  test('unlink preserves both copies and deleting primary carries the promoted binding', () async {
    final f = await fixture();
    await f.sync.syncNow();
    await f.files.deletePlaylist(1);
    expect(f.sync.playlists.single.number, 1);
    await f.sync.unlink(f.sync.playlists.single);
    expect(f.sync.playlists, isEmpty);
    expect(await f.files.readPlaylistTracks(1), initial.youtubeVideoIds.map(url));
    expect(f.cloud.content.youtubeVideoIds, initial.youtubeVideoIds);
  });

  test('explicit replacement waits for the worker and rebinds without duplicate additions', () async {
    final f = await fixture();
    await f.sync.syncNow();
    await f.files.appendTrack(f.number, url(c));
    f.cloud.reading = Completer<void>();
    f.cloud.release = Completer<void>();
    final began = f.cloud.reading!.future;
    final worker = f.sync.syncNow();
    await began;
    var acted = false;
    final replacement = f.sync.withPaused('cloud-file', () async {
      acted = true;
      final old = f.cloud.document!;
      f.cloud.remote(old.edit(device: 'manual-replace', tracks: [...retain(old), (entryId: null, videoId: c)]));
      await f.sync.link(
        number: f.number,
        remote: const DrivePlaylist(id: 'cloud-file', name: 'Shared'),
        mode: PlaylistSyncMode.stream,
      );
    });
    await Future<void>.delayed(Duration.zero);
    expect(acted, isFalse);
    f.cloud.release!.complete();
    f.cloud.release = null;
    await worker;
    await replacement;
    await f.sync.syncNow();
    expect(f.cloud.content.youtubeVideoIds.where((id) => id == c), hasLength(1));
    expect((await f.files.readPlaylistTracks(f.number)).where((path) => path == url(c)), hasLength(1));
  });

  test('cloud deletion stops syncing without deleting the local playlist or tracks', () async {
    final f = await fixture();
    await f.sync.syncNow();
    f.cloud.readFailure = const GoogleDriveException('Gone', statusCode: 404);
    await f.sync.syncNow();
    expect(f.sync.playlists, isEmpty);
    expect(await f.files.readPlaylistTracks(f.number), initial.youtubeVideoIds.map(url));
  });

  testWidgets('empty cloud playlist asks before adding and keeps sync off by default', (tester) async {
    final f = (await tester.runAsync(() => fixture(download: (_, __) async => null)))!;
    await tester.runAsync(() => f.sync.unlink(f.sync.playlists.single));
    f.cloud.remote(PlaylistSyncDocument.seed('cloud-file', initial).edit(device: 'other', tracks: []));
    final imports = _EmptyImportFiles();
    await tester.pumpWidget(app(GoogleDrivePlaylistsScreen(service: f.cloud, sync: f.sync, files: imports)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-file')));
    await tester.pumpAndSettle();
    expect(find.text('This playlist is empty.'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    await tester.runAsync(() async {
      await tester.tap(find.text('Add playlist'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty && find.byType(AlertDialog).evaluate().isEmpty) break;
    }
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    expect(imports.imports, 1);
    expect(f.sync.playlists, isEmpty);
    expect(tester.takeException(), isNull);
    disposeSync(f.sync);
  });

  for (final scenario in [(840.0, const Locale('en')), (360.0, const Locale('en')), (360.0, const Locale('ar'))]) {
    testWidgets('sync options work at ${scenario.$1}/${scenario.$2} without replacing the playlist', (tester) async {
      tester.view.physicalSize = Size(scenario.$1, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = Platform.environment['RESONANCE_CAPTURE_SYNC_PREVIEWS'] == '1';
      if (capture) {
        await tester.runAsync(() async {
          final font = FontLoader('DrivePreview')
            ..addFont(File('C:/Windows/Fonts/segoeui.ttf').readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
          await font.load();
          final icons = FontLoader('MaterialIcons')
            ..addFont(
              File(
                'C:/Users/kahwa/Documents/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            );
          await icons.load();
        });
      }
      final f = (await tester.runAsync(() => fixture(download: (_, __) async => null)))!;
      await tester.runAsync(f.sync.syncNow);
      final key = GlobalKey();
      await tester.pumpWidget(
        app(
          GoogleDrivePlaylistsScreen(service: f.cloud, sync: f.sync),
          locale: scenario.$2,
          capture: key,
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cloud-file')));
      await tester.pumpAndSettle();
      final strings = AppStrings(scenario.$2);
      expect(find.text(strings.text('Keep in sync')), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
      if (scenario.$2.languageCode == 'ar') {
        expect(Directionality.of(tester.element(find.text(strings.text('Keep in sync')))), TextDirection.rtl);
      }
      await tester.tap(find.text(strings.text('Download')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      expect(f.sync.playlists.single.mode, PlaylistSyncMode.download);
      expect(
        tester.widget<SegmentedButton<PlaylistSyncMode>>(find.byType(SegmentedButton<PlaylistSyncMode>)).selected,
        {PlaylistSyncMode.download},
      );
      if (capture) {
        await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/sync-preview').create(recursive: true);
          await File(
            'build/sync-preview/${scenario.$1.toInt()}-${scenario.$2.languageCode}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(f.sync.playlists, isEmpty);
      expect(f.cloud.content.youtubeVideoIds, initial.youtubeVideoIds);
      expect(tester.takeException(), isNull);
      disposeSync(f.sync);
    });
  }
}
