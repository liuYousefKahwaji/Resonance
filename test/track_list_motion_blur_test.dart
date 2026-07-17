import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/library/track_list.dart';

void main() {
  testWidgets('ending motion blur preserves the list scroll offset', (tester) async {
    final controller = ScrollController();
    final blurEnabled = ValueNotifier<bool>(false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: blurEnabled,
            child: ListView.builder(
              controller: controller,
              itemExtent: 50,
              itemCount: 100,
              itemBuilder: (_, index) => Text('Track $index'),
            ),
            builder: (context, enabled, child) => TrackListMotionBlurSurface(enabled: enabled, child: child!),
          ),
        ),
      ),
    );

    controller.jumpTo(600);
    await tester.pump();
    expect(controller.offset, 600);

    blurEnabled.value = true;
    await tester.pump();
    expect(controller.offset, 600);

    blurEnabled.value = false;
    await tester.pump();
    expect(controller.offset, 600);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    blurEnabled.dispose();
  });
}
