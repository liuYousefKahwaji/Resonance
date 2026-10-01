import 'dart:async';

import 'package:flutter/material.dart';
import 'package:resonance/app/resonance_motion.dart';

class VersionTapTracker {
  int _tapCount = 0;

  bool registerTap() {
    _tapCount++;
    if (_tapCount < 5) return false;
    _tapCount = 0;
    return true;
  }
}

class IDontKnowPage extends StatefulWidget {
  const IDontKnowPage({super.key, this.onExit});

  final VoidCallback? onExit;

  @override
  State<IDontKnowPage> createState() => _IDontKnowPageState();
}

class _IDontKnowPageState extends State<IDontKnowPage> {
  static const _answers = <String>[
    'The record is quiet. Suspiciously quiet.',
    'Have you tried turning the song off and on again?',
    'The record says your next song should be louder.',
    'A mysterious DJ approves of your taste.',
    'No answers here. Only excellent vibes.',
    'You have unlocked absolutely nothing. Congratulations!',
  ];

  int _spins = 0;
  Timer? _exitTimer;

  void _askTheRecord() {
    if (_spins >= 13) return;
    setState(() => _spins++);
    if (_spins == 13) {
      _exitTimer = Timer(const Duration(seconds: 3), () => widget.onExit?.call());
    }
  }

  @override
  void dispose() {
    _exitTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    final answer = switch (_spins) {
      10 => 'You should stop now.',
      11 => 'Stop now.',
      12 => 'Do it again, I dare you.',
      13 => 'Okay, you asked for it.',
      _ => _answers[_spins % _answers.length],
    };
    final motion = resonanceDuration(context, const Duration(milliseconds: 700));

    return Scaffold(
      appBar: AppBar(title: const Text('I DONT KNOW PAGE')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'You found the B-side of Settings.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'It has no settings. It does have a record.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted),
                  ),
                  const SizedBox(height: 36),
                  Semantics(
                    label: 'Spin the record',
                    button: true,
                    child: InkWell(
                      key: const Key('secret-record'),
                      customBorder: const CircleBorder(),
                      onTap: _askTheRecord,
                      child: AnimatedRotation(
                        turns: _spins.toDouble(),
                        duration: motion,
                        curve: Curves.easeOutCubic,
                        child: Container(
                          width: 230,
                          height: 230,
                          padding: const EdgeInsets.all(17),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF12121B),
                            border: Border.all(color: primary.withValues(alpha: 0.65), width: 3),
                            boxShadow: [
                              BoxShadow(color: primary.withValues(alpha: 0.22), blurRadius: 34, spreadRadius: 4),
                            ],
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white24, width: 2),
                            ),
                            child: Center(
                              child: Container(
                                width: 100,
                                height: 100,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: primary,
                                  border: Border.all(color: Colors.white54, width: 2),
                                ),
                                child: Icon(Icons.music_note_rounded, size: 48, color: theme.colorScheme.onPrimary),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  AnimatedSwitcher(
                    duration: resonanceDuration(context, const Duration(milliseconds: 220)),
                    child: Text(
                      answer,
                      key: ValueKey(_spins),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _askTheRecord,
                    icon: const Icon(Icons.help_outline_rounded),
                    label: const Text('Ask the record'),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'No music was harmed in the making of this page.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
