import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/services/sync/sync_session_service.dart';

Future<bool?> showSyncLauncher(
  BuildContext context, {
  required PlayerHandler handler,
  required int playlistNumber,
  required String playlistName,
  required List<String> tracks,
}) => showModalBottomSheet<bool>(
  context: context,
  useSafeArea: true,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheetContext) =>
      _SyncLauncher(handler: handler, playlistNumber: playlistNumber, playlistName: playlistName, tracks: tracks),
);

class _SyncLauncher extends StatefulWidget {
  final PlayerHandler handler;
  final int playlistNumber;
  final String playlistName;
  final List<String> tracks;

  const _SyncLauncher({
    required this.handler,
    required this.playlistNumber,
    required this.playlistName,
    required this.tracks,
  });

  @override
  State<_SyncLauncher> createState() => _SyncLauncherState();
}

class _SyncLauncherState extends State<_SyncLauncher> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final sync = SyncSessionService.instance;
    if (sync.isHost) return _HostSessionView(sync: sync);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.spatial_audio_rounded, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Text('Resonance Sync', style: Theme.of(context).textTheme.headlineSmall),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Play the same streamed music on nearby phones. The host controls playback; every phone keeps its own volume.',
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: _busy ? null : _host,
            icon: const Icon(Icons.wifi_tethering_rounded),
            label: Text(_busy ? 'Starting…' : 'Host from this playlist'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _join,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Join with QR code'),
          ),
          const SizedBox(height: 14),
          Text(
            'Phones must be on the same Wi-Fi or the host phone’s hotspot. Local files are excluded.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _host() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SyncSessionService.instance.startHosting(
        currentPlaylistNumber: widget.playlistNumber,
        currentPlaylistName: widget.playlistName,
        currentTracks: widget.tracks,
      );
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not host: $error';
        });
      }
    }
  }

  Future<void> _join() async {
    final joined = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => SyncJoinScreen(handler: widget.handler)),
    );
    if (joined == true && mounted) Navigator.pop(context, true);
  }
}

class _HostSessionView extends StatelessWidget {
  final SyncSessionService sync;
  const _HostSessionView({required this.sync});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: sync,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Resonance Sync is live', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text('${sync.peerCount} ${sync.peerCount == 1 ? 'phone' : 'phones'} connected'),
          const SizedBox(height: 18),
          if (sync.pairingPayload case final payload?)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
              child: QrImageView(data: payload, size: 230, backgroundColor: Colors.white),
            )
          else
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('The five-minute joining window has closed. End and restart Sync to invite another phone.'),
            ),
          const SizedBox(height: 14),
          Text(
            'Guests hear only streamed tracks and cannot control playback.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () async {
              await sync.leave();
              if (context.mounted) Navigator.pop(context, true);
            },
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('End Sync'),
          ),
        ],
      ),
    ),
  );
}

class SyncJoinScreen extends StatefulWidget {
  final PlayerHandler handler;
  const SyncJoinScreen({super.key, required this.handler});

  @override
  State<SyncJoinScreen> createState() => _SyncJoinScreenState();
}

class _SyncJoinScreenState extends State<SyncJoinScreen> {
  late final MobileScannerController _scanner;
  bool _joining = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scanner = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void dispose() {
    unawaited(_scanner.dispose());
    super.dispose();
  }

  Future<void> _detect(BarcodeCapture capture) async {
    if (_joining) return;
    final raw = capture.barcodes.map((barcode) => barcode.rawValue).whereType<String>().firstOrNull;
    if (raw == null || !raw.startsWith('resonance://sync')) return;
    setState(() {
      _joining = true;
      _error = null;
    });
    await _scanner.stop();
    try {
      await SyncSessionService.instance.join(raw);
      if (!mounted) return;
      await Navigator.pushReplacement<void, void>(
        context,
        MaterialPageRoute(builder: (_) => const StandalonePlayerScreen(syncPeer: true)),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = error.toString();
      });
      await _scanner.start();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Join Resonance Sync')),
    body: Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: MobileScanner(controller: _scanner, onDetect: _detect),
            ),
          ),
        ),
        if (_joining) const LinearProgressIndicator(),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 28),
          child: Text(
            _error ?? 'Scan the QR code shown on the host phone.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _error == null ? null : Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    ),
  );
}
