import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/screens/settings/google_drive_playlists_screen.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';
import 'package:resonance/services/google_drive/google_drive_service.dart';
import 'package:resonance/widgets/settings/google_drive_settings_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'google_drive_test.dart' show FakeDriveAuth, jsonResponse, remoteFile, manifest;
import 'google_drive_reliability_test.dart' show NoHeaderDrive;
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/google_drive/playlist_sync_service.dart';

class _Library extends FileService {
  final tracks = ['https://www.youtube.com/watch?v=bbbbbbbbbbb', 'https://www.youtube.com/watch?v=ccccccccccc'];
  @override
  Future<Map<int, String>> getPlaylistNames() async => {2: 'Local mix'};
  @override
  Future<List<String>> readPlaylistTracks(int number) async => tracks.toList();
}

class _UiSync extends PlaylistSyncService {
  _UiSync(GoogleDriveService drive, FileService files)
    : super(drive: drive, files: files, debounce: const Duration(days: 1));
  @override
  Future<void> syncNow() async {} // These tests exercise explicit UI actions.
}

Widget app(Widget child, {Locale locale = const Locale('en'), GlobalKey? capture}) {
  final theme = buildResonanceTheme(ResonanceThemeStyle.obsidian, Brightness.dark);
  return RepaintBoundary(
    key: capture,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [AppStrings.delegate, ...GlobalMaterialLocalizations.delegates],
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'DrivePreview'),
        appBarTheme: theme.appBarTheme.copyWith(
          titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'DrivePreview'),
        ),
      ),
      home: child,
    ),
  );
}

