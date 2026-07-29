import 'package:flutter/material.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/equalizer_settings.dart';

class EqualizerScreen extends StatefulWidget {
  final PlayerHandler handler;

  const EqualizerScreen({super.key, required this.handler});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  late EqualizerSettings _settings;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.handler.equalizerNotifier.value;
    widget.handler.equalizerNotifier.addListener(_syncSettings);
  }

  @override
  void didUpdateWidget(covariant EqualizerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.handler == widget.handler) return;
    oldWidget.handler.equalizerNotifier.removeListener(_syncSettings);
    _settings = widget.handler.equalizerNotifier.value;
    widget.handler.equalizerNotifier.addListener(_syncSettings);
  }

  void _syncSettings() {
    if (mounted && !_applying) {
      setState(() => _settings = widget.handler.equalizerNotifier.value);
    }
  }

  @override
  void dispose() {
    widget.handler.equalizerNotifier.removeListener(_syncSettings);
    super.dispose();
  }

  Future<void> _apply(EqualizerSettings settings) async {
    setState(() {
      _settings = settings;
      _applying = true;
    });
    try {
      await widget.handler.setEqualizer(settings);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Equalizer'),
        actions: [
          if (_applying)
            const Padding(
              padding: EdgeInsets.only(right: 18),
              child: Center(child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: colors.outline),
              ),
              child: Row(
                children: [
                  Icon(Icons.equalizer_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Five-band equalizer', style: TextStyle(fontWeight: FontWeight.w700)),
                        Text('Automatic headroom prevents boosted bands from clipping', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _settings.enabled,
                    onChanged: (enabled) => _apply(_settings.copyWith(enabled: enabled)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text('PRESETS', style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1.1)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in EqualizerPreset.values.where((preset) => preset != EqualizerPreset.custom))
                  ChoiceChip(
                    label: Text(preset.label),
                    selected: _settings.preset == preset,
                    onSelected: (_) => _apply(_settings.selectPreset(preset)),
                  ),
                if (_settings.preset == EqualizerPreset.custom || _settings.hasRememberedCustom)
                  ChoiceChip(
                    label: const Text('Custom'),
                    selected: _settings.preset == EqualizerPreset.custom,
                    onSelected: (_) => _apply(_settings.selectPreset(EqualizerPreset.custom)),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            Container(
              height: 330,
              padding: const EdgeInsets.fromLTRB(8, 18, 8, 12),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: colors.outline),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < equalizerBandFrequencies.length; index++)
                    Expanded(
                      child: _EqualizerBand(
                        label: equalizerBandLabels[index],
                        value: _settings.gainsDb[index],
                        enabled: _settings.enabled,
                        onChanged: (gain) => setState(() => _settings = _settings.withBandGain(index, gain)),
                        onChangeEnd: (_) => _apply(_settings),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Preamp ${_settings.automaticPreampDb.toStringAsFixed(1)} dB',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _EqualizerBand extends StatelessWidget {
  final String label;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  const _EqualizerBand({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final valueLabel = '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)} dB';
    return Semantics(
      label: '$label equalizer band',
      value: valueLabel,
      slider: true,
      child: Column(
        children: [
          SizedBox(
            height: 24,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(valueLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: value,
                min: -10,
                max: 10,
                divisions: 40,
                label: valueLabel,
                onChanged: enabled ? onChanged : null,
                onChangeEnd: enabled ? onChangeEnd : null,
              ),
            ),
          ),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
