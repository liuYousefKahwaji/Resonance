# Resonance Issues #16–#18 Implementation Plan

## Scope

- #16: remove local-track loading UI entirely and eliminate avoidable delay when selecting or switching tracks.
- #17: give the standalone player its own fixed, non-scrollable layout with smaller artwork, metadata directly above larger controls, and animated overflow text.
- #18: replace the dot/line perimeter visualizer with a smooth expanding pulse that renders identically on Windows and Android.

## Execution Checklist

1. Preserve the existing uncommitted playlist/standalone navigation work and build the new changes on top of it.
2. Move album-art extraction and persistence off the playback-critical path; start Windows playback on tap-down while retaining double-click standalone navigation, and remove redundant presence/settings work and full-file Unicode-path copies.
3. Normalize public playback state so local files can never advertise loading or buffering, while streamed tracks retain genuine loading feedback.
4. Recompose the standalone screen as one bounded, non-scrollable surface: an accent-tinted light/dark gradient, transparent app bar and controls, smaller responsive artwork, and larger transport buttons.
5. Add an overflow-aware animated text widget that only moves when metadata exceeds its available width.
6. Decode a low-rate mono PCM envelope after playback has started, using one background FFmpeg thread and a bounded disk/memory cache so analysis never blocks source switching.
7. Sample the real RMS envelope at the live playback position and render the same filled pulse around both the Currently Playing card and standalone artwork, with a quiet static glow while paused or before analysis is ready.
8. Add focused unit/widget coverage for local loading normalization, RMS envelope response, pulse animation, animated overflow behavior, theme-aware gradients, and fixed standalone layout.
9. Run Dart formatting, Flutter tests, and static analysis; address regressions introduced by this scope.
10. Launch `flutter build windows --release` and `flutter build apk --release` concurrently in separate processes and report both results.
