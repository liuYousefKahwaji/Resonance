import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/screens/onboarding/onboarding_screen.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('tour saves focus, teaches the cover gesture, and completes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeProvider();
    final access = YoutubeAccessService(isWindows: false, isAndroid: false);
    var finished = false;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
          ChangeNotifierProvider<YoutubeAccessService>.value(value: access),
        ],
        child: MaterialApp(home: OnboardingScreen(onFinished: () => finished = true)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Discover first'));
    await tester.tap(find.text('Discover first'));
    await tester.pumpAndSettle();
    expect(theme.listeningFocus, ListeningFocus.stream);

    for (var page = 1; page < 4; page++) {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.byKey(const Key('onboarding-cover-demo')));
    await tester.tap(find.byKey(const Key('onboarding-cover-demo')));
    await tester.pumpAndSettle();
    expect(find.text('Full player'), findsOneWidget);

    await tester.tap(find.text('Start listening'));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect((await SharedPreferences.getInstance()).getBool('onboarding_completed'), isTrue);
  });
}
