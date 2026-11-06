import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:resonance/services/cover_crop_service.dart';
import 'package:resonance/widgets/library/cover_crop_dialog.dart';
import 'dart:io';
import 'dart:ui' as ui;

void main() {
  Uint8List image() {
    final picture = img.Image(width: 80, height: 40);
    img.fill(picture, color: img.ColorRgb8(255, 0, 0));
    img.fillRect(picture, x1: 40, y1: 0, x2: 79, y2: 39, color: img.ColorRgb8(0, 0, 255));
    return Uint8List.fromList(img.encodePng(picture));
  }

  test('crop exports selected source pixels as a square, without mutating the original', () {
    final original = image();
    final result = renderCoverCrop((bytes: original, left: .5, top: 0, width: .5, height: 1));
    final cropped = img.decodePng(result)!;
    expect(cropped.width, 40);
    expect(cropped.height, 40);
    expect(cropped.getPixel(0, 0).b, 255);
    expect(cropped.getPixel(39, 39).r, 0);
    expect(original, image());
  });
  test('large exports are bounded, small images are not upscaled, invalid images fail', () {
    final large = Uint8List.fromList(img.encodePng(img.Image(width: 1200, height: 1200)));
    expect(img.decodePng(renderCoverCrop((bytes: large, left: 0, top: 0, width: 1, height: 1)))!.width, 1024);
    expect(() => renderCoverCrop((bytes: Uint8List(2), left: 0, top: 0, width: 1, height: 1)), throwsFormatException);
  });
  setUpAll(() async {
    final icons = await File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf').readAsBytes();
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons)))).load();
    final font = File(r'C:\Windows\Fonts\segoeui.ttf');
    if (await font.exists()) {
      await (FontLoader('ReviewFont')..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())))).load();
    }
  });
  for (final width in [320.0, 900.0]) {
    testWidgets('crop preview pans, zooms, resets and cancels at $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'ReviewFont')),
          home: RepaintBoundary(
            key: capture,
            child: CoverCropDialog(bytes: image()),
          ),
        ),
      );
      for (var i = 0; i < 30 && find.byKey(const Key('cover-crop-zoom')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      final slider = find.byKey(const Key('cover-crop-zoom'));
      expect(slider, findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.widget<Slider>(slider).onChanged!(2);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 2);
      await tester.tap(find.byTooltip('Reset'));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 1);
      await tester.drag(find.byKey(const Key('cover-crop-viewport')), const Offset(-25, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final provider = tester.widget<Image>(find.byType(Image).first).image;
      await tester.runAsync(() => precacheImage(provider, tester.element(find.byType(Image).first)));
      await tester.pump();
      final viewport = tester.getSize(find.byKey(const Key('cover-crop-viewport')));
      expect(viewport.width, closeTo(viewport.height, 1));
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
      await tester.runAsync(() async {
        final shot = await boundary.toImage();
        final bytes = await shot.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/v403/crop-${width.toInt()}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        shot.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('Use cover applies the zoomed selection; cancelling returns no edited bytes', (tester) async {
    Uint8List? result;
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showCoverCropDialog(context, image()),
              child: const Text('Open crop'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open crop'));
    await tester.pump();
    for (var i = 0; i < 100 && find.byKey(const Key('cover-crop-zoom')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    tester.widget<Slider>(find.byKey(const Key('cover-crop-zoom'))).onChanged!(2);
    await tester.pump();
    await tester.tap(find.text('Use cover'));
    for (var i = 0; i < 100 && result == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(result, isNotNull);
    expect(img.decodePng(result!)!.width, 20);
    expect(img.decodePng(result!)!.height, 20);
    await tester.pumpAndSettle();
    result = null;
    await tester.tap(find.text('Open crop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });
}