void main() {
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 60 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    }
    await tester.pump();
    expect(ready(), isTrue);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({'download_directory': 'Test downloads'});
    await SharedPreferences.getInstance();
  });

  setUpAll(() async {
    if (Platform.environment['RESONANCE_CAPTURE_DRIVE_PREVIEWS'] == '1') {
      final file = File('C:/Windows/Fonts/segoeui.ttf');
      if (await file.exists()) {
        final font = FontLoader('DrivePreview')
          ..addFont(file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
        await font.load();
      }
      final material = File(
        'C:/Users/kahwa/Documents/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await material.exists()) {
        final icons = FontLoader('MaterialIcons')
          ..addFont(material.readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
        await icons.load();
      }
    }
  });

  testWidgets('settings provides Connect and account identity with a working Logout', (tester) async {
    final auth = FakeDriveAuth()..account = null;
    final service = GoogleDriveService(
      auth: auth,
      clientFactory: () => MockClient(
        (request) async => jsonResponse({
          'files': request.url.queryParameters['q']!.contains("mimeType = 'application/vnd.google-apps.folder'")
              ? [
                  {'id': 'folder-a'},
                ]
              : [],
        }),
      ),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(app(Scaffold(body: GoogleDriveSettingsCard(service: service))));
    await tester.pumpAndSettle();
    expect(find.text('Connect Google Drive'), findsOneWidget);
    await tester.tap(find.text('Connect Google Drive'));
    await tester.pumpAndSettle();
    expect(find.text('Resonance listener'), findsOneWidget);
    expect(find.text('Drive playlists'), findsOneWidget);
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();
    expect(service.connected, isFalse);
    expect(find.text('Connect Google Drive'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replace from the row menu selects the intended file even when its name differs', (tester) async {
    final backend = NoHeaderDrive(), library = _Library();
    final drive = backend.service();
    addTearDown(drive.dispose);
    await tester.pump(); // Flush futures constructed under the widget clock before real I/O.
    await tester.runAsync(() async {
      await drive.refresh();
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(app(GoogleDrivePlaylistsScreen(service: drive, files: library)));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await waitFor(tester, () => !drive.busy);
    await tester.tap(find.byTooltip('Playlist options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace from library'));
    await waitFor(tester, () => find.text('Local mix').evaluate().isNotEmpty);
    await tester.tap(find.text('Local mix'));
    await waitFor(tester, () => find.text('Replace stored playlist').evaluate().isNotEmpty);
    await tester.runAsync(() async {
      await tester.tap(find.text('Replace stored playlist'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await waitFor(tester, () => backend.writes == 1 && !drive.busy);
    expect(drive.playlists.single.id, 'playlist-one');
    expect(drive.playlists.single.name, 'Local mix');
    expect(DrivePlaylistCodec.decode(backend.content).youtubeVideoIds, ['bbbbbbbbbbb', 'ccccccccccc']);
    expect(tester.takeException(), isNull);
  });

  for (final locale in [const Locale('en'), const Locale('ar')]) {
    testWidgets('Drive delete confirms, unlinks and preserves local tracks in $locale', (tester) async {
      tester.view.physicalSize = const Size(360, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = NoHeaderDrive(), library = _Library();
      late GoogleDriveService drive;
      late PlaylistSyncService sync;
      await tester.runAsync(() async {
        drive = backend.service();
        sync = _UiSync(drive, library);
        await drive.refresh();
        await sync.start(polling: false);
        await sync.link(number: 2, remote: drive.playlists.single, mode: PlaylistSyncMode.stream);
      });
      addTearDown(drive.dispose);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          app(
            GoogleDrivePlaylistsScreen(service: drive, sync: sync, files: library),
            locale: locale,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await waitFor(tester, () => !drive.busy);
      final strings = AppStrings(locale);
      Future<void> openDelete() async {
        await tester.tap(find.byTooltip(strings.text('Playlist options')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.text('Delete from Drive')));
        await tester.pumpAndSettle();
      }

      await openDelete();
      expect(find.text(strings.text('Delete from Drive?')), findsOneWidget);
      await tester.tap(find.text(strings.text('Cancel')));
      await tester.pumpAndSettle();
      expect(backend.trashCalls, 0);
      expect(sync.playlists, hasLength(1));
      await openDelete();
      await tester.runAsync(() async {
        await tester.tap(find.text(strings.text('Delete from Drive')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await waitFor(tester, () => backend.trashCalls == 1 && sync.playlists.isEmpty);
      expect(drive.playlists, isEmpty);
      expect(library.tracks, [
        'https://www.youtube.com/watch?v=bbbbbbbbbbb',
        'https://www.youtube.com/watch?v=ccccccccccc',
      ]);
      expect(tester.takeException(), isNull);
      sync.dispose();
    });
  }

  for (final scenario in [(840.0, const Locale('en')), (360.0, const Locale('en')), (360.0, const Locale('ar'))]) {
    testWidgets('Drive playlist layout and import choices at ${scenario.$1}/${scenario.$2}', (tester) async {
      tester.view.physicalSize = Size(scenario.$1, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = GoogleDriveService(
        auth: FakeDriveAuth(),
        clientFactory: () => MockClient((request) async {
          if (request.url.queryParameters['alt'] == 'media') {
            return jsonResponse(jsonDecode(utf8.decode(DrivePlaylistCodec.encode(manifest))));
          }
          if (request.url.path.endsWith('/playlist-one')) return jsonResponse(remoteFile());
          final query = request.url.queryParameters['q']!;
          return jsonResponse({
            'files': query.contains("mimeType = 'application/vnd.google-apps.folder'")
                ? [
                    {'id': 'folder-a'},
                  ]
                : [remoteFile()],
          });
        }),
      );
      addTearDown(service.dispose);
      await service.initialize();
      final capture = GlobalKey();
      // Streamed HTTP needs the real event loop, rather than the widget clock
      // advancing straight to the timeout while an I/O event is pending.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          app(
            GoogleDrivePlaylistsScreen(service: service),
            locale: scenario.$2,
            capture: capture,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(service.error, isNull);
      expect(service.playlists, hasLength(1));
      expect(find.text(manifest.playlistName), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (scenario.$2.languageCode == 'ar') {
        expect(Directionality.of(tester.element(find.text(manifest.playlistName))), TextDirection.rtl);
      }
      if (Platform.environment['RESONANCE_CAPTURE_DRIVE_PREVIEWS'] == '1') {
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = await Directory('build/drive-preview').create(recursive: true);
          await File(
            '${directory.path}/${scenario.$1.toInt()}-${scenario.$2.languageCode}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.runAsync(() async {
        await tester.tap(find.text(manifest.playlistName));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      final strings = AppStrings(scenario.$2);
      for (var attempt = 0; attempt < 20 && find.text(strings.text('Download Tracks')).evaluate().isEmpty; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      await tester.pump();
      expect(
        find.text(strings.text('Download Tracks')),
        findsOneWidget,
        reason: tester.allWidgets.whereType<Text>().map((widget) => widget.data).join(' | '),
      );
      expect(find.text(strings.text('Stream From Playlist')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
