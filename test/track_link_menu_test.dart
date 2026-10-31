import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/widgets/common/track_link_menu.dart';

void main() {
  testWidgets('Copy link never dispatches Download and copies the canonical source', (tester) async {
    SharedPreferences.setMockInitialValues({});
    String? copied;
    var downloads = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackLinkMenu(
            trackId: 'https://music.youtube.com/watch?v=abcdefghijk&si=tracking',
            extraEntries: const [PopupMenuItem(value: 'download', child: Text('Download'))],
            onExtraSelected: (_) => downloads++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    expect(copied, 'https://www.youtube.com/watch?v=abcdefghijk');
    expect(downloads, 0);
    expect(find.text('Link copied'), findsOneWidget);
  });
}
