import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:resonance/core/audio/equalizer_settings.dart';
import 'package:resonance/platform/desktop/hotkey_settings_tile.dart';
import 'package:resonance/services/companion/companion_client_service.dart';
import 'package:resonance/services/companion/companion_protocol.dart';
import 'package:resonance/services/companion/companion_server_service.dart';
import 'package:resonance/services/companion/discord_keybind_service.dart';

class CompanionScreen extends StatelessWidget {
  const CompanionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return const _CompanionServerScreen();
    if (Platform.isAndroid) return const _CompanionRemoteScreen();
    return const Scaffold(body: Center(child: Text('PC Companion is available on Windows and Android.')));
  }
}

class _CompanionServerScreen extends StatefulWidget {
  const _CompanionServerScreen();

  @override
  State<_CompanionServerScreen> createState() => _CompanionServerScreenState();
}

class _CompanionServerScreenState extends State<_CompanionServerScreen> {
  final _server = CompanionServerService.instance;
  final _discordKeybinds = const DiscordKeybindService();
  final Map<DiscordKeybindAction, HotKey> _shortcuts = {};
  DiscordKeybindAction? _shortcutBusy;

  @override
  void initState() {
    super.initState();
    _server.addListener(_refresh);
    unawaited(_server.preparePairing());
    unawaited(_loadShortcuts());
  }

