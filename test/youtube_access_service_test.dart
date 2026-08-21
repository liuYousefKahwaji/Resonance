import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/services/youtube/youtube_access_backend.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows connection commits only after a successful test and revisions track changes', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final service = YoutubeAccessService(
      preferences: preferences,
      androidBackend: MemoryYoutubeAccessBackend(),
      isWindows: true,
      isAndroid: false,
    );
    await service.initialize();
    service.setWindowsTester((browser, url) async {
      expect(browser, 'edge');
      expect(url, YoutubeAccessService.fallbackTestTarget);
      expect(url, startsWith('ytsearch1:'));
    });

    await service.connectWindowsBrowser('edge');
    expect(service.status.state, YoutubeAccessState.ready);
    expect(service.revision, 1);
    expect(preferences.getString('youtube_access.windows_browser_id'), 'edge');
    expect(preferences.getKeys(), isNot(contains('cookies')));

    await service.testCurrent();
    expect(service.revision, 1);
    await service.clear();
    expect(service.revision, 2);
    expect(service.status.state, YoutubeAccessState.notConfigured);
  });

  test('Android invalid import never replaces existing native credentials', () async {
    SharedPreferences.setMockInitialValues({});
    final backend = MemoryYoutubeAccessBackend(configured: true);
    final service = YoutubeAccessService(
      preferences: await SharedPreferences.getInstance(),
      androidBackend: backend,
      isWindows: false,
      isAndroid: true,
    );
    await service.initialize();
    expect(() => service.importAndroidCookies(Uint8List.fromList([1, 2, 3])), throwsA(isA<YoutubeFailure>()));
    expect(backend.configured, isTrue);
  });

  test('a failed pending Windows browser test preserves the previously connected browser', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final service = YoutubeAccessService(
      preferences: preferences,
      androidBackend: MemoryYoutubeAccessBackend(),
      isWindows: true,
      isAndroid: false,
    );
    await service.initialize();
    service.setWindowsTester((_, __) async {});
    await service.connectWindowsBrowser('edge');
    service.setWindowsTester((_, __) async {
      throw Exception("Sign in to confirm you're not a bot");
    });

    await expectLater(service.connectWindowsBrowser('chrome'), throwsA(isA<YoutubeFailure>()));
    expect(service.windowsBrowserId, 'edge');
    expect(service.revision, 1);
    expect(preferences.getString('youtube_access.windows_browser_id'), 'edge');
  });

  test('valid Android import is tested and increments the credential revision once', () async {
    SharedPreferences.setMockInitialValues({});
    final backend = MemoryYoutubeAccessBackend();
    final service = YoutubeAccessService(
      preferences: await SharedPreferences.getInstance(),
      androidBackend: backend,
      isWindows: false,
      isAndroid: true,
    );
    await service.initialize();
    final bytes = Uint8List.fromList(
      ('# Netscape HTTP Cookie File\n'
              '.youtube.com\tTRUE\t/\tTRUE\t0\tLOGIN_INFO\tfake-login\n'
              '.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tfake-sapisid\n')
          .codeUnits,
    );
    await service.importAndroidCookies(bytes);
    expect(service.status.state, YoutubeAccessState.ready);
    expect(service.revision, 1);
    expect(backend.configured, isTrue);
    expect(backend.lastTestSourceUrl, YoutubeAccessService.fallbackTestTarget);
  });
}
