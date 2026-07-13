import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('source mapping saves and looks up by track and YouTube ID', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-source-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}song.mp3');
    await file.writeAsString('audio');
    const repository = TrackSourceRepository();

    await repository.saveSource(
      localPath: file.path,
      youtubeVideoId: 'aaaaaaaaaaa',
      method: TrackSourceMethod.downloadedByResonance,
    );

    expect((await repository.getSourceForTrack(file.path))?.youtubeVideoId, 'aaaaaaaaaaa');
    expect(await repository.findLocalTrackByYoutubeId('aaaaaaaaaaa'), file.path);
  });

  test('existing mapping with missing local file needs redownload', () async {
    SharedPreferences.setMockInitialValues({});
    const repository = TrackSourceRepository();
    final missing = '${Directory.systemTemp.path}${Platform.pathSeparator}missing-resonance-track.mp3';
    await repository.saveSource(
      localPath: missing,
      youtubeVideoId: 'bbbbbbbbbbb',
      method: TrackSourceMethod.importedFromQrTransfer,
    );

    expect(await repository.findLocalTrackByYoutubeId('bbbbbbbbbbb'), isNull);
    expect((await repository.getSourceForYoutubeId('bbbbbbbbbbb'))?.localPath, missing);
  });

  test('saving a redownload updates stale local path without duplicate records', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('resonance-source-update-');
    addTearDown(() => directory.delete(recursive: true));
    final oldPath = '${directory.path}${Platform.pathSeparator}old.mp3';
    final newFile = File('${directory.path}${Platform.pathSeparator}new.mp3');
    await newFile.writeAsString('audio');
    const repository = TrackSourceRepository();
    await repository.saveSource(
      localPath: oldPath,
      youtubeVideoId: 'ccccccccccc',
      method: TrackSourceMethod.downloadedByResonance,
    );
    await repository.saveSource(
      localPath: newFile.path,
      youtubeVideoId: 'ccccccccccc',
      method: TrackSourceMethod.importedFromQrTransfer,
    );

    expect(await repository.getSourceForTrack(oldPath), isNull);
    expect(await repository.findLocalTrackByYoutubeId('ccccccccccc'), newFile.path);
  });

  test('source references can be removed when a track is permanently deleted', () async {
    SharedPreferences.setMockInitialValues({});
    const repository = TrackSourceRepository(isWindowsOverride: true);
    const path = r'C:\Music\Delete Me.mp3';
    await repository.saveSource(
      localPath: path,
      youtubeVideoId: 'aaaaaaaaaaa',
      method: TrackSourceMethod.downloadedByResonance,
    );

    await repository.removeSourceForTrack(r'c:\music\DELETE ME.mp3');

    expect(await repository.getSourceForTrack(path), isNull);
    expect(await repository.getSourceForYoutubeId('aaaaaaaaaaa'), isNull);
  });

  test('YouTube URL parser accepts canonical variants and rejects other hosts', () {
    expect(TrackSourceRepository.videoIdFromUrlOrId('aaaaaaaaaaa'), 'aaaaaaaaaaa');
    expect(TrackSourceRepository.videoIdFromUrlOrId('https://youtu.be/aaaaaaaaaaa?t=2'), 'aaaaaaaaaaa');
    expect(TrackSourceRepository.videoIdFromUrlOrId('https://music.youtube.com/watch?v=aaaaaaaaaaa'), 'aaaaaaaaaaa');
    expect(TrackSourceRepository.videoIdFromUrlOrId('https://example.com/watch?v=aaaaaaaaaaa'), isNull);
  });
}
