import 'dart:async';
import 'package:flutter/material.dart';
import 'package:resonance/services/app_update_service.dart';

String formatUpdateBytes(int bytes) =>
    bytes >= 1048576 ? '${(bytes / 1048576).toStringAsFixed(1)} MB' : '${(bytes / 1024).toStringAsFixed(0)} KB';

class AndroidUpdateStatus extends StatefulWidget {
  const AndroidUpdateStatus({super.key, this.statusLoader, this.retry});
  final Future<Map<String, dynamic>?> Function()? statusLoader;
  final Future<void> Function()? retry;
  @override
  State<AndroidUpdateStatus> createState() => _AndroidUpdateStatusState();
}

class _AndroidUpdateStatusState extends State<AndroidUpdateStatus> with WidgetsBindingObserver {
  Map<String, dynamic>? _status;
  Timer? _timer;
  bool _busy = false;
  bool _reading = false;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppUpdateService.androidUpdateRevision.addListener(_refresh);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    AppUpdateService.androidUpdateRevision.removeListener(_refresh);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_visible) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!mounted || !_visible || _reading) return;
    _reading = true;
    _timer?.cancel();
    try {
      final status = await (widget.statusLoader?.call() ?? AppUpdateService().androidUpdateStatus());
      if (mounted) setState(() => _status = status);
    } catch (_) {
      // An optional status display must not interfere with the music player.
    } finally {
      _reading = false;
      if (mounted && _visible && _status != null) {
        _timer = Timer(const Duration(seconds: 2), () => unawaited(_refresh()));
      }
    }
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await (widget.retry?.call() ?? AppUpdateService().retryAndroidInstall());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not continue update: $error')));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    final state = status['state'];
    final received = (status['received'] as num?)?.toInt() ?? 0;
    final total = (status['total'] as num?)?.toInt() ?? 0;
    final fraction = total > 0 ? (received / total).clamp(0.0, 1.0) : null;
    final ready = state == 'ready' || state == 'awaiting_approval';
    final failed = state == 'failed';
    final downloading = state == 'downloading' || state == 'waiting';
    final message = switch (state) {
      'downloading' => 'Downloading ${formatUpdateBytes(received)} of ${formatUpdateBytes(total)}',
      'waiting' => 'Waiting for the download to continue…',
      'verifying' => 'Checking the downloaded update…',
      'reconstructing' => 'Preparing the update…',
      'ready' =>
        status['needsPermission'] == true
            ? 'Ready to install. Allow Resonance to install updates.'
            : 'Ready to install.',
      'awaiting_approval' => 'Ready to install. Android needs your approval.',
      'installing' => 'Installing the update…',
      'failed' => 'The update could not finish. You can try again.',
      _ => 'Preparing the update…',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Updating to ${status['version']}', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(message),
          if (!ready && !failed) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: downloading ? fraction : null),
            if (downloading && fraction != null)
              Padding(padding: const EdgeInsets.only(top: 5), child: Text('${(fraction * 100).round()}%')),
          ],
          if (downloading && status['full'] == true)
            const Padding(padding: EdgeInsets.only(top: 5), child: Text('Downloading the full package.')),
          if (ready || failed)
            TextButton(
              onPressed: _busy ? null : _retry,
              child: Text(failed ? 'Retry update' : 'Continue installation'),
            ),
        ],
      ),
    );
  }
}
