import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/services/app_update_service.dart';
import 'package:resonance/services/update_discovery_coordinator.dart';

AvailableUpdate update(String version) => AvailableUpdate(
  version: AppVersion.parse(version)!,
  notes: '',
  asset: UpdateAsset(url: Uri.parse('https://example.com/update.zip'), name: 'update.zip', sha256: '0' * 64, size: 1),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('UI readiness, scheduled discovery and dismissal are coordinated per version', (tester) async {
    var ready = false, checks = 0;
    var latest = update('3.5.1');
    final shown = <String>[];
    final coordinator = UpdateDiscoveryCoordinator(
      ready: () => ready,
      interval: const Duration(seconds: 20),
      check: () async {
        checks++;
        return latest;
      },
      present: (value) async {
        shown.add('${value.version}');
      },
    );
    coordinator.start();
    await tester.pump(const Duration(seconds: 8));
    expect(checks, 0);
    ready = true;
    await coordinator.wake();
    expect(shown, ['3.5.1']);
    await tester.pump(const Duration(seconds: 20));
    expect(checks, 2);
    expect(shown, ['3.5.1']);
    latest = update('3.5.2');
    await tester.pump(const Duration(seconds: 20));
    expect(shown, ['3.5.1', '3.5.2']);
    coordinator.dispose();
  });
  testWidgets('network failures retry and overlapping wake calls share one check', (tester) async {
    var calls = 0;
    final pending = Completer<AvailableUpdate?>();
    final coordinator = UpdateDiscoveryCoordinator(
      ready: () => true,
      retryDelays: const [Duration(seconds: 2), Duration(seconds: 4)],
      check: () {
        calls++;
        if (calls == 1) throw StateError('offline');
        return pending.future;
      },
      present: (_) async {},
    );
    await coordinator.wake();
    expect(coordinator.lastError, contains('offline'));
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 2);
    await coordinator.wake();
    expect(calls, 2);
    pending.complete(null);
    await tester.pump();
    expect(coordinator.lastError, isNull);
    coordinator.dispose();
  });
  testWidgets('failed presentation remains eligible for a bounded retry', (tester) async {
    var shown = 0;
    final coordinator = UpdateDiscoveryCoordinator(
      ready: () => true,
      retryDelays: const [Duration(seconds: 2), Duration(seconds: 4)],
      check: () async => update('3.5.1'),
      present: (_) async {
        if (++shown <= 2) throw StateError('navigator unavailable');
      },
    );
    await coordinator.wake();
    await tester.pump(const Duration(seconds: 2));
    expect(shown, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(shown, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(shown, 3);
    coordinator.dispose();
  });
}
