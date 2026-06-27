// lib/widgets/library/drop_overlay.dart
// Logic: UNCHANGED. Visual only.

import 'package:flutter/material.dart';

class DropOverlay extends StatelessWidget {
  final bool isDragging;

  const DropOverlay({super.key, required this.isDragging});

  @override
  Widget build(BuildContext context) {
    if (!isDragging) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return AnimatedOpacity(
      opacity: isDragging ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 150),
      child: Container(
        color: (isDark ? const Color(0xFF0D0D14) : const Color(0xFFF0EFF5))
            .withValues(alpha: 0.85),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1A1A2A) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: primary.withValues(alpha: 0.5),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: primary.withValues(alpha: 0.15),
                  blurRadius: 30,
                  spreadRadius: 0,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.file_upload_rounded,
                    size: 28,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Drop to import',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? const Color(0xFFE2E8F0)
                        : const Color(0xFF0F172A),
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'MP3, WAV, M4A, OGG, M3U, M3U8',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}