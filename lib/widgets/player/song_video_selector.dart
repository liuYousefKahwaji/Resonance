import 'dart:async';
import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';

/// Labels teach the two modes once, then quietly make room for the artwork.
class SongVideoSelector extends StatefulWidget {
  const SongVideoSelector({super.key, required this.video, required this.onChanged, this.collapse = true});
  final bool video, collapse;
  final ValueChanged<bool> onChanged;
  @override
  State<SongVideoSelector> createState() => _SongVideoSelectorState();
}

class _SongVideoSelectorState extends State<SongVideoSelector> {
  Timer? _timer;
  bool _icons = false;
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (widget.collapse) {
      _timer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _icons = true);
      });
    }
  }

  @override
  void didUpdateWidget(covariant SongVideoSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapse != widget.collapse) {
      _icons = false;
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 320);
    if (!widget.collapse) {
      return SegmentedButton<bool>(
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? colors.primary : colors.surface.withValues(alpha: .8),
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? colors.onPrimary : colors.onSurface,
          ),
        ),
        segments: [
          ButtonSegment(value: false, label: Text(context.tr('Song'))),
          ButtonSegment(value: true, label: Text(context.tr('Video'))),
        ],
        selected: {widget.video},
        onSelectionChanged: (values) => widget.onChanged(values.single),
      );
    }
    return Material(
      color: colors.onSurface.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final video in [false, true])
              Semantics(
                button: true,
                selected: widget.video == video,
                label: context.tr(video ? 'Video' : 'Song'),
                child: Tooltip(
                  message: context.tr(video ? 'Video' : 'Song'),
                  child: AnimatedContainer(
                    duration: duration,
                    curve: Curves.easeInOutCubic,
                    decoration: BoxDecoration(
                      color: widget.video == video ? colors.onSurface.withValues(alpha: .13) : Colors.transparent,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: () => widget.onChanged(video),
                      child: AnimatedSize(
                        duration: duration,
                        curve: Curves.easeInOutCubic,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          child: ExcludeSemantics(
                            child: AnimatedSwitcher(
                              duration: duration,
                              child: _icons
                                  ? Icon(
                                      video ? Icons.videocam_rounded : Icons.music_note_rounded,
                                      key: ValueKey('mode-icon-$video'),
                                      size: 20,
                                    )
                                  : Text(
                                      context.tr(video ? 'Video' : 'Song'),
                                      key: ValueKey('mode-label-$video'),
                                      style: TextStyle(fontWeight: FontWeight.w600, color: colors.onSurface),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
