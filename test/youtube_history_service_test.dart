import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/services/youtube/youtube_history_preferences.dart';
import 'package:resonance/services/youtube/youtube_history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<YoutubeAccessService> configuredAccess() async {
    SharedPreferences.setMockInitialValues({
      'youtube_access.windows_browser_id': 'chrome',
      'youtube_access.last_successful_test_at': DateTime(2026).toIso8601String(),
    });
    final preferences = await SharedPreferences.getInstance();
    final access = YoutubeAccessService(preferences: preferences, isWindows: true, isAndroid: false);
    await access.initialize();
    return access;
  }

  Future<YoutubeHistoryPreferences> historyPreferences({bool enabled = false}) async {
    SharedPreferences.setMockInitialValues({YoutubeHistoryPreferences.preferenceKey: enabled});
    return YoutubeHistoryPreferences.load();
  }

  test('disabled preference does not invoke a platform writer', () async {
    var calls = 0;
    final service = YoutubeHistoryService(
      preferences: await historyPreferences(),
      access: await configuredAccess(),
      isWindows: true,
      windowsInvoker: (_) async {
        calls++;
        return '{}';
      },
    );

    final result = await service.reportVideoId('jNQXAC9IVRw');

    expect(result.status, YoutubeHistoryWriteStatus.disabled);
    expect(calls, 0);
  });

  test('malformed video id is skipped without a platform call', () async {
    var calls = 0;
    final service = YoutubeHistoryService(
      preferences: await historyPreferences(enabled: true),
      access: await configuredAccess(),
      isWindows: true,
      windowsInvoker: (_) async {
        calls++;
        return '{}';
      },
    );

    final result = await service.reportVideoId('not-a-valid-id');

    expect(result.status, YoutubeHistoryWriteStatus.skipped);
    expect(calls, 0);
  });

  test('writes a valid Windows helper response', () async {
    final service = YoutubeHistoryService(
      preferences: await historyPreferences(enabled: true),
      access: await configuredAccess(),
      isWindows: true,
      windowsInvoker: (_) async => '{"ok":true,"videoId":"jNQXAC9IVRw","statusCode":204}',
    );

    final result = await service.reportVideoId('jNQXAC9IVRw');

    expect(result.status, YoutubeHistoryWriteStatus.written);
  });

  test('writes a valid Android channel response', () async {
    final service = YoutubeHistoryService(
      preferences: await historyPreferences(enabled: true),
      access: await configuredAccess(),
      isWindows: false,
      isAndroid: true,
      androidInvoker: (_) async => const {'ok': true, 'videoId': 'jNQXAC9IVRw', 'statusCode': 204},
    );

    final result = await service.reportVideoId('jNQXAC9IVRw');

    expect(result.status, YoutubeHistoryWriteStatus.written);
  });

  test('maps access failures without throwing into playback', () async {
    final service = YoutubeHistoryService(
      preferences: await historyPreferences(enabled: true),
      access: await configuredAccess(),
      isWindows: true,
      windowsInvoker: (_) =>
          Future<String>.error(const YoutubeFailure(kind: YoutubeFailureKind.sessionRejected, userMessage: 'expired')),
    );

    final result = await service.reportVideoId('jNQXAC9IVRw');

    expect(result.status, YoutubeHistoryWriteStatus.authUnavailable);
  });

  test('treats malformed platform responses and exceptions as non-fatal failures', () async {
    final service = YoutubeHistoryService(
      preferences: await historyPreferences(enabled: true),
      access: await configuredAccess(),
      isWindows: false,
      isAndroid: true,
      androidInvoker: (_) => Future<Object?>.error(PlatformException(code: 'TEST_ERROR')),
    );

    final result = await service.reportVideoId('jNQXAC9IVRw');

    expect(result.status, YoutubeHistoryWriteStatus.failed);
  });

  test('reports unsupported outside Windows and Android', () async {
    final service = YoutubeHistoryService(
      preferences: await historyPreferences(enabled: true),
      access: await configuredAccess(),
      isWindows: false,
      isAndroid: false,
    );

    final result = await service.reportVideoId('jNQXAC9IVRw');

    expect(result.status, YoutubeHistoryWriteStatus.unsupported);
  });
}