  @override
  void dispose() {
    _server.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadShortcuts() async {
    final loaded = <DiscordKeybindAction, HotKey>{};
    for (final action in DiscordKeybindAction.values) {
      loaded[action] = await _discordKeybinds.get(action);
    }
    if (mounted) setState(() => _shortcuts.addAll(loaded));
  }

  Future<void> _recordShortcut(DiscordKeybindAction action) async {
    final recorded = await recordHotKey(context, requireModifier: false);
    if (recorded == null) return;
    await _discordKeybinds.set(action, recorded);
    if (mounted) setState(() => _shortcuts[action] = recorded);
  }

  Future<void> _testShortcut(DiscordKeybindAction action) async {
    if (_shortcutBusy != null) return;
    setState(() => _shortcutBusy = action);
    final sent = await _discordKeybinds.trigger(action);
    if (!mounted) return;
    setState(() => _shortcutBusy = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? '${action.label} shortcut delivered to Discord'
              : 'Discord did not accept ${action.label.toLowerCase()}',
        ),
      ),
    );
  }

  Future<void> _resetShortcuts() async {
    await _discordKeybinds.resetDefaults();
    await _loadShortcuts();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Discord shortcuts restored')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = _server.pairingPayload;
    return Scaffold(
      appBar: AppBar(title: const Text('PC Companion')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: SwitchListTile(
                        value: _server.enabled,
                        onChanged: (enabled) => unawaited(_server.setEnabled(enabled)),
                        secondary: const Icon(Icons.computer_rounded),
                        title: const Text('Allow Android remote control'),
                        subtitle: Text(
                          _server.running
                              ? '${_server.address}:${_server.port} · ${_server.connectedClientCount} connected'
                              : _server.error ?? 'Server is off',
                        ),
                      ),
                    ),
                    if (_server.error != null) ...[
                      const SizedBox(height: 10),
                      Text(_server.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(child: Text('Discord Controls', style: Theme.of(context).textTheme.titleLarge)),
                        TextButton.icon(
                          onPressed: _resetShortcuts,
                          icon: const Icon(Icons.restore_rounded, size: 18),
                          label: const Text('Restore defaults'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Column(
                        children: [
                          for (var index = 0; index < DiscordKeybindAction.values.length; index++) ...[
                            if (index > 0) const Divider(height: 1),
                            _DiscordKeybindTile(
                              action: DiscordKeybindAction.values[index],
                              hotKey: _shortcuts[DiscordKeybindAction.values[index]],
                              testing: _shortcutBusy == DiscordKeybindAction.values[index],
                              onRecord: () => _recordShortcut(DiscordKeybindAction.values[index]),
                              onTest: () => _testShortcut(DiscordKeybindAction.values[index]),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'These shortcuts are sent to Windows when the Android Companion buttons are tapped. Discord state is not read or tracked.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_server.running && payload != null) ...[
                      const SizedBox(height: 16),
                      Text('Pair an Android device', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      const Text(
                        'Open Settings → PC Companion on Android and scan this one-time code. Both devices must be on the same local network.',
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: Container(
                          width: 300,
                          height: 300,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                          child: QrImageView(
                            data: payload,
                            version: QrVersions.auto,
                            errorCorrectionLevel: QrErrorCorrectLevel.M,
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Pairing code expires after 5 minutes · ${_server.address}:${_server.port}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: OutlinedButton.icon(
                          onPressed: _server.rotatePairingCode,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('New pairing code'),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Text('Approved devices', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    if (_server.approvedDevices.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(18),
                          child: Text('No Android devices have been paired yet.'),
                        ),
                      )
                    else
                      Card(
                        child: Column(
                          children: [
                            for (final device in _server.approvedDevices)
                              ListTile(
                                leading: const Icon(Icons.phone_android_rounded),
                                title: Text(device.name),
                                subtitle: Text('Paired ${_formatDate(device.pairedAt)}'),
                                trailing: IconButton(
                                  tooltip: 'Forget device',
                                  onPressed: () => unawaited(_server.forgetDevice(device.id)),
                                  icon: const Icon(Icons.delete_outline_rounded),
                                ),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      'The companion transfers playback state and control commands only. Audio, files, playlists, and downloads stay on this PC.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}

class _DiscordKeybindTile extends StatelessWidget {
  final DiscordKeybindAction action;
  final HotKey? hotKey;
  final bool testing;
  final VoidCallback onRecord;
  final VoidCallback onTest;

  const _DiscordKeybindTile({
    required this.action,
    required this.hotKey,
    required this.testing,
    required this.onRecord,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        Icon(action == DiscordKeybindAction.toggleMute ? Icons.mic_off_rounded : Icons.headset_off_rounded),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(action.label, style: Theme.of(context).textTheme.titleMedium),
              Text(hotKey == null ? 'Loading…' : formatHotKey(hotKey!), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        TextButton(onPressed: onRecord, child: const Text('Record')),
        const SizedBox(width: 4),
        OutlinedButton.icon(
          onPressed: hotKey == null || testing ? null : onTest,
          icon: testing
              ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('Test'),
        ),
      ],
    ),
  );
}

class _CompanionRemoteScreen extends StatefulWidget {
  const _CompanionRemoteScreen();

  @override
  State<_CompanionRemoteScreen> createState() => _CompanionRemoteScreenState();
}

class _CompanionRemoteScreenState extends State<_CompanionRemoteScreen> {
  final _client = CompanionClientService.instance;
  MobileScannerController? _scanner;
  bool _showScanner = false;
  bool _processingCode = false;
  double? _volumeDraft;
  double? _speedDraft;
  double? _pitchDraft;
  List<double>? _equalizerDraft;

  @override
  void initState() {
    super.initState();
    _client.addListener(_refresh);
    unawaited(
      _client.initialize().then((_) {
        if (mounted && !_client.hasSavedPairing) _openScanner();
      }),
    );
  }

  @override
  void dispose() {
    _client.removeListener(_refresh);
    unawaited(_scanner?.dispose());
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _sendEqualizer(
    CompanionPlaybackSnapshot snapshot, {
    bool? enabled,
    EqualizerPreset? preset,
    List<double>? gainsDb,
  }) {
    final settings = preset == null
        ? EqualizerSettings(
            enabled: enabled ?? snapshot.equalizerEnabled,
            preset: gainsDb == null ? _equalizerPreset(snapshot.equalizerPreset) : EqualizerPreset.custom,
            gainsDb: gainsDb ?? snapshot.equalizerGainsDb,
          )
        : EqualizerSettings.forPreset(preset).copyWith(enabled: enabled ?? snapshot.equalizerEnabled);
    _client.sendCommand('setEqualizer', value: settings.toJson());
  }

  EqualizerPreset _equalizerPreset(String value) =>
      EqualizerPreset.values.firstWhere((preset) => preset.name == value, orElse: () => EqualizerPreset.custom);

  void _openScanner() {
    unawaited(_scanner?.dispose());
    setState(() {
      _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
      _showScanner = true;
      _processingCode = false;
    });
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processingCode) return;
    final raw = capture.barcodes.map((code) => code.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    try {
      CompanionPairingInfo.parse(raw);
      _processingCode = true;
      await _scanner?.stop();
      await _client.pairFromPayload(raw);
      if (!mounted) return;
      setState(() => _showScanner = false);
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      _processingCode = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PC Companion'),
        actions: [
          IconButton(
            onPressed: _openScanner,
            tooltip: 'Pair another PC',
            icon: const Icon(Icons.qr_code_scanner_rounded),
          ),
        ],
      ),
      body: SafeArea(child: _showScanner ? _buildScanner() : _buildRemote()),
    );
  }

  Widget _buildScanner() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        Text('Scan the pairing code shown by Resonance on Windows', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: MobileScanner(
              controller: _scanner,
              onDetect: _onDetect,
              errorBuilder: (context, error) =>
                  Center(child: Text('Camera unavailable: ${error.errorDetails?.message ?? error.errorCode.name}')),
            ),
          ),
        ),
        if (_client.hasSavedPairing) ...[
          const SizedBox(height: 10),
          TextButton(onPressed: () => setState(() => _showScanner = false), child: const Text('Cancel')),
        ],
      ],
    ),
  );

  Widget _buildRemote() {
    final snapshot = _client.snapshot;
    final current = snapshot.currentTrack;
    return RefreshIndicator(
      onRefresh: _client.reconnectNow,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _ConnectionCard(client: _client),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(
                    current == null ? Icons.music_off_rounded : Icons.album_rounded,
                    size: 52,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    current?.title ?? 'Nothing playing',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (current?.artist.isNotEmpty == true) Text(current!.artist, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filledTonal(
                        onPressed: _client.connected ? () => _client.sendCommand('previous') : null,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      const SizedBox(width: 14),
                      IconButton.filled(
                        iconSize: 34,
                        onPressed: _client.connected ? () => _client.sendCommand('playPause') : null,
                        icon: Icon(snapshot.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      ),
                      const SizedBox(width: 14),
                      IconButton.filledTonal(
                        onPressed: _client.connected ? () => _client.sendCommand('next') : null,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _client.connected ? () => _client.sendCommand('seekBackward') : null,
                        icon: const Icon(Icons.fast_rewind_rounded),
                        label: Text('-${snapshot.seekStepSeconds}s'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _client.connected ? () => _client.sendCommand('seekForward') : null,
                        icon: const Icon(Icons.fast_forward_rounded),
                        label: Text('+${snapshot.seekStepSeconds}s'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Loop: ${snapshot.loopMode}',
                        onPressed: _client.connected
                            ? () => _client.sendCommand('setLoop', value: _nextLoopMode(snapshot.loopMode))
                            : null,
                        icon: Icon(snapshot.loopMode == 'one' ? Icons.repeat_one_rounded : Icons.repeat_rounded),
                        color: snapshot.loopMode == 'off' ? null : Theme.of(context).colorScheme.primary,
                      ),
                      IconButton(
                        tooltip: snapshot.shuffle ? 'Turn shuffle off' : 'Turn shuffle on',
                        onPressed: _client.connected
                            ? () => _client.sendCommand('setShuffle', value: !snapshot.shuffle)
                            : null,
                        icon: const Icon(Icons.shuffle_rounded),
                        color: snapshot.shuffle ? Theme.of(context).colorScheme.primary : null,
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  Text('Discord', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('companion-discord-mute'),
                        onPressed: _client.connected ? () => _client.sendCommand(companionToggleMuteCommand) : null,
                        icon: const Icon(Icons.mic_off_rounded),
                        label: const Text('Toggle mute'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('companion-discord-deafen'),
                        onPressed: _client.connected ? () => _client.sendCommand(companionToggleDeafenCommand) : null,
                        icon: const Icon(Icons.headset_off_rounded),
                        label: const Text('Toggle deafen'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
              child: Column(
                children: [
                  _RemoteSlider(
                    label: 'Volume',
                    value: (_volumeDraft ?? snapshot.volume).clamp(0, 2),
                    min: 0,
                    max: 2,
                    divisions: 40,
                    valueLabel: '${((_volumeDraft ?? snapshot.volume) * 100).round()}%',
                    enabled: _client.connected,
                    onChanged: (value) => setState(() => _volumeDraft = value),
                    onChangeEnd: (value) {
                      _client.sendCommand('setVolume', value: value);
                      setState(() => _volumeDraft = null);
                    },
                  ),
                  _RemoteSlider(
                    label: 'Speed',
                    value: (_speedDraft ?? snapshot.speed).clamp(0.5, 2),
                    min: 0.5,
                    max: 2,
                    divisions: 15,
                    valueLabel: '${(_speedDraft ?? snapshot.speed).toStringAsFixed(1)}x',
                    enabled: _client.connected,
                    onChanged: (value) => setState(() => _speedDraft = value),
                    onChangeEnd: (value) {
                      _client.sendCommand('setSpeed', value: value);
                      setState(() => _speedDraft = null);
                    },
                  ),
                  _RemoteSlider(
                    label: 'Pitch',
                    value: (_pitchDraft ?? snapshot.pitch).clamp(0.5, 2),
                    min: 0.5,
                    max: 2,
                    divisions: 15,
                    valueLabel: '${(_pitchDraft ?? snapshot.pitch).toStringAsFixed(1)}x',
                    enabled: _client.connected,
                    onChanged: (value) => setState(() => _pitchDraft = value),
                    onChangeEnd: (value) {
                      _client.sendCommand('setPitch', value: value);
                      setState(() => _pitchDraft = null);
                    },
                  ),
                  if (snapshot.equalizerSupported) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Equalizer'),
                      subtitle: Text(_equalizerPreset(snapshot.equalizerPreset).label),
                      value: snapshot.equalizerEnabled,
                      onChanged: _client.connected ? (enabled) => _sendEqualizer(snapshot, enabled: enabled) : null,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DropdownButton<EqualizerPreset>(
                        value: _equalizerPreset(snapshot.equalizerPreset),
                        onChanged: _client.connected
                            ? (preset) {
                                if (preset != null) _sendEqualizer(snapshot, preset: preset);
                              }
                            : null,
                        items: EqualizerPreset.values
                            .map((preset) => DropdownMenuItem(value: preset, child: Text(preset.label)))
                            .toList(growable: false),
                      ),
                    ),
                    for (var index = 0; index < equalizerBandLabels.length; index++)
                      _RemoteSlider(
                        label: equalizerBandLabels[index],
                        value: (_equalizerDraft ?? snapshot.equalizerGainsDb)[index],
                        min: -10,
                        max: 10,
                        divisions: 40,
                        valueLabel:
                            '${((_equalizerDraft ?? snapshot.equalizerGainsDb)[index] >= 0 ? '+' : '')}${(_equalizerDraft ?? snapshot.equalizerGainsDb)[index].toStringAsFixed(1)} dB',
                        enabled: _client.connected && snapshot.equalizerEnabled,
                        onChanged: (value) {
                          final updated = List<double>.from(_equalizerDraft ?? snapshot.equalizerGainsDb);
                          updated[index] = value;
                          setState(() => _equalizerDraft = updated);
                        },
                        onChangeEnd: (_) {
                          _sendEqualizer(snapshot, gainsDb: _equalizerDraft ?? snapshot.equalizerGainsDb);
                          setState(() => _equalizerDraft = null);
                        },
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('PC queue', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (snapshot.queue.isEmpty)
            const Card(
              child: Padding(padding: EdgeInsets.all(18), child: Text('The PC queue is empty.')),
            )
          else
            Card(
              child: Column(
                children: [
                  for (final track in snapshot.queue)
                    ListTile(
                      selected: track.current,
                      leading: Icon(track.current ? Icons.graphic_eq_rounded : Icons.music_note_rounded),
                      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: track.artist.isEmpty
                          ? null
                          : Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: track.current ? const Text('NOW') : const Icon(Icons.play_arrow_rounded),
                      onTap: track.current || !_client.connected
                          ? null
                          : () => _client.sendCommand('playTrack', id: track.id),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _client.hasSavedPairing ? _client.reconnectNow : _openScanner,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Reconnect'),
          ),
          TextButton.icon(
            onPressed: () async {
              await _client.forgetPairing();
              if (mounted) _openScanner();
            },
            icon: const Icon(Icons.link_off_rounded),
            label: const Text('Forget this PC'),
          ),
        ],
      ),
    );
  }

  String _nextLoopMode(String current) => switch (current) {
    'off' => 'one',
    'one' => 'all',
    _ => 'off',
  };
}

class _ConnectionCard extends StatelessWidget {
  final CompanionClientService client;

  const _ConnectionCard({required this.client});

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (client.status) {
      CompanionConnectionStatus.connected => (Icons.link_rounded, Colors.green, 'Connected to ${client.pcName}'),
      CompanionConnectionStatus.connecting => (Icons.sync_rounded, Colors.orange, 'Connecting to ${client.pcName}…'),
      CompanionConnectionStatus.disconnected => (Icons.link_off_rounded, Colors.orange, 'Waiting for ${client.pcName}'),
      CompanionConnectionStatus.error => (
        Icons.error_outline_rounded,
        Theme.of(context).colorScheme.error,
        'Pairing needs attention',
      ),
      CompanionConnectionStatus.unpaired => (Icons.qr_code_scanner_rounded, Colors.grey, 'No PC paired'),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(label),
        subtitle: client.error == null ? null : Text(client.error!, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _RemoteSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  const _RemoteSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 58,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      Expanded(
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          onChanged: enabled ? onChanged : null,
          onChangeEnd: enabled ? onChangeEnd : null,
        ),
      ),
      SizedBox(width: 46, child: Text(valueLabel, textAlign: TextAlign.right)),
    ],
  );
}
