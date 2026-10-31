import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/widgets/common/resonance_dialog.dart';

void main() {
  setUpAll(() async {
    final font = File(r'C:\Windows\Fonts\segoeui.ttf');
    if (await font.exists()) {
      final bytes = await font.readAsBytes();
      await (FontLoader('Segoe UI')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    final icons = await File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf').readAsBytes();
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons)))).load();
  });
  for (final native in [false, true]) {
    for (final locale in [const Locale('en'), const Locale('ar')]) {
      testWidgets('Windows prompts keep a desktop footer with native=$native ${locale.languageCode}', (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final capture = GlobalKey();
        String? result;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: const [
              AppStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: buildResonanceTheme(
              ResonanceThemeStyle.obsidian,
              Brightness.dark,
              windowsNativeControls: native,
            ).copyWith(platform: TargetPlatform.windows),
            builder: (_, child) => RepaintBoundary(key: capture, child: child!),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () async {
                    result = await showDialog<String>(
                      context: context,
                      builder: (context) => ResonanceDialog(
                        title: Text(context.tr('Rename playlist')),
                        content: const SizedBox(
                          width: 360,
                          child: TextField(autofocus: true, decoration: InputDecoration(labelText: 'Playlist name')),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, 'cancel'),
                            child: Text(context.tr('Cancel')),
                          ),
                          TextButton(onPressed: () => Navigator.pop(context, 'save'), child: Text(context.tr('Save'))),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('windows-dialog-frame')), findsOneWidget);
        final footer = find.byKey(const Key('windows-dialog-footer'));
        expect(footer, findsOneWidget);
        expect(tester.getTopLeft(footer).dy, greaterThan(tester.getBottomLeft(find.byType(TextField)).dy));
        await tester.enterText(find.byType(TextField), 'Night drive');
        await tester.pump();
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
        await tester.runAsync(() async {
          final picture = await boundary.toImage(pixelRatio: 1);
          final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
          final f = File('build/v400-ui/dialog-${locale.languageCode}-$native.png');
          await f.parent.create(recursive: true);
          await f.writeAsBytes(bytes!.buffer.asUint8List());
          picture.dispose();
        });
        await tester.tap(find.text(AppStrings(locale).text('Cancel')));
        await tester.pumpAndSettle();
        expect(result, 'cancel');
        expect(find.byKey(const Key('windows-dialog-frame')), findsNothing);
      });
    }
  }
  testWidgets('long Windows prompt content scrolls without moving its actions off screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(720, 460));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: ResonanceDialog(
            title: const Text('Details'),
            scrollable: true,
            content: Column(children: List.generate(40, (i) => Text('Detail $i'))),
            actions: [TextButton(onPressed: () {}, child: const Text('Close'))],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(find.text('Close')).dy, lessThan(460));
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
