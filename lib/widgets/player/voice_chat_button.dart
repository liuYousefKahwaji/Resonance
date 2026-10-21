import 'dart:async';
import 'package:flutter/material.dart';
import 'package:resonance/core/audio/voice_chat_controller.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:url_launcher/url_launcher.dart';

class VoiceChatButton extends StatelessWidget {
  const VoiceChatButton({super.key, required this.controller});
  final VoiceChatController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => IconButton(
      tooltip: context.tr(controller.enabled ? 'Voice chat is on' : 'Voice chat'),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(
        controller.enabled ? Icons.mic_rounded : Icons.mic_none_rounded,
        size: 19,
        color: controller.enabled ? Theme.of(context).colorScheme.primary : null,
      ),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => VoiceChatPanel(controller: controller),
      ),
    ),
  );
}

class VoiceChatPanel extends StatefulWidget {
  const VoiceChatPanel({super.key, required this.controller});
  final VoiceChatController controller;
  @override
  State<VoiceChatPanel> createState() => _VoiceChatPanelState();
}

class _VoiceChatPanelState extends State<VoiceChatPanel> {
  bool _initializing = true;
  @override
  void initState() {
    super.initState();
    unawaited(
      widget.controller.initialize().whenComplete(() {
        if (mounted) setState(() => _initializing = false);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.mic_rounded),
            const SizedBox(width: 10),
            Expanded(child: Text(context.tr('Voice chat'))),
            IconButton(
              tooltip: context.tr('Close'),
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        content: SizedBox(
          width: 390,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.tr('Share your music and microphone together in Discord, games or calls.')),
                const SizedBox(height: 16),
                if (_initializing)
                  const LinearProgressIndicator()
                else ...[
                  if (c.cable == null) ...[
                    Text(context.tr('One-time setup'), style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      context.tr(
                        'Install VB-CABLE, then choose CABLE Output as your microphone in the voice chat app. Your headphones stay as its speakers.',
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: Text(context.tr('Get VB-CABLE')),
                          onPressed: () =>
                              launchUrl(Uri.parse('https://vb-audio.com/Cable/'), mode: LaunchMode.externalApplication),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.refresh, size: 16),
                          label: Text(context.tr('Refresh devices')),
                          onPressed: c.busy ? null : c.refreshDevices,
                        ),
                      ],
                    ),
                  ] else ...[
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.tr('Share music + microphone')),
                      subtitle: Text(
                        context.tr(c.enabled ? 'Voice chat is on' : 'Off — your microphone is not being shared'),
                      ),
                      value: c.enabled,
                      onChanged: c.busy ? null : (value) => unawaited(c.setEnabled(value)),
                    ),
                    if (c.busy) const LinearProgressIndicator(),
                    Text(
                      context.tr('In your chat app, select {0} as the microphone.', [
                        c.cable!.name.replaceAll(RegExp('input', caseSensitive: false), 'Output'),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    _level(
                      context,
                      context.tr('Music sent to chat'),
                      c.musicLevel,
                      1,
                      (value) => c.setLevels(music: value),
                    ),
                    _level(
                      context,
                      context.tr('Microphone'),
                      c.microphoneLevel,
                      2,
                      (value) => c.setLevels(microphone: value),
                    ),
                    if (c.enabled)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(value: c.microphonePeak, minHeight: 4),
                        ),
                      ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.tr('Hear myself')),
                      subtitle: Text(context.tr('Use headphones to avoid echo.')),
                      value: c.hearMyself,
                      onChanged: (value) => c.setLevels(monitor: value),
                    ),
                    Text(context.tr('The usual volume bar only changes what you hear.')),
                    if (c.musicLoading)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(context.tr('Preparing music for voice chat…')),
                      ),
                  ],
                  if (c.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        context.trRendered(c.error!),
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  if (c.canRetryMusic)
                    TextButton.icon(
                      onPressed: c.retryMusic,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: Text(context.tr('Retry music')),
                    ),
                  const SizedBox(height: 8),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(context.tr('Audio devices')),
                    children: [
                      _device(
                        context,
                        context.tr('Microphone'),
                        c.microphoneId,
                        c.microphones,
                        (value) => c.selectDevices(microphone: value),
                        enabled: !c.busy,
                      ),
                      _device(
                        context,
                        context.tr('Virtual cable'),
                        c.outputId,
                        c.outputs.where((d) => d.isVirtual).toList(),
                        (value) => c.selectDevices(output: value),
                        enabled: !c.busy,
                      ),
                      _device(
                        context,
                        context.tr('Hear myself through'),
                        c.headphonesId,
                        [VoiceChatDevice('', context.tr('System default')), ...c.outputs.where((d) => !d.isVirtual)],
                        (value) => c.selectDevices(headphones: value),
                        enabled: !c.busy,
                      ),
                      TextButton.icon(
                        onPressed: c.busy ? null : c.refreshDevices,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text(context.tr('Refresh devices')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.tr(
                      'If music sounds filtered, turn off noise suppression and automatic microphone volume in your chat app.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _level(BuildContext context, String title, double value, double max, ValueChanged<double> change) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(title)),
          Text('${(value * 100).round()}%'),
        ],
      ),
      Slider(value: value, max: max, onChanged: change),
    ],
  );
  Widget _device(
    BuildContext context,
    String label,
    String selected,
    List<VoiceChatDevice> devices,
    ValueChanged<String> change, {
    required bool enabled,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label:$selected:${devices.map((d) => d.id).join()}'),
      initialValue: devices.any((d) => d.id == selected) ? selected : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: devices
          .map(
            (d) => DropdownMenuItem(
              value: d.id,
              child: Text(d.name, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: enabled
          ? (value) {
              if (value != null) change(value);
            }
          : null,
    ),
  );
}
