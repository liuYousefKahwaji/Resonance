import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/screens/settings/youtube_access_screen.dart';
import 'package:resonance/services/youtube/youtube_access_backend.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/widgets/youtube/youtube_failure_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingBackend extends MemoryYoutubeAccessBackend {
  String? lastUrl;

  @override
  Future<bool> openFirefoxUrl(String url) async {
    lastUrl = url;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<YoutubeAccessService> serviceFor(_RecordingBackend backend) async {
    SharedPreferences.setMockInitialValues({});
    final service = YoutubeAccessService(
      androidBackend: backend,
      preferences: await SharedPreferences.getInstance(),
      isWindows: false,
      isAndroid: true,
    );
    await service.initialize();
    return service;
  }

  testWidgets('Android guide is redirect-safe and targets the exact cookies.txt add-on', (tester) async {
    final backend = _RecordingBackend();
    final service = await serviceFor(backend);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: const MaterialApp(home: YoutubeAccessScreen(android: true, windows: false)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Open links in apps'), findsOneWidget);
    expect(find.textContaining('Current Site → Download'), findsOneWidget);
    expect(find.textContaining('Do not choose ALL'), findsOneWidget);
    expect(find.byKey(const Key('youtube-cookies-addon-link')), findsOneWidget);

    final addOnButton = tester.widget<OutlinedButton>(find.byKey(const Key('youtube-cookies-addon-link')));
    addOnButton.onPressed!();
    await tester.pumpAndSettle();
    expect(backend.lastUrl, 'https://addons.mozilla.org/en-US/firefox/addon/cookies-txt/');
    expect(tester.takeException(), isNull);
  });

  testWidgets('guide wraps at narrow width and 2x text scale', (tester) async {
    final service = await serviceFor(_RecordingBackend());
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: const MaterialApp(home: YoutubeAccessScreen(android: true, windows: false)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('authentication failures never render raw yt-dlp output as the main message', (tester) async {
    final service = await serviceFor(_RecordingBackend());
    const raw = "ERROR: [youtube] abc: Sign in to confirm you're not a bot. Use --cookies-from-browser or --cookies";
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showYoutubeFailure(context, Exception(raw)),
                child: const Text('Fail'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Fail'));
    await tester.pumpAndSettle();
    expect(find.text('YouTube verification required'), findsOneWidget);
    expect(find.textContaining('YouTube blocked this request'), findsOneWidget);
    expect(find.textContaining('--cookies-from-browser'), findsNothing);
  });
}
