import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/smart_playlist.dart';
import 'package:resonance/services/library_catalog.dart';
import 'package:resonance/services/listening_statistics.dart';
import 'package:resonance/services/smart_playlist_repository.dart';
import 'package:resonance/screens/library/library_browser_screen.dart';
import 'package:resonance/screens/settings/backup_screen.dart';
import 'package:resonance/screens/settings/listening_statistics_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory directory;
  late FileService files;
  late LibraryCatalog catalog;
  late SmartPlaylistRepository smart;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('resonance-library-layout-');
    files = FileService(documentsPathOverride: directory.path);
    catalog = LibraryCatalog(files: files);
    smart = SmartPlaylistRepository();
    catalog.tracks = List.generate(
      12,
      (i) => LibraryTrack(
        id: '$i',
        path: '${directory.path}/missing-$i.mp3',
        title: 'Track ${i + 1}',
        artist: 'Artist',
        album: 'Album ${i ~/ 3 + 1}',
        favorite: i.isEven,
      ),
    );
    smart.playlists = [
      const SmartPlaylist(id: 'favorites', name: 'My favorites', rules: [SmartRule(SmartField.favorite, '')]),
    ];
  });
  tearDown(() async {
    catalog.dispose();
    smart.dispose();
    await directory.delete(recursive: true);
  });
  Widget wrap(Widget screen, bool arabic, GlobalKey capture) => RepaintBoundary(
    key: capture,
    child: MaterialApp(
      locale: Locale(arabic ? 'ar' : 'en'),
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData.dark(useMaterial3: true),
      home: screen,
    ),
  );
  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final image = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final folder = await Directory('build/issues-preview').create(recursive: true);
      await File('${folder.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  for (final arabic in [false, true]) {
    testWidgets('library and smart editor fit ${arabic ? 'Arabic phone' : 'Windows'}', (tester) async {
      await tester.binding.setSurfaceSize(arabic ? const Size(390, 844) : const Size(1280, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey();
      await tester.pumpWidget(wrap(LibraryBrowserScreen(catalog: catalog, smart: smart), arabic, key));
      await tester.pumpAndSettle();
      expect(find.text('My favorites'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('Album 1'), findsOneWidget);
      await capture(tester, key, arabic ? 'albums-arabic-phone' : 'albums-windows');
      await tester.tap(find.text(arabic ? 'إنشاء' : 'Create'));
      await tester.pumpAndSettle();
      expect(find.byType(SmartPlaylistEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, key, arabic ? 'smart-arabic-phone' : 'smart-windows');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    testWidgets('recap and backup fit ${arabic ? 'Arabic phone' : 'Windows'}', (tester) async {
      await tester.binding.setSurfaceSize(arabic ? const Size(390, 844) : const Size(1000, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final stats = ListeningStatistics();
      addTearDown(stats.dispose);
      final date = DateTime.now();
      final day = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      stats.days = {
        day: {
          'track': {
            'title': 'The best song',
            'artist': 'An artist',
            'ms': 86400000,
            'plays': 42,
            'localMs': 20000000,
            'streamMs': 66400000,
            'hours': {'12': 86400000},
            'playlists': {'1': 86400000},
          },
        },
      };
      final key = GlobalKey();
      await tester.pumpWidget(wrap(ListeningStatisticsScreen(statistics: stats, files: files), arabic, key));
      await tester.pumpAndSettle();
      expect(find.text('The best song'), findsWidgets);
      expect(tester.takeException(), isNull);
      await capture(tester, key, arabic ? 'recap-arabic-phone' : 'recap-windows');
      await tester.pumpWidget(wrap(const BackupScreen(), arabic, GlobalKey()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
