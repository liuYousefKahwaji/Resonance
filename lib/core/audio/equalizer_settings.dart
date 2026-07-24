import 'dart:math' as math;

import 'package:flutter/foundation.dart';

const List<double> equalizerBandFrequencies = <double>[60, 230, 910, 3600, 12000];
const List<String> equalizerBandLabels = <String>['60 Hz', '230 Hz', '910 Hz', '3.6 kHz', '12 kHz'];

enum EqualizerPreset { flat, bassBoost, rock, pop, vocal, electronic, custom }

extension EqualizerPresetLabel on EqualizerPreset {
  String get label => switch (this) {
    EqualizerPreset.flat => 'Flat',
    EqualizerPreset.bassBoost => 'Bass Boost',
    EqualizerPreset.rock => 'Rock',
    EqualizerPreset.pop => 'Pop',
    EqualizerPreset.vocal => 'Vocal',
    EqualizerPreset.electronic => 'Electronic',
    EqualizerPreset.custom => 'Custom',
  };
}

@immutable
class EqualizerSettings {
  final bool enabled;
  final EqualizerPreset preset;
  final List<double> gainsDb;

  EqualizerSettings({
    this.enabled = true,
    this.preset = EqualizerPreset.flat,
    List<double> gainsDb = const <double>[0, 0, 0, 0, 0],
  }) : gainsDb = List<double>.unmodifiable(_normalizeGains(gainsDb));

  static final EqualizerSettings flat = EqualizerSettings();

  factory EqualizerSettings.forPreset(EqualizerPreset preset) {
    final gains = switch (preset) {
      EqualizerPreset.flat => const <double>[0, 0, 0, 0, 0],
      EqualizerPreset.bassBoost => const <double>[7, 4, 0, -1, -2],
      EqualizerPreset.rock => const <double>[4, 2, -2, 3, 4],
      EqualizerPreset.pop => const <double>[1, 3, 2, 2, 1],
      EqualizerPreset.vocal => const <double>[-2, -1, 2, 4, 2],
      EqualizerPreset.electronic => const <double>[5, 2, -1, 2, 5],
      EqualizerPreset.custom => const <double>[0, 0, 0, 0, 0],
    };
    return EqualizerSettings(preset: preset, gainsDb: gains);
  }

  factory EqualizerSettings.fromLegacyBass(double bass) {
    final strength = bass.clamp(0.0, 1.0);
    if (strength <= 0) return EqualizerSettings.flat;
    return EqualizerSettings(preset: EqualizerPreset.custom, gainsDb: <double>[strength * 10, strength * 6, 0, 0, 0]);
  }

  factory EqualizerSettings.fromJson(Object? value) {
    if (value is! Map) return EqualizerSettings.flat;
    final presetName = value['preset'] as String?;
    final preset =
        EqualizerPreset.values.where((item) => item.name == presetName).firstOrNull ?? EqualizerPreset.custom;
    final rawGains = value['gainsDb'];
    final gains = rawGains is List
        ? rawGains.map((gain) => (gain as num?)?.toDouble() ?? 0).toList()
        : EqualizerSettings.forPreset(preset).gainsDb;
    return EqualizerSettings(enabled: value['enabled'] as bool? ?? true, preset: preset, gainsDb: gains);
  }

  bool get isActive => enabled && gainsDb.any((gain) => gain.abs() >= 0.01);

  double get automaticPreampDb {
    if (!isActive) return 0;
    return -math.max(0.0, gainsDb.reduce(math.max));
  }

  double get automaticPreampMultiplier => math.pow(10.0, automaticPreampDb / 20.0).toDouble();

  double get legacyBassEquivalent => (gainsDb.first / 10.0).clamp(0.0, 1.0);

  EqualizerSettings copyWith({bool? enabled, EqualizerPreset? preset, List<double>? gainsDb}) => EqualizerSettings(
    enabled: enabled ?? this.enabled,
    preset: preset ?? this.preset,
    gainsDb: gainsDb ?? this.gainsDb,
  );

  EqualizerSettings withBandGain(int index, double gainDb) {
    if (index < 0 || index >= gainsDb.length) return this;
    final updated = List<double>.from(gainsDb);
    updated[index] = gainDb.clamp(-10.0, 10.0);
    return copyWith(enabled: true, preset: EqualizerPreset.custom, gainsDb: updated);
  }

  Map<String, Object?> toJson() => <String, Object?>{'enabled': enabled, 'preset': preset.name, 'gainsDb': gainsDb};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EqualizerSettings &&
          enabled == other.enabled &&
          preset == other.preset &&
          listEquals(gainsDb, other.gainsDb);

  @override
  int get hashCode => Object.hash(enabled, preset, Object.hashAll(gainsDb));

  static List<double> _normalizeGains(List<double> gains) => List<double>.generate(
    equalizerBandFrequencies.length,
    (index) => (index < gains.length ? gains[index] : 0.0).clamp(-10.0, 10.0).toDouble(),
  );
}

/// Maps Resonance's stable five logical bands to a device-specific Android
/// equalizer layout. Interpolation happens in logarithmic frequency space,
/// matching how the bands are presented and perceived.
double interpolatedEqualizerGain(double centerFrequency, EqualizerSettings settings) {
  if (!settings.enabled || centerFrequency <= 0) return 0;
  final frequency = centerFrequency.clamp(equalizerBandFrequencies.first, equalizerBandFrequencies.last);
  if (frequency <= equalizerBandFrequencies.first) return settings.gainsDb.first;
  if (frequency >= equalizerBandFrequencies.last) return settings.gainsDb.last;
  final logFrequency = math.log(frequency);
  for (var index = 0; index < equalizerBandFrequencies.length - 1; index++) {
    final lower = equalizerBandFrequencies[index];
    final upper = equalizerBandFrequencies[index + 1];
    if (frequency <= upper) {
      final fraction = (logFrequency - math.log(lower)) / (math.log(upper) - math.log(lower));
      return settings.gainsDb[index] + (settings.gainsDb[index + 1] - settings.gainsDb[index]) * fraction;
    }
  }
  return settings.gainsDb.last;
}
