import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/screens/settings/youtube_access_screen.dart';
import 'package:resonance/services/youtube/youtube_access_backend.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/services/youtube/windows_browser_detector.dart';
import 'package:resonance/services/youtube/windows_chromium_connector.dart';
import 'package:resonance/services/youtube/youtube_history_preferences.dart';
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

  testWidgets('Chromium tries direct access before offering the optional connector', (tester) async {
    SharedPreferences.setMockInitialValues({'youtube_access.warning_acknowledged': true});
    final browser = _ChromiumBrowser();
    final connector = _ChromiumConnector();
    final service = YoutubeAccessService(
      preferences: await SharedPreferences.getInstance(),
      isWindows: true,
      isAndroid: false,
      windowsConnector: connector,
    );
    await service.initialize();
    final tested = <String>[];
    service.setWindowsTester((source, _) async {
      tested.add(source);
      if (source == _ChromiumBrowser.source) {
        throw Exception('WARNING: unknown cookie version: v20. Missing its authenticated SAPISID cookie');
      }
    });
    service.setWindowsHomeTester((source) async => tested.add(source));
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: MaterialApp(home: YoutubeAccessScreen(windows: true, android: false, browserDetector: browser)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect browser session'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Some browsers protect their saved sessions'), findsWidgets);
    expect(find.textContaining('Load unpacked'), findsNothing);
    expect(connector.begun, 0);
    expect(browser.launched, ['https://music.youtube.com/']);
    await tester.tap(find.text("I'm signed in — test access"));
    await tester.pumpAndSettle();
    expect(find.text('Could not read this browser session'), findsOneWidget);
    expect(tested, [_ChromiumBrowser.source]);
    expect(connector.begun, 0);
    await tester.tap(find.text('Use browser connector'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Load unpacked'), findsOneWidget);
    expect(connector.begun, 1);
    await tester.tap(find.text('Open extensions'));
    await tester.pumpAndSettle();
    expect(browser.launched.last, 'edge://extensions/');
    await tester.tap(find.text('Test access'));
    await tester.pumpAndSettle();
    expect(tested, [_ChromiumBrowser.source, _ChromiumConnector.source, _ChromiumConnector.source]);
    expect(service.windowsBrowserId, _ChromiumConnector.source);
    expect(find.textContaining('encrypted copy'), findsOneWidget);
    expect(connector.activated, isTrue);
    expect(connector.revoked, isFalse);
    expect(tester.takeException(), isNull);
  });

  Future<void> showWindows(WidgetTester tester, YoutubeAccessService service, _ChromiumBrowser browser) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: MaterialApp(home: YoutubeAccessScreen(windows: true, android: false, browserDetector: browser)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect browser session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("I'm signed in — test access"));
    await tester.pumpAndSettle();
  }

  Future<YoutubeAccessService> windowsService(_ChromiumConnector connector) async {
    SharedPreferences.setMockInitialValues({'youtube_access.warning_acknowledged': true});
    final service = YoutubeAccessService(
      preferences: await SharedPreferences.getInstance(),
      isWindows: true,
      isAndroid: false,
      windowsConnector: connector,
    );
    await service.initialize();
    return service;
  }

  testWidgets('a readable default browser connects without any connector setup', (tester) async {
    final browser = _ChromiumBrowser();
    final connector = _ChromiumConnector();
    final service = await windowsService(connector);
    final tested = <String>[];
    service.setWindowsTester((source, _) async => tested.add(source));
    service.setWindowsHomeTester((source) async => tested.add(source));
    await showWindows(tester, service, browser);
    expect(tested, [_ChromiumBrowser.source, _ChromiumBrowser.source]);
    expect(service.windowsBrowserId, _ChromiumBrowser.source);
    expect(service.status.state, YoutubeAccessState.ready);
    expect(find.textContaining('connected browser profile locally'), findsOneWidget);
    expect(find.textContaining('reads Firefox'), findsNothing);
    expect(connector.begun, 0);
    expect(connector.activated, isFalse);
    expect(connector.revoked, isFalse);
    expect(browser.launched, ['https://music.youtube.com/']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a locked browser can retry direct access without reopening it', (tester) async {
    final browser = _ChromiumBrowser();
    final connector = _ChromiumConnector();
    final service = await windowsService(connector);
    var attempts = 0;
    service.setWindowsTester((source, _) async {
      expect(source, _ChromiumBrowser.source);
      if (++attempts == 1) throw Exception('Could not copy Chrome cookie database: database is locked');
    });
    service.setWindowsHomeTester((source) async => expect(source, _ChromiumBrowser.source));
    await showWindows(tester, service, browser);
    expect(find.textContaining('Close its windows and retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(service.status.state, YoutubeAccessState.ready);
    expect(service.windowsBrowserId, _ChromiumBrowser.source);
    expect(browser.launched, ['https://music.youtube.com/']);
    expect(connector.begun, 0);
    expect(tester.takeException(), isNull);
  });

  for (final error in ['Connection timed out', 'The selected browser profile is not signed in to YouTube Music']) {
    testWidgets('ordinary connection failures never request a connector: $error', (tester) async {
      final browser = _ChromiumBrowser();
      final connector = _ChromiumConnector();
      final service = await windowsService(connector);
      service.setWindowsTester((_, _) async => throw Exception(error));
      await showWindows(tester, service, browser);
      expect(find.text('Use browser connector'), findsNothing);
      expect(find.textContaining('Load unpacked'), findsNothing);
      expect(connector.begun, 0);
      expect(service.isConfigured, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

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

  testWidgets('history sync is explicit, off by default, and waits for tested access', (tester) async {
    final backend = _RecordingBackend();
    final service = await serviceFor(backend);
    final history = await YoutubeHistoryPreferences.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: service),
          ChangeNotifierProvider.value(value: history),
        ],
        child: const MaterialApp(home: YoutubeAccessScreen(android: true, windows: false)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sync plays to YouTube Music history'), findsOneWidget);
    expect(history.enabled, isFalse);
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.onChanged, isNull);
    expect(find.textContaining('view count', findRichText: true), findsNothing);
  });
}

class _ChromiumBrowser extends WindowsBrowserDetector {
  static const source = 'edge:Profile 1';
  final launched = <String>[];
  @override
  Future<String?> detectDefaultBrowser() async => 'edge';
  @override
  Future<String> resolveCookieSource(String browserId) async {
    expect(browserId, 'edge');
    return source;
  }

  @override
  Future<bool> launchBrowser(String browserId, String url) async {
    expect(browserId, 'edge');
    launched.add(url);
    return true;
  }
}

class _ChromiumConnector extends WindowsChromiumConnector {
  static const source = 'edge+connector:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  bool activated = false, revoked = false;
  int begun = 0;
  @override
  Future<WindowsChromiumConnection> begin(String browser) async {
    begun++;
    return const WindowsChromiumConnection(source, 'C:/test/connector');
  }

  @override
  Future<void> activate(String source) async {
    activated = true;
  }

  @override
  Future<void> revoke(String source) async {
    revoked = true;
  }
}
