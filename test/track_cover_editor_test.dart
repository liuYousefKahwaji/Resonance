import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:metadata_god/metadata_god.dart';
// The plugin's mock API reproduces its native append-only picture behavior.
// ignore: implementation_imports
import 'package:metadata_god/src/rust/frb_generated.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_range.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_artwork_service.dart';
import 'package:resonance/widgets/library/track_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late File track;
  final api = _AppendingMetadataApi();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await MetadataCacheService.reloadAfterRestore();
    RustLib.initMock(api: api);
  });
  late Uint8List original, chosen;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('resonance-cover-editor-');
    track = await File('${folder.path}/song.mp3').writeAsBytes([0, 1, 2]);
    Uint8List png(int red, int blue) {
      final picture = image.Image(width: 4, height: 4);
      image.fill(picture, color: image.ColorRgb8(red, 0, blue));
      return Uint8List.fromList(image.encodePng(picture));
    }

    original = png(255, 0);
    chosen = png(0, 255);
    api.picture = Picture(mimeType: 'image/png', data: original);
    api.writes = 0;
    api.title = 'Song';
    messenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    messenger.setMockMethodCallHandler(picker, (call) async {
      expect(call.method, 'image');
      return [
        {'name': 'chosen.png', 'path': null, 'bytes': chosen, 'size': chosen.length},
      ];
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(picker, null);

    await folder.delete(recursive: true);
  });

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 120; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
      if (ready()) return;
    }
    fail('Editor operation did not settle');
  }

  Future<void> flush(WidgetTester tester) async {
    var done = false;
    final pending = MetadataCacheService.flush().then((_) => done = true);
    await waitFor(tester, () => done);
    await pending;
  }

  Future<void> mount(WidgetTester tester, _Handler handler) async {
    await tester.pumpWidget(
      Provider<PlayerHandler>.value(
        value: handler,
        child: MaterialApp(
          home: Scaffold(
            body: TrackTile(
              trackPath: track.path,
              playlistNumber: 1,
              index: 0,
              allowReorder: false,
              onDelete: () {},
              onDeleteEverywhere: () {},
              metadataLoader: (_) async => const CachedTrackMetadata(title: 'Song', artist: 'Artist'),
            ),
          ),
        ),
      ),
    );
    await waitFor(tester, () => find.byTooltip('Track actions').evaluate().isNotEmpty);
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Track actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit metadata'));
    await waitFor(tester, () => find.text('Edit Metadata').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('Save'));
    await waitFor(tester, () => find.text('Edit Metadata').evaluate().isEmpty);
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester) async {
    await tester.tap(
      find.text('Change cover').evaluate().isEmpty ? find.text('Choose cover') : find.text('Change cover'),
    );
    await tester.pumpAndSettle();
  }

  Future<Uint8List?> resolved(WidgetTester tester) async => tester.runAsync<Uint8List?>(() async {
    final uri = await const TrackArtworkService().resolve(track.path, allowRemote: false);
    return uri == null ? null : File.fromUri(uri).readAsBytes();
  });

  testWidgets('manual cover replacement, removal and re-add survive reopening and text edits', (tester) async {
    final handler = _Handler();

    await mount(tester, handler);
    await open(tester);
    await pick(tester);
    await save(tester);
    expect(api.writes, 1);
    expect(api.picture.data, original, reason: 'The real plugin still reads the first embedded picture.');

    expect(await resolved(tester), chosen);

    await tester.pumpWidget(const SizedBox());
    // A new row/resolver uses the saved choice, not a transient preview.

    await mount(tester, handler);
    await open(tester);

    final preview = tester.widget<Image>(find.byType(Image).last).image as MemoryImage;
    expect(preview.bytes, chosen);
    await tester.ensureVisible(find.text('Restore original'));
    await tester.tap(find.text('Restore original'));
    await waitFor(tester, () {
      final preview = tester.widget<Image>(find.byType(Image).last).image;
      return preview is MemoryImage && listEquals(preview.bytes, original);
    });
    expect(await resolved(tester), chosen, reason: 'Restore is a preview until Save.');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await open(tester);
    await tester.ensureVisible(find.text('Restore original'));
    await tester.tap(find.text('Restore original'));
    await waitFor(
      tester,
      () => listEquals((tester.widget<Image>(find.byType(Image).last).image as MemoryImage).bytes, original),
    );
    await save(tester);
    expect(await resolved(tester), original);
    // Removing the original cover must stay removed when reopening the editor.
    await open(tester);
    await tester.ensureVisible(find.text('Remove cover'));
    await tester.tap(find.text('Remove cover'));
    await tester.pump();
    await save(tester);
    expect(await resolved(tester), isNull);
    await open(tester);
    expect(find.text('Choose cover'), findsOneWidget);
    expect(find.text('Remove cover'), findsNothing);
    final thirdCover = image.Image(width: 4, height: 4);
    image.fill(thirdCover, color: image.ColorRgb8(0, 255, 0));
    chosen = Uint8List.fromList(image.encodePng(thirdCover));
    await pick(tester);
    await save(tester);

    expect(await resolved(tester), chosen);

    // Text-only editing must preserve the manually chosen cover too.
    await open(tester);
    await tester.enterText(find.byType(TextField).first, 'Renamed');
    await save(tester);

    expect(await resolved(tester), chosen);

    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    await handler.dispose();
  });
}

class _AppendingMetadataApi extends RustLibApi {
  late Picture picture;
  int writes = 0;
  String title = 'Song';
  @override
  Future<void> crateApiApiInitApp() async {}
  @override
  Future<Metadata> crateApiApiReadMetadata({required String file}) async =>
      Metadata(title: title, artist: 'Artist', picture: picture);
  @override
  Future<void> crateApiApiWriteMetadata({required String file, required Metadata metadata}) async {
    writes++;
    title = metadata.title ?? title;
    // metadata_god appends a picture; its reader keeps returning the original.
  }
}

class _Handler extends Fake implements PlayerHandler {
  @override
  final playbackVisualNotifier = ValueNotifier(const PlaybackVisualState());
  @override
  final playbackModeRevision = ValueNotifier(0);
  @override
  final playbackRangeRevision = ValueNotifier(0);
  @override
  bool getShuffleMode() => false;
  @override
  Future<PlaybackRange> savedPlaybackRangeFor(String path) async => PlaybackRange.full;
  @override
  Future<T> withTrackFileReleased<T>(
    String path,
    Future<T> Function() action, {
    required String updatedTitle,
    required String updatedArtist,
  }) => action();
  @override
  Future<void> dispose() async {
    playbackVisualNotifier.dispose();
    playbackModeRevision.dispose();
    playbackRangeRevision.dispose();
  }
}
