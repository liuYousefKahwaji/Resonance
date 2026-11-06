import 'package:image/image.dart' as img;
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/track_artwork_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File track;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MetadataCacheService.reloadAfterRestore();
    root = await Directory.systemTemp.createTemp('resonance-artwork-');
    track = File('${root.path}/original.webm');
    await track.writeAsBytes([0, 1, 2]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => root.path,
    );
  });
  tearDown(() async {
    await MetadataCacheService.flush();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });
  test('Original downloads use saved artwork even without embedded metadata', () async {
    await MetadataCacheService.set(track.path, 'Song', 'Artist', artworkUrl: 'https://example.com/art.jpg');
    final resolver = TrackArtworkService(readEmbedded: (_) async => null);
    expect((await resolver.resolve(track.path)).toString(), 'https://example.com/art.jpg');
    expect(await resolver.resolve(track.path, allowRemote: false), isNull);
  });
  test('source mapping recovers cover after metadata cache invalidation', () async {
    await const TrackSourceRepository().saveSource(
      localPath: track.path,
      youtubeVideoId: 'abcdefghijk',
      method: TrackSourceMethod.downloadedByResonance,
    );
    final resolver = TrackArtworkService(readEmbedded: (_) async => throw UnsupportedError('No WebM tags'));
    expect((await resolver.resolve(track.path)).toString(), TrackSourceRepository.thumbnailUrlFor('abcdefghijk'));
  });
  test('same-path embedded edits get new image keys and explicit removal stays removed', () async {
    var image = Uint8List.fromList([1, 2, 3]);
    final resolver = TrackArtworkService(directory: Directory('${root.path}/covers'), readEmbedded: (_) async => image);
    final first = await resolver.resolve(track.path);
    image = Uint8List.fromList([4, 5, 6]);
    await resolver.embeddedChanged(track.path);
    final second = await resolver.resolve(track.path);
    expect(first, isNot(second));
    expect(await File.fromUri(second!).readAsBytes(), image);
    await MetadataCacheService.set(track.path, 'Song', 'Artist', artworkUrl: 'https://example.com/stale.jpg');
    await resolver.embeddedChanged(track.path, removed: true);
    expect(await resolver.resolve(track.path), isNull);
  });
  test('cover repair persists without modifying unsupported audio containers', () async {
    final original = await track.readAsBytes();
    final events = <String>[];
    final subscription = TrackArtworkService.changes.listen(events.add);
    addTearDown(subscription.cancel);
    final resolver = TrackArtworkService(directory: Directory('${root.path}/covers'), readEmbedded: (_) async => null);
    final image = Uint8List.fromList([9, 8, 7]);
    await resolver.saveCover(track.path, image);
    final restarted = TrackArtworkService(readEmbedded: (_) async => throw StateError('Must use persisted cover'));
    final uri = await restarted.resolve(track.path, allowRemote: false);
    expect(await File.fromUri(uri!).readAsBytes(), image);
    expect(await track.readAsBytes(), original);
    expect(events, [track.path]);
  });
  test('late embedded reads cannot replace a newer cover repair', () async {
    final pending = Completer<Uint8List?>();
    final started = Completer<void>();
    final resolver = TrackArtworkService(
      directory: Directory('${root.path}/covers'),
      readEmbedded: (_) {
        started.complete();
        return pending.future;
      },
    );
    final old = resolver.resolve(track.path);
    await started.future;
    await resolver.saveCover(track.path, Uint8List.fromList([8, 8, 8]));
    pending.complete(Uint8List.fromList([1, 1, 1]));
    expect(await old, await resolver.resolve(track.path));
  });
  test('repair falls back from corrupt cached art to the exact mapped video, without search', () async {
    await MetadataCacheService.set(track.path, 'Song', 'Artist', artworkUrl: 'https://example.com/broken.jpg');
    await const TrackSourceRepository().saveSource(
      localPath: track.path,
      youtubeVideoId: 'abcdefghijk',
      method: TrackSourceMethod.downloadedByResonance,
    );
    final resolver = TrackArtworkService(directory: Directory('${root.path}/covers'), readEmbedded: (_) async => null);
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
    final requested = <String>[];
    final result = await resolver.fillMissingCover(
      track.path,
      download: (url) async {
        requested.add(url);
        return requested.length == 1 ? Uint8List.fromList([0, 1, 2]) : png;
      },
      lookup: () async => throw StateError('Mapped video needs no search'),
    );
    expect(result, CoverRepairResult.updated);
    expect(requested, ['https://example.com/broken.jpg', TrackSourceRepository.thumbnailUrlFor('abcdefghijk')]);
    expect(await File.fromUri((await resolver.resolve(track.path))!).readAsBytes(), png);
    expect(await track.readAsBytes(), [0, 1, 2]);
    expect(
      await resolver.fillMissingCover(
        track.path,
        download: (_) async => throw StateError('Already repaired'),
        lookup: () async => throw StateError('Already repaired'),
      ),
      CoverRepairResult.unchanged,
    );
  });
  test('repair searches only when no known thumbnail works', () async {
    final resolver = TrackArtworkService(directory: Directory('${root.path}/covers'), readEmbedded: (_) async => null);
    var searches = 0;
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
    expect(
      await resolver.fillMissingCover(
        track.path,
        download: (_) async => png,
        lookup: () async {
          searches++;
          return 'https://example.com/found.png';
        },
      ),
      CoverRepairResult.updated,
    );
    expect(searches, 1);
  });
}
