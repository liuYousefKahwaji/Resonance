// lib/widgets/youtube/android_youtube.dart
//
// Shown on Android when the user taps the YouTube download button.
// yt-dlp requires native binaries that cannot run on Android without
// root/Termux, so downloading is desktop-only for now.

import 'package:flutter/material.dart';

class AndroidYoutube extends StatelessWidget {
  const AndroidYoutube({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.desktop_windows_rounded,
                size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Desktop Only',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(
              'YouTube downloading requires the desktop version of Resonance '
              '(Windows, macOS, or Linux). '
              'Open Resonance on your computer to download and sync tracks.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    );
  }
}