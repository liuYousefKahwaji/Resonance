import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:resonance/services/music_recognition/music_recognition_service.dart';

Future<MusicRecognitionResult?> showMusicRecognitionDialog(BuildContext context, {MusicRecognitionService? service}) =>
    showDialog<MusicRecognitionResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MusicRecognitionDialog(service: service),
    );

class MusicRecognitionDialog extends StatefulWidget {
  final MusicRecognitionService? service;

  const MusicRecognitionDialog({super.key, this.service});

  @override
  State<MusicRecognitionDialog> createState() => _MusicRecognitionDialogState();
}

class _MusicRecognitionDialogState extends State<MusicRecognitionDialog> {
  late final MusicRecognitionService _service = widget.service ?? MusicRecognitionService();
  MusicRecognitionSource? _source;
  MusicRecognitionStage? _stage;
  String? _error;
  bool _running = false;
  bool _closing = false;

  Future<void> _start(MusicRecognitionSource source) async {
    if (_running) return;
    setState(() {
      _source = source;
      _stage = source == MusicRecognitionSource.deviceOutput
          ? MusicRecognitionStage.waitingForAudio
          : MusicRecognitionStage.listening;
      _error = null;
      _running = true;
    });
    try {
      final result = await _service.recognize(
        source,
        onStage: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
      if (!mounted || _closing) return;
      if (result == null) {
        setState(() {
          _running = false;
          _error = 'No song matched that recording. Try again closer to the music or with less background noise.';
        });
        return;
      }
      Navigator.pop(context, result);
    } on MusicRecognitionException catch (error) {
      if (!mounted || _closing) return;
      setState(() {
        _running = false;
        _error = error.message;
      });
    } on FormatException catch (error) {
      if (!mounted || _closing) return;
      setState(() {
        _running = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted || _closing) return;
      setState(() {
        _running = false;
        _error = 'Music recognition failed: $error';
      });
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    if (_running) await _service.cancel();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(24, 22, 14, 0),
        title: Row(
          children: [
            Icon(Icons.graphic_eq_rounded, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            const Expanded(child: Text('Identify a song')),
            IconButton(onPressed: _close, tooltip: 'Close', icon: const Icon(Icons.close_rounded)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, minWidth: 300),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _running ? _buildProgress() : _buildSourcePicker(),
          ),
        ),
        actions: _running
            ? [TextButton(onPressed: _close, child: const Text('Cancel'))]
            : _error != null
            ? [TextButton(onPressed: _close, child: const Text('Close'))]
            : null,
      ),
    );
  }

  Widget _buildSourcePicker() {
    return Column(
      key: const ValueKey('source-picker'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text('Try another source', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
        ] else ...[
          Text('Where should Resonance listen?', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 14),
        ],
        _SourceCard(
          key: const Key('recognition-source-microphone'),
          icon: Icons.mic_rounded,
          title: 'Microphone',
          subtitle: 'Listen to music playing nearby',
          onTap: () => _start(MusicRecognitionSource.microphone),
        ),
        const SizedBox(height: 10),
        _SourceCard(
          key: const Key('recognition-source-device-output'),
          icon: Icons.speaker_rounded,
          title: 'Device audio',
          subtitle: Platform.isAndroid
              ? 'Minimize Resonance, then play audio in another app within 20 seconds'
              : 'Listen directly to audio playing on this computer',
          onTap: () => _start(MusicRecognitionSource.deviceOutput),
        ),
        const SizedBox(height: 12),
        Text(
          'The recording stays on this device. Only an irreversible audio fingerprint is sent for matching.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildProgress() {
    final source = _source;
    return Padding(
      key: ValueKey('progress-${_stage?.name}'),
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 76,
            height: 76,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Positioned.fill(child: CircularProgressIndicator(strokeWidth: 3)),
                Icon(
                  source == MusicRecognitionSource.deviceOutput ? Icons.speaker_rounded : Icons.mic_rounded,
                  size: 34,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text(_stageTitle(), style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(_stageDescription(), style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  String _stageTitle() => switch (_stage) {
    MusicRecognitionStage.requestingPermission => 'Microphone access',
    MusicRecognitionStage.waitingForAudio => 'Waiting for device audio',
    MusicRecognitionStage.listening => 'Listening…',
    MusicRecognitionStage.fingerprinting => 'Analyzing locally…',
    MusicRecognitionStage.matching => 'Finding the song…',
    null => 'Preparing…',
  };

  String _stageDescription() => switch (_stage) {
    MusicRecognitionStage.requestingPermission => 'Approve the permission request to begin listening.',
    MusicRecognitionStage.waitingForAudio when Platform.isAndroid =>
      'Approve audio capture, then switch to the app playing music. Listening stops if no audio is heard in 20 seconds.',
    MusicRecognitionStage.waitingForAudio => 'Start playback on this computer within 20 seconds.',
    MusicRecognitionStage.listening => 'Keep the music playing clearly for a few seconds.',
    MusicRecognitionStage.fingerprinting => 'Creating a private fingerprint from the captured audio.',
    MusicRecognitionStage.matching => 'Checking the fingerprint against the music catalog.',
    null => 'Preparing audio capture.',
  };
}

class _SourceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SourceCard({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 3),
                    Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
