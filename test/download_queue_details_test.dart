import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/download_queue_entry.dart';
import 'package:resonance/models/download_transfer_progress.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/widgets/youtube/download_queue_panel.dart';

void main() {
  setUpAll(() async {
    final icons = await File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf').readAsBytes();
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons)))).load();
    final font = File(r'C:\Windows\Fonts\segoeui.ttf');
    if (await font.exists()) {
      await (FontLoader('ReviewFont')..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())))).load();
    }
  });
  for (final language in ['en', 'ar']) {
    testWidgets('download details and failure action fit narrow $language queue', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final queue = _QueueFixture();
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('en'), Locale('ar')],
          localizationsDelegates: const [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: buildResonanceTheme(ResonanceThemeStyle.obsidian, Brightness.dark).copyWith(
            textTheme: buildResonanceTheme(
              ResonanceThemeStyle.obsidian,
              Brightness.dark,
            ).textTheme.apply(fontFamily: 'ReviewFont'),
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: DownloadQueuePanel(controller: queue),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('download-transfer-details')), findsOneWidget);
      final details = tester.widget<Text>(find.byKey(const Key('download-transfer-details'))).data!;
      expect(details, contains('1.0 MB / 4.0 MB'));
      expect(details, contains('512 KB/s'));
      expect(find.byTooltip(AppStrings(Locale(language)).text('Retry')), findsOneWidget);
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
      await tester.runAsync(() async {
        final shot = await boundary.toImage();
        final bytes = await shot.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/v403/queue-$language.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        shot.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      queue.dispose();
    });
  }
}

class _QueueFixture extends DownloadQueueController {
  _QueueFixture() : super.forTesting(runner: (_, __) async => null);
  @override
  int get pendingCount => 1;
  @override
  List<DownloadQueueEntry> get entries => const [
    DownloadQueueEntry(
      id: 'active',
      track: YoutubeTrack(title: 'Blow Me Away', artist: 'Breaking Benjamin', url: 'https://youtu.be/abcdefghijk'),
      playlistNumber: 1,
      status: DownloadQueueStatus.downloading,
      progress: 25,
      statusText: 'Downloading... 25.0%',
      attempts: 1,
      transfer: DownloadTransferProgress(
        downloadedBytes: 1048576,
        totalBytes: 4194304,
        bytesPerSecond: 524288,
        etaSeconds: 6,
      ),
    ),
    DownloadQueueEntry(
      id: 'failed',
      track: YoutubeTrack(title: 'Haunted House', artist: 'Neoni', url: 'https://youtu.be/othertrack1'),
      playlistNumber: 1,
      status: DownloadQueueStatus.failed,
      attempts: 4,
      error: 'YouTube could not be reached. Check your connection and try again.',
    ),
  ];
}
