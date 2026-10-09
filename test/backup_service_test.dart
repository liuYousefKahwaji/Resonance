import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/services/backup_service.dart';
import 'package:resonance/services/track_source_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FileService files;
  late BackupService backups;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('resonance-backup-test-');
    files = FileService(documentsPathOverride: directory.path);
    backups = BackupService(files: files, supportDirectory: directory.path);
  });
  tearDown(() => directory.delete(recursive: true));
  String archivePath(String name) => p.join(directory.path, '$name.zip');
  test('settings export excludes sessions and keeps the current library during restore', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_style', 'aurum');
    await prefs.setString('app_language', 'ar');
    await prefs.setString('youtube_windows_browser', 'firefox:private');
    await prefs.setString('companion_pairing', 'secret');
    await files.replacePlaylistTracks(2, ['untouched.mp3']);
    await files.setActivePlaylistNumber(2);
    final preview = await backups.previewExport(BackupMode.settings, includeAudio: true);
    expect(preview.playlistCount, 0);
    expect(preview.audioCount, 0);
    expect((preview.manifest['settings'] as Map).keys, containsAll(['theme_style', 'app_language']));
    expect(
      (preview.manifest['settings'] as Map).keys.any((key) => '$key'.contains('youtube') || '$key'.contains('pairing')),
      isFalse,
    );
    await backups.export(archivePath('settings'), preview);
    await prefs.setString('theme_style', 'quartz');
    await backups.restore(archivePath('settings'), replace: true);
    expect(prefs.getString('theme_style'), 'aurum');
    expect(await files.getActivePlaylistNumber(), 2);
    expect(await files.readPlaylistTracks(2), ['untouched.mp3']);
    expect(prefs.getString('companion_pairing'), 'secret');
  });
  test('complete audio restore relinks metadata, source identity and sort history without duplicate copies', () async {
    final a = await File(p.join(directory.path, 'a.mp3')).writeAsString('audio a');
    final b = await File(p.join(directory.path, 'b.mp3')).writeAsString('audio b larger');
    await const TrackSourceRepository().saveSource(
      localPath: a.path,
      youtubeVideoId: 'abcdefghijk',
      method: TrackSourceMethod.downloadedByResonance,
    );
    await files.replacePlaylistTracks(1, [a.path, b.path, a.path]);
    await files.renamePlaylist(1, 'My mix');
    await files.setTracksFavorite([a.path], true);
    await files.sortPlaylist(1, PlaylistSortMode.random);
    final before = await files.readPlaylistTracks(1);
    final sort = await files.playlistSortState(1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('long_track_positions_v1', jsonEncode({'file:${a.path.toLowerCase()}': 123000}));
    final preview = await backups.previewExport(BackupMode.everything, includeAudio: true);
    expect(preview.audioCount, 2);
    expect(preview.unresolved, 0);
    await backups.export(archivePath('complete'), preview);
    await a.delete();
    await b.delete();
    await backups.restore(archivePath('complete'), replace: true);
    final restored = await files.readPlaylistTracks(1);
    final mapping = <String, String>{};
    for (var i = 0; i < before.length; i++) {
      mapping[before[i]] = restored[i];
      expect(await File(restored[i]).exists(), isTrue);
    }
    expect((await files.playlistSortState(1)).seed, sort.seed);
    expect((await files.playlistSortState(1)).addedOrder, sort.addedOrder.map((path) => mapping[path]).toList());
    expect(await files.readPlaylistTracks(0), [mapping[a.path]]);
    expect((await const TrackSourceRepository().getSourceForTrack(mapping[a.path]!))!.youtubeVideoId, 'abcdefghijk');
    expect(
      jsonDecode(prefs.getString('long_track_positions_v1')!),
      containsPair('file:${mapping[a.path]!.toLowerCase()}', 123000),
    );
    final hashes = await Future.wait(
      restored.map((path) async => (await sha256.bind(File(path).openRead()).first).toString()),
    );
    expect(hashes.toSet().length, 2);
    await backups.restore(archivePath('complete'), replace: false);
    expect(await files.listPlaylistNumbers(), [0, 1]);
    final audio = Directory(
      p.join(directory.path, 'RestoredAudio'),
    ).listSync(recursive: true).whereType<File>().toList();
    expect(audio.length, 2);
  });
  test('references-only backup can relink a uniquely named moved file', () async {
    const old = r'C:\Old Computer\music\song.mp3';
    await files.replacePlaylistTracks(1, [old]);
    final preview = await backups.previewExport(BackupMode.everything);
    expect(preview.unresolved, 1);
    await backups.export(archivePath('references'), preview);
    final folder = await Directory(p.join(directory.path, 'new')).create();
    final relocated = await File(p.join(folder.path, 'song.mp3')).writeAsString('audio');
    await backups.restore(archivePath('references'), replace: true, relinkFolder: folder.path);
    expect(await files.readPlaylistTracks(1), [relocated.path]);
  });
  test('corrupt audio and unsafe entries cannot replace existing playlists', () async {
    await files.replacePlaylistTracks(1, ['original.mp3']);
    final manifest = (await backups.previewExport(BackupMode.everything)).manifest;
    void writeZip(String name, String extra, List<int> bytes, {bool audio = false}) {
      final data = jsonDecode(jsonEncode(manifest)) as Map<String, dynamic>;
      if (audio) {
        data['audio'] = [
          {'path': 'new.mp3', 'entry': extra, 'size': bytes.length, 'sha256': '0' * 64},
        ];
      }
      final json = utf8.encode(jsonEncode(data));
      final archive = Archive()
        ..addFile(ArchiveFile('manifest.json', json.length, json))
        ..addFile(ArchiveFile(extra, bytes.length, bytes));
      File(archivePath(name)).writeAsBytesSync(ZipEncoder().encode(archive));
    }

    writeZip('unsafe', '../outside.mp3', [1]);
    expect(() => backups.inspect(archivePath('unsafe')), throwsFormatException);
    writeZip('corrupt', 'audio/0.mp3', [1, 2], audio: true);
    await expectLater(backups.restore(archivePath('corrupt'), replace: true), throwsFormatException);
    expect(await files.readPlaylistTracks(1), ['original.mp3']);
  });
  test('mid-restore failure restores every playlist file and preferences', () async {
    await files.replacePlaylistTracks(1, ['first.mp3']);
    await files.renamePlaylist(1, 'Before');
    await files.replacePlaylistTracks(2, ['second.mp3']);
    await files.setActivePlaylistNumber(2);
    final preview = await backups.previewExport(BackupMode.everything);
    await backups.export(archivePath('rollback'), preview);
    final before = {
      for (final entry in directory.listSync().whereType<File>().where(
        (file) => p.basename(file.path).startsWith('r_playlist_'),
      ))
        entry.path: entry.readAsBytesSync(),
    };
    final failing = BackupService(files: _FailingFiles(directory.path), supportDirectory: directory.path);
    await expectLater(failing.restore(archivePath('rollback'), replace: true), throwsStateError);
    for (final entry in before.entries) {
      expect(await File(entry.key).readAsBytes(), entry.value);
    }
    expect((await files.getPlaylistNames())[1], 'Before');
    expect(await files.getActivePlaylistNumber(), 2);
  });
}

class _FailingFiles extends FileService {
  _FailingFiles(String directory) : super(documentsPathOverride: directory);
  @override
  Future<void> renamePlaylist(int number, String name) async {
    throw StateError('Simulated storage failure');
  }
}
