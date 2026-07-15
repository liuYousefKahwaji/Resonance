import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/screens/settings/app_version_label.dart';

void main() {
  Widget buildSubject(AppVersionLoader versionLoader) {
    return MaterialApp(
      home: Scaffold(body: AppVersionLabel(versionLoader: versionLoader)),
    );
  }

  testWidgets('app version label displays the packaged app version', (tester) async {
    await tester.pumpWidget(buildSubject(() async => '2.4.6'));
    await tester.pumpAndSettle();

    expect(find.text('2.4.6'), findsOneWidget);
  });

  testWidgets('app version label handles unavailable package metadata', (tester) async {
    await tester.pumpWidget(buildSubject(() => Future<String>.error(StateError('unavailable'))));
    await tester.pumpAndSettle();

    expect(find.text('Unavailable'), findsOneWidget);
  });
}
