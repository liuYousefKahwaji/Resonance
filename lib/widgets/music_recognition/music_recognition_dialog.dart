import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:resonance/platform/android/android_entrypoint_service.dart';
import 'package:resonance/services/music_recognition/music_recognition_service.dart';

abstract class MusicRecognitionDialogEntrypoint {
  const MusicRecognitionDialogEntrypoint();

  Future<bool> beginRecognition({required bool fromTile});

  Future<void> updateRecognitionStage(String stage);

  Future<bool> completeRecognition({
    required bool success,
    required bool canOpenDirectly,
    MusicRecognitionResult? result,
    String? message,
  });

  Future<void> resetRecognition();

  Future<String> getDefaultRecognitionSource();

  Future<void> setDefaultRecognitionSource(String source);
}

class _AndroidMusicRecognitionDialogEntrypoint extends MusicRecognitionDialogEntrypoint {
  const _AndroidMusicRecognitionDialogEntrypoint();

  @override
  Future<bool> beginRecognition({required bool fromTile}) =>
      AndroidEntrypointService.beginRecognition(fromTile: fromTile);

  @override
  Future<void> updateRecognitionStage(String stage) => AndroidEntrypointService.updateRecognitionStage(stage);

  @override
  Future<bool> completeRecognition({
    required bool success,
    required bool canOpenDirectly,
    MusicRecognitionResult? result,
    String? message,
  }) => AndroidEntrypointService.completeRecognition(
    success: success,
    canOpenDirectly: canOpenDirectly,
    title: result?.title,
    artist: result?.artist,
    album: result?.album,
    artworkUrl: result?.artworkUrl,
    shazamUrl: result?.shazamUrl,
    message: message,
  );

  @override
  Future<void> resetRecognition() => AndroidEntrypointService.resetRecognition();

  @override
  Future<String> getDefaultRecognitionSource() => AndroidEntrypointService.getDefaultRecognitionSource();

  @override
  Future<void> setDefaultRecognitionSource(String source) =>
      AndroidEntrypointService.setDefaultRecognitionSource(source);
}

Future<MusicRecognitionResult?> showMusicRecognitionDialog(
  BuildContext context, {
  MusicRecognitionService? service,
  MusicRecognitionDialogEntrypoint? entrypoint,
  MusicRecognitionSource? initialSource,
  bool tileTriggered = false,
  bool? androidOverride,
}) => showDialog<MusicRecognitionResult>(
  context: context,
  barrierDismissible: false,
  builder: (_) => MusicRecognitionDialog(
    service: service,
    entrypoint: entrypoint,
    initialSource: initialSource,
    tileTriggered: tileTriggered,
    androidOverride: androidOverride,
  ),
);

class MusicRecognitionDialog extends StatefulWidget {
  final MusicRecognitionService? service;
  final MusicRecognitionDialogEntrypoint? entrypoint;
  final MusicRecognitionSource? initialSource;
  final bool tileTriggered;
  final bool? androidOverride;

  const MusicRecognitionDialog({
    super.key,
    this.service,
    this.entrypoint,
    this.initialSource,
    this.tileTriggered = false,
    this.androidOverride,
  });

  @override
  State<MusicRecognitionDialog> createState() => _MusicRecognitionDialogState();
}

class _MusicRecognitionDialogState extends State<MusicRecognitionDialog> {
  late final MusicRecognitionService _service = widget.service ?? MusicRecognitionService();
  late final MusicRecognitionDialogEntrypoint _entrypoint =
      widget.entrypoint ?? const _AndroidMusicRecognitionDialogEntrypoint();
  MusicRecognitionSource? _source;
  MusicRecognitionStage? _stage;
  String? _error;
  bool _running = false;
  bool _acquiring = false;
  bool _closing = false;
  bool _closeOwnsRelease = false;
  bool _ownsScan = false;
  MusicRecognitionSource _defaultSource = MusicRecognitionSource.microphone;

