import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/player/cinematic_intro.dart';

void main() {
  testWidgets('intro retains its text layout and painter between animation frames', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final position = ValueNotifier(const Duration(milliseconds: 600));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 800)),
          child: CinematicIntro(position: position, onDismiss: () {}),
        ),
      ),
    );
    final title = tester.widget<Text>(find.text('Resonance'));
    final painter = tester.widget<CustomPaint>(find.byKey(const Key('cinematic-ribbons'))).painter!;
    expect((painter as dynamic).ribbonCount, 13);
    await tester.pump(const Duration(milliseconds: 600));
    final before = (painter as dynamic).progress as double;
    position.value = const Duration(milliseconds: 650); // delayed Android position event
    await tester.pump(const Duration(milliseconds: 16));
    expect((painter as dynamic).progress, greaterThanOrEqualTo(before));
    expect(identical(title, tester.widget<Text>(find.text('Resonance'))), isTrue);
    expect(identical(painter, tester.widget<CustomPaint>(find.byKey(const Key('cinematic-ribbons'))).painter), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    position.dispose();
    expect(tester.takeException(), isNull);
  });
}
