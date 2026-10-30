import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/screens/google_drive/drive_music_screen.dart';
import 'package:resonance/services/google_drive/drive_music_models.dart';
import 'package:resonance/services/google_drive/drive_music_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'drive_music_service_test.dart' show MusicAuth, MusicDrive, jsonResponse;
import 'google_drive_ui_test.dart' show app;

const mixes = DriveMusicItem(id: 'mixes', name: 'Night drives', mimeType: driveFolderMime);
const library = DriveMusicItem(id: 'library', name: 'موسيقى عربية', mimeType: driveFolderMime);
const tracks = [
  DriveMusicItem(
    id: 'one',
    name: 'øneheart - snowfall.mp3',
    mimeType: 'audio/mpeg',
    parents: ['mixes'],
    bytes: 4219034,
  ),
  DriveMusicItem(id: 'two', name: 'HOME - Resonance.flac', mimeType: 'audio/flac', parents: ['mixes'], bytes: 29102938),
  DriveMusicItem(
    id: 'three',
    name: 'فيروز - نسم علينا الهوى.mp3',
    mimeType: 'audio/mpeg',
    parents: ['library'],
    bytes: 6439830,
  ),
];

class FixtureMusic extends DriveMusicService {
  FixtureMusic(MusicDrive drive) : super(drive: drive);
  int discoveryRequests = 0;
  final downloads = <String>[];
  @override
  Future<DriveMusicPage> discover({String? pageToken, String query = ''}) async {
    discoveryRequests++;
    return DriveMusicPage(tracks.where((e) => e.name.toLowerCase().contains(query.toLowerCase())).toList());
  }

  @override
  Future<DriveMusicPage> folder(String id, {String? pageToken, String query = ''}) async => DriveMusicPage(
    tracks.where((e) => e.parents.contains(id) && e.name.toLowerCase().contains(query.toLowerCase())).toList(),
  );
  @override
  Future<DriveMusicItem> metadata(String id) async => id == 'mixes' ? mixes : library;
  @override
  Future<void> cacheNames(Iterable<DriveMusicItem> items, {String artist = 'Google Drive'}) async {}
  @override
  Future<String> download(DriveMusicItem item, {int? playlistNumber}) async {
    downloads.add(item.id);
    return 'local.mp3';
  }
}

class UiDrive extends MusicDrive {
  UiDrive(this.user) : super(user, (_) async => jsonResponse({}));
  final MusicAuth user;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> enableMusicLibrary() async {
    await user.enableMusicLibrary();
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (await font.exists()) {
      await (FontLoader('DrivePreview')..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())))).load();
    }
    final icons = File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf');
    if (await icons.exists()) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(await icons.readAsBytes())))).load();
    }
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
  });
  for (final scenario in [(1120.0, const Locale('en')), (390.0, const Locale('en')), (390.0, const Locale('ar'))]) {
    testWidgets('Drive folder and track views at ${scenario.$1}/${scenario.$2.languageCode}', (tester) async {
      tester.view.physicalSize = Size(scenario.$1, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = MusicAuth();
      final drive = UiDrive(auth);
      final music = (await tester.runAsync(() async => FixtureMusic(drive)))!;
      final played = <String>[];
      addTearDown(music.dispose);
      addTearDown(drive.dispose);
      final capture = GlobalKey();
      await tester.pumpWidget(
        app(
          DriveMusicScreen(
            service: music,
            onPlay: (selected, queue) async {
              played.add(selected.id);
              expect(queue.map((e) => e.id), ['one', 'two']);
            },
          ),
          locale: scenario.$2,
          capture: capture,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(mixes.name), findsOneWidget);
      expect(find.text(library.name), findsOneWidget);
      expect(music.discoveryRequests, 1);
      expect(tester.takeException(), isNull);
      Future<void> screenshot(String view) async {
        if (Platform.environment['RESONANCE_CAPTURE_DRIVE_MUSIC'] != '1') return;
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = await Directory('build/drive-music-preview').create(recursive: true);
          await File(
            '${output.path}/${scenario.$1.toInt()}-${scenario.$2.languageCode}-$view.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await screenshot('folders');
      await tester.tap(find.text(mixes.name));
      await tester.pumpAndSettle();
      final strings = AppStrings(scenario.$2);
      expect(find.text(strings.text('Stream folder')), findsOneWidget);
      expect(find.text('HOME - Resonance'), findsOneWidget);
      if (scenario.$2.languageCode == 'ar') {
        expect(Directionality.of(tester.element(find.text(strings.text('Drive music')))), TextDirection.rtl);
      }
      await screenshot('tracks');
      await tester.tap(find.text('HOME - Resonance'));
      await tester.pumpAndSettle();
      expect(played, ['two']);
      await tester.tap(find.byTooltip(strings.text('Track options')).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.text('Download to library')));
      await tester.pumpAndSettle();
      expect(music.downloads, ['one']);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(library.name), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('existing music permission is optional and can be enabled explicitly', (tester) async {
    final auth = MusicAuth()..musicLibraryAccess = false;
    final drive = UiDrive(auth);
    final music = (await tester.runAsync(() async => FixtureMusic(drive)))!;
    addTearDown(music.dispose);
    addTearDown(drive.dispose);
    await tester.pumpWidget(app(DriveMusicScreen(service: music)));
    await tester.pumpAndSettle();
    expect(find.text('Browse existing music'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Browse existing music'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(auth.musicLibraryAccess, isTrue);
    expect(find.text('Browse existing music'), findsNothing);
  });
}