  bool get _isAndroid => widget.androidOverride ?? Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDefaultSource());
    final initialSource = widget.initialSource;
    if (initialSource != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_start(initialSource));
      });
    }
  }

  Future<void> _loadDefaultSource() async {
    if (!_isAndroid) return;
    final source = await _entrypoint.getDefaultRecognitionSource();
    if (!mounted) return;
    setState(() {
      _defaultSource = source == 'deviceOutput'
          ? MusicRecognitionSource.deviceOutput
          : MusicRecognitionSource.microphone;
    });
  }

  Future<void> _setDefaultSource(MusicRecognitionSource source) async {
    setState(() => _defaultSource = source);
    await _entrypoint.setDefaultRecognitionSource(
      source == MusicRecognitionSource.microphone ? 'microphone' : 'deviceOutput',
    );
  }

  Future<void> _start(MusicRecognitionSource source) async {
    if (_running || _acquiring || _closing) return;
    _acquiring = true;
    bool acquired;
    try {
      acquired = await _entrypoint.beginRecognition(fromTile: widget.tileTriggered);
    } catch (error) {
      _acquiring = false;
      if (mounted && !_closing) {
        setState(() => _error = 'Could not start music recognition: $error');
      }
      return;
    }
    _acquiring = false;
    if (!acquired) {
      if (mounted && !_closing) {
        setState(() => _error = 'Another music scan is already running.');
      }
      return;
    }
    _ownsScan = true;
    try {
      if (!mounted || _closing) return;
      setState(() {
        _source = source;
        _stage = source == MusicRecognitionSource.deviceOutput
            ? MusicRecognitionStage.waitingForAudio
            : MusicRecognitionStage.listening;
        _error = null;
        _running = true;
      });
      final result = await _service.recognize(
        source,
        onStage: (stage) {
          unawaited(_entrypoint.updateRecognitionStage(stage.name).catchError((_) {}));
          if (mounted) setState(() => _stage = stage);
        },
      );
      if (_closing) return;
      if (result == null) {
        await _finishWithFailure(
          'No song matched that recording. Try again closer to the music or with less background noise.',
        );
        return;
      }
      var deferred = false;
      try {
        deferred = await _entrypoint.completeRecognition(success: true, canOpenDirectly: mounted, result: result);
      } catch (_) {
        // The match is still useful locally if Android could not persist it.
      }
      if (!mounted || _closing) return;
      _closing = true;
      Navigator.pop(context, deferred ? null : result);
    } on MusicRecognitionException catch (error) {
      await _finishWithFailure(error.message);
    } on FormatException catch (error) {
      await _finishWithFailure(error.message);
    } catch (error) {
      await _finishWithFailure('Music recognition failed: $error');
    } finally {
      if (!_closeOwnsRelease) await _releaseRecognition();
    }
  }

  Future<void> _finishWithFailure(String message) async {
    if (_closing) return;
    var deferred = false;
    try {
      deferred = await _entrypoint.completeRecognition(success: false, canOpenDirectly: mounted, message: message);
    } catch (_) {
      // Keep the in-app retry available when native completion reporting fails.
    }
    if (!mounted || _closing) return;
    if (deferred) {
      _closing = true;
      Navigator.pop(context);
      return;
    }
    setState(() {
      _running = false;
      _error = message;
    });
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _closeOwnsRelease = true;
    try {
      if (_running) {
        try {
          await _service.cancel();
        } catch (_) {
          // Native cancellation can race service teardown; cleanup must continue.
        }
        try {
          await _entrypoint.completeRecognition(
            success: false,
            canOpenDirectly: mounted,
            message: 'Music recognition was cancelled.',
          );
        } catch (_) {
          // The reset below still has to release the scan reservation.
        }
      }
    } finally {
      await _releaseRecognition();
      _closeOwnsRelease = false;
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _releaseRecognition() async {
    if (!_ownsScan) return;
    _ownsScan = false;
    try {
      await _entrypoint.resetRecognition();
    } catch (_) {
      // Do not strand the dialog when the Android activity is already tearing down.
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: AlertDialog(
        key: const Key('music-recognition-dialog'),
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.graphic_eq_rounded, size: 21, color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 10),
            const Expanded(child: Text('Identify a song')),
            IconButton(
              onPressed: _close,
              tooltip: 'Close',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        content: ConstrainedBox(
          key: const Key('music-recognition-content'),
          constraints: const BoxConstraints(maxWidth: 440),
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
          Text(
            'Choose how Resonance listens.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
        ],
        _SourceCard(
          key: const Key('recognition-source-microphone'),
          icon: Icons.mic_rounded,
          title: _isAndroid ? 'Listen with microphone' : 'Microphone',
          subtitle: _isAndroid
              ? 'Nearby music and this phone’s speakers. No casting prompt.'
              : 'Listen to music playing nearby',
          recommended: _isAndroid,
          isDefault: _isAndroid && _defaultSource == MusicRecognitionSource.microphone,
          onSetDefault: _isAndroid ? () => _setDefaultSource(MusicRecognitionSource.microphone) : null,
          onTap: () => _start(MusicRecognitionSource.microphone),
        ),
        const SizedBox(height: 8),
        _SourceCard(
          key: const Key('recognition-source-device-output'),
          icon: Icons.speaker_rounded,
          title: _isAndroid ? 'Capture device audio' : 'Device audio',
          subtitle: _isAndroid
              ? 'Direct audio for headphones or failed mic scans. Android shows a capture prompt.'
              : 'Listen directly to audio playing on this computer',
          isDefault: _isAndroid && _defaultSource == MusicRecognitionSource.deviceOutput,
          onSetDefault: _isAndroid ? () => _setDefaultSource(MusicRecognitionSource.deviceOutput) : null,
          onTap: () => _start(MusicRecognitionSource.deviceOutput),
        ),
        if (_isAndroid) ...[
          const SizedBox(height: 9),
          const _InfoRow(icon: Icons.star_outline_rounded, text: 'Star sets the Quick Settings tile source.'),
        ],
        const SizedBox(height: 7),
        const _InfoRow(
          icon: Icons.privacy_tip_outlined,
          text: 'Audio stays on-device; only an irreversible fingerprint is sent for matching.',
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
  final bool recommended;
  final bool isDefault;
  final VoidCallback? onSetDefault;

  const _SourceCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.recommended = false,
    this.isDefault = false,
    this.onSetDefault,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final primary = colors.primary;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: isDefault ? primary.withValues(alpha: 0.55) : colors.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 21, color: primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (onSetDefault != null) ...[
                    const SizedBox(width: 2),
                    SizedBox.square(
                      dimension: 36,
                      child: IconButton(
                        onPressed: isDefault ? null : onSetDefault,
                        tooltip: isDefault ? 'Quick Settings tile default' : 'Use for Quick Settings tile',
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(
                          foregroundColor: colors.onSurfaceVariant,
                          disabledForegroundColor: primary,
                        ),
                        iconSize: 21,
                        icon: Icon(isDefault ? Icons.star_rounded : Icons.star_border_rounded),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.25),
                  children: [
                    if (recommended)
                      TextSpan(
                        text: 'Recommended · ',
                        style: TextStyle(color: primary, fontWeight: FontWeight.w600),
                      ),
                    TextSpan(text: subtitle),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.25);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: colors.onSurfaceVariant),
        ),
        const SizedBox(width: 7),
        Expanded(child: Text(text, style: style)),
      ],
    );
  }
}
