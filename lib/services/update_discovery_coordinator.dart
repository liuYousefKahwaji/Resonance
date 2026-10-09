import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_update_service.dart';

/// One active discovery loop. Download cancellation does not discard availability.
class UpdateDiscoveryCoordinator {
  UpdateDiscoveryCoordinator({
    required this.ready,
    required this.present,
    Future<AvailableUpdate?> Function()? check,
    this.interval = const Duration(minutes: 5),
    this.retryDelays = const [Duration(seconds: 30), Duration(minutes: 2), Duration(minutes: 10)],
  }) : _check = check ?? (() => AppUpdateService().check());
  final bool Function() ready;
  final Future<void> Function(AvailableUpdate) present;
  final Future<AvailableUpdate?> Function() _check;
  final Duration interval;
  final List<Duration> retryDelays;
  Timer? _timer;
  bool _running = false, _disposed = false;
  int _failures = 0;
  String? lastError;
  Future<void> wake() async {
    if (_disposed || _running) return;
    _timer?.cancel();
    var delay = interval;
    var checked = false, failed = false;
    _running = true;
    try {
      if (!ready()) return;
      final update = await _check();
      checked = true;
      if (_disposed || !ready() || update == null) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('update_deferred_version') == update.version.toString()) return;
      // Mark only when UI is ready; a newer version remains eligible.
      await prefs.setString('update_deferred_version', update.version.toString());
      try {
        await present(update);
      } catch (_) {
        await prefs.remove('update_deferred_version');
        rethrow;
      }
    } catch (error) {
      failed = true;
      lastError = '$error';
      if (_failures < retryDelays.length) delay = retryDelays[_failures++];
    } finally {
      if (checked && !failed) {
        _failures = 0;
        lastError = null;
      }
      _running = false;
      if (!_disposed) _timer = Timer(delay, () => unawaited(wake()));
    }
  }

  void start() {
    _timer = Timer(const Duration(seconds: 8), () => unawaited(wake()));
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
