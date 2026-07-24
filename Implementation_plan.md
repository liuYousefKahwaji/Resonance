# Resonance Equalizer, Volume Normalization, and Pocket Vinyl Implementation Plan

Last reviewed: 2026-07-23

Implementation status: completed on 2026-07-23, including the approved Pocket Vinyl feature.

## Executive decision

All three proposals are feasible on the current Windows and Android architecture without adding a new runtime dependency.

| Feature | Feasibility | Main constraint | Recommendation |
| --- | --- | --- | --- |
| Five-band equalizer with presets | High on Windows; medium-high on Android | Windows requires one combined `lavfi` graph. Android exposes device-specific band layouts. | Implement |
| Volume normalization setting | High for local files; intentionally limited for streams in v1 | Loudness must be analyzed and cached without delaying track start. | Implement as cached EBU R128 track normalization |
| Surprise UI: Pocket Vinyl | High | Must remain decorative, lightweight, and respect reduced-motion settings. | Implemented after product approval |

The equalizer should replace the current Bass control rather than stack another effect on top of it. Volume normalization should be a global playback option, independent of the Global/Per-track playback-settings scope.

## Research findings

### Current architecture

- Windows playback uses `media_kit` 1.2.6 with `media_kit_libs_windows_audio` 1.0.9 and controls libmpv through `NativePlayer`.
- Android playback uses `just_audio` 0.9.46 with an `AudioPipeline` containing `AndroidEqualizer` and `AndroidLoudnessEnhancer`.
- Speed, pitch, and bass are stored in `PlaybackAdjustments`, with both global and per-track persistence.
- The player has separate active and incoming backends during crossfade. New EQ and normalization state must be computed independently for both players.
- FFmpeg already ships on Windows and FFmpegKit Audio already ships on Android. No additional decoder/analyzer dependency is needed.
- The PC Companion protocol currently exposes Bass as a scalar, so the protocol and remote UI are part of the migration.

### Empirical Windows equalizer result

The bundled Windows libmpv exposes FFmpeg's `equalizer`, but it does not expose the `bass` filter or the automatic `aresample` converter.

A naïve chain containing five separate mpv equalizer entries failed because libmpv tried to insert the missing resampler between entries. The working structure is:

```text
scaletempo,
format=format=floatp,
lavfi=[equalizer,...,equalizer],
format=format=float
```

A five-band proof graph was tested against all six issue-#46 regression tracks:

- Breaking Benjamin - Blow Me Away
- BULGARIAN ETERNAL FUNK
- ketamine (Ultra Slowed)
- Sem Tempo (Super Slowed)
- FUNK ABNORMAL (SUPER SLOWED)
- REBOLATON (slowed)

All six reached approximately 2.9 seconds after a three-second probe with no buffering and no filter initialization failures. A full equalizer therefore does **not** require replacing the current Windows libmpv package, provided the combined-graph constraint is protected by regression tests.

### Empirical normalization result

The bundled Windows FFmpeg includes `ebur128`, `loudnorm`, `equalizer`, and `alimiter`.

An `ebur128=peak=true` scan of the 3:26 "Blow Me Away" file completed in approximately 1.27 seconds, or 176x realtime, on the current machine. It reported:

- Integrated loudness: -7.1 LUFS
- True peak: +1.9 dBFS

This is fast enough for a single-worker background analysis queue. It is still too slow to place on the playback-critical path, so playback must start immediately and use a cached result when available.

### Dependency health

The installed `ffmpeg_kit_audio_flutter` package is sufficient for the proposed Android scanner and is already used by `AudioEnvelopeAnalyzer`. It is a third-party fork, and the original FFmpegKit project was retired, so dependency maintenance remains a medium-term risk. The new normalization code should sit behind a small analyzer interface so the package-specific implementation can later be replaced without touching `PlayerHandler`.

## UI analysis

### Existing player surface

The desktop player uses a three-zone footer:

- Loop, shuffle, and Playback Settings on the left.
- Previous, play/pause, and next in the center.
- Volume on the right.

Playback Settings currently opens a roughly 300-pixel-wide `AlertDialog` with three horizontal sliders: Speed, Pitch, and Bass. The dialog is already close to its useful height. Five additional sliders, preset controls, normalization status, and explanatory text would make it cramped on desktop and overflow-prone on Android.

The Playback Settings icon is also visually ambiguous (`settings_overscan`). It should become `equalizer_rounded` or `tune_rounded` and retain the existing "Playback Settings" tooltip.

### Existing Settings surface

The main Settings screen already has a suitable visual language:

- Uppercase section labels.
- Rounded, outlined cards.
- One setting per tile.
- Inline switches and compact trailing controls.
- A single scrolling route that works on Windows and Android.

The Playback card is the correct home for the normalization switch and a new Equalizer tile. The existing Playback Settings Scope tile remains useful, but its subtitle must change from "speed, pitch, and bass" to "speed, pitch, and equalizer."

### Proposed information architecture

#### Compact Playback Settings dialog

Keep this dialog fast and lightweight:

1. Speed slider.
2. Pitch slider.
3. Sound preset row showing the active preset and an "Open Equalizer" button.
4. Reset and Close actions.

Do not place all five bands in this dialog.

#### Dedicated Equalizer screen

Open the same screen from:

- The compact Playback Settings dialog.
- Settings → Playback → Equalizer.
- The Android PC Companion's sound-controls card.

Layout:

- Header: Equalizer, enabled switch, and current scope badge (`GLOBAL` or `THIS TRACK`).
- Preset chips: Flat, Bass Boost, Rock, Pop, Vocal, Electronic, and Custom.
- Five vertical sliders centered inside a responsive card.
- A subtle curve behind the sliders showing the current frequency response.
- Read-only "Auto preamp" value below the sliders.
- Reset to Flat action.

Logical bands:

| Label | Center frequency | Purpose |
| --- | ---: | --- |
| Sub | 60 Hz | Sub-bass and kick weight |
| Bass | 230 Hz | Bass body and warmth |
| Mid | 910 Hz | Instrument and vocal body |
| Presence | 3.6 kHz | Definition and attack |
| Air | 12 kHz | Brightness and air |

Each logical band supports -10 dB to +10 dB in 1 dB steps.

Responsive behavior:

- At 500 pixels and above, center the editor at a maximum width of about 680 pixels.
- Below 500 pixels, retain all five vertical sliders in one row with narrower columns and shorter labels.
- Do not use horizontal scrolling for primary controls.
- Use `SafeArea` and allow the screen to scroll if text scaling increases its height.

Accessibility:

- Give every slider a semantic label containing its frequency and signed dB value.
- Announce preset changes.
- Expose the dialog and all controls to accessibility APIs; live inspection did not expose the current modal sliders in the Windows UI Automation tree.
- Respect keyboard arrows, focus order, large text, high contrast, and reduced motion.

### Normalization UI

Add these tiles to the existing Playback card:

1. **Equalizer**
   - Icon: `Icons.equalizer_rounded`
   - Subtitle: active preset, or "Custom · Global/This track"
   - Trailing chevron

2. **Volume normalization**
   - Icon: `Icons.multitrack_audio_rounded` or `Icons.volume_up_rounded`
   - Trailing switch
   - Off subtitle: "Keep each track's original loudness"
   - Enabled and ready: "Target -14 LUFS · prevents sudden volume jumps"
   - Scanning: "Analyzing volume · 12 of 55 tracks"

Normalization is global. It must not move into `PlaybackAdjustments` and must not change when Playback Settings Scope changes.

## Feature 1: five-band equalizer with presets

### Product behavior

- The equalizer is disabled/Flat by default for new users.
- Selecting any non-Flat preset enables it.
- Moving a band changes the active preset to Custom.
- Selecting Flat sets all gains to zero and removes the EQ graph/effect.
- Presets are Resonance-defined and identical across platforms. Do not use Android vendor presets because names and curves differ by device.
- The existing Bass slider is removed. Bass Boost becomes one preset.
- EQ changes preview during playback with a short debounce and a final apply on pointer release.
- EQ changes follow the existing Global/Per-track scope.

Recommended initial preset curves, ordered `[60, 230, 910, 3600, 12000]` Hz:

```text
Flat        [ 0,  0,  0,  0,  0]
Bass Boost  [ 7,  4,  0, -1, -2]
Rock        [ 4,  2, -2,  3,  4]
Pop         [ 1,  3,  2,  2,  1]
Vocal       [-2, -1,  2,  4,  2]
Electronic  [ 5,  2, -1,  2,  5]
```

These curves should be listening-tested on both platforms before freezing them.

### Data model

Add an immutable sound model outside `PlayerHandler`:

```dart
enum EqualizerPreset {
  flat,
  bassBoost,
  rock,
  pop,
  vocal,
  electronic,
  custom,
}

class EqualizerSettings {
  final bool enabled;
  final EqualizerPreset preset;
  final List<double> gainsDb; // exactly five, each clamped to -10...+10
}
```

Change `PlaybackAdjustments` to contain:

- `speed`
- `pitch`
- `equalizer`

Do not keep both `bass` and `equalizer` in the active model; overlapping effects would make clipping and preset behavior difficult to understand.

Add:

- `ValueNotifier<EqualizerSettings> equalizerNotifier`
- `ValueNotifier<bool> equalizerSupportedNotifier`
- `setEqualizerEnabled`
- `setEqualizerPreset`
- `setEqualizerBand`
- `resetEqualizer`

### Windows backend

Replace `buildWindowsAudioFilter(PlaybackAdjustments)` with a builder that owns the complete speed/pitch/EQ chain.

Rules:

1. Always preserve `scaletempo`.
2. For Flat/disabled, return only the pitch-correction chain.
3. For active EQ, build **one** `lavfi=[...]` graph containing all five equalizers.
4. Wrap the graph with native `format=format=floatp` and `format=format=float`.
5. Never emit the unavailable `bass` filter.
6. Format gains with a fixed decimal representation so persistence and filter-string tests remain stable.

Example shape:

```text
scaletempo:scale=1.00000000,
format=format=floatp,
lavfi=[
  equalizer=f=60:t=q:w=0.70:g=...,
  equalizer=f=230:t=q:w=0.70:g=...,
  equalizer=f=910:t=q:w=0.70:g=...,
  equalizer=f=3600:t=q:w=0.70:g=...,
  equalizer=f=12000:t=q:w=0.70:g=...
],
format=format=float
```

Use a latest-value-wins debounce of approximately 60 milliseconds while dragging. Ensure the final value is always applied on `onChangeEnd`.

### Android backend

Continue using the `AndroidEqualizer` already attached to each `AudioPlayer`.

Android vendors expose different band counts, center frequencies, and gain ranges. Treat the UI's five bands as a logical curve:

1. Read device bands and min/max dB from `AndroidEqualizerParameters`.
2. For each device band, interpolate requested gain between surrounding logical control points on a logarithmic frequency axis.
3. Clamp the result to the device-reported range.
4. Enable the effect only when the logical curve is non-Flat.
5. Apply the same curve to an incoming crossfade player's equalizer before it starts.

Remove the bass-specific native bridge after the equalizer migration is stable. It cannot represent five bands, and keeping it would leave two competing effect paths. If the Android equalizer cannot initialize, disable the editor and show "Equalizer unavailable on this device" rather than silently claiming success.

### Clipping prevention

Compute automatic EQ preamp:

```text
preampDb = -max(0, maximumPositiveBandGain)
preampMultiplier = 10 ^ (preampDb / 20)
```

Apply this multiplier in the output-volume layer. It keeps the strongest boosted band at or below the pre-EQ peak. Display the value in the editor so users understand why a heavily boosted preset may sound slightly quieter.

The user's existing 0–200% volume control remains an explicit override. Normalization and auto-preamp should be safe internally, but Resonance cannot promise a true-peak ceiling when the user deliberately enables volume boost above 100%.

### Bass migration

Introduce versioned persistence, for example `per_track_playback_settings_v2`.

On first read:

- Bass 0 maps to Flat.
- Bass greater than 0 maps to Custom:
  - 60 Hz = `bass * 10 dB`
  - 230 Hz = `bass * 6 dB`
  - Other bands = 0 dB
- Preserve old keys for one release so rollback remains possible.
- Write v2 only after a successful decode/migration.

Update global persistence similarly. Add malformed, partial, future-version, and out-of-range migration tests.

### PC Companion compatibility

Keep protocol v1 additive for one compatibility window:

- Add `equalizerSupported`, `equalizerEnabled`, `equalizerPreset`, and `equalizerGains`.
- Add commands `setEqualizerEnabled`, `setEqualizerPreset`, and `setEqualizerGains`.
- Continue sending legacy `bass`/`bassSupported` for older Android clients.
- Map legacy `setBass` to the migrated two-band custom curve.

The updated Android remote should replace its Bass slider with:

- Preset dropdown/chips.
- An "Edit five bands" expansion using the same logical model.

Remove legacy fields in a later explicit protocol-version bump, not in this release.

## Feature 2: volume normalization

### Definition

Implement **track loudness normalization**, not a dynamic compressor.

For each local file:

1. Measure integrated loudness and true peak with FFmpeg's EBU R128 scanner.
2. Cache the measurements.
3. Calculate a constant playback gain.
4. Apply that constant gain through the existing output-volume layer.

This keeps each song's internal dynamics intact while reducing loudness jumps between tracks.

Recommended v1 policy:

- Target: -14 LUFS
- True-peak ceiling: -1 dBTP
- Maximum attenuation: -12 dB
- Maximum positive gain: +6 dB, further limited by the true-peak ceiling

Gain calculation:

```text
loudnessGainDb = targetLufs - integratedLufs
peakSafeGainDb = truePeakCeilingDb - measuredTruePeakDb
trackGainDb = clamp(min(loudnessGainDb, peakSafeGainDb), -12, +6)
trackGainMultiplier = 10 ^ (trackGainDb / 20)
```

### Analyzer service

Create:

- `lib/core/audio/loudness_profile.dart`
- `lib/core/audio/loudness_analyzer.dart`
- `lib/core/audio/loudness_cache.dart`
- `lib/core/audio/loudness_scan_queue.dart`

Mirror the proven platform split in `AudioEnvelopeAnalyzer`:

- Windows: `Process.start` with the shipped `bin/ffmpeg.exe`.
- Android: `FFmpegKit.executeWithArgumentsAsync`.

Use one worker with `-threads 1`. Parse the final `ebur128=peak=true` summary from stderr. Keep parsing isolated and unit-tested with captured Windows and Android log fixtures.

Do not:

- Rewrite audio files.
- Block `loadTrack`.
- Run multiple scans concurrently.
- Scan HTTP streams in v1.
- Apply a newly discovered gain abruptly in the middle of a track.

### Cache

Use a versioned JSON cache in the application-support directory instead of expanding the already large SharedPreferences payload.

Each entry contains:

- Normalized absolute path identity.
- File size.
- Last-modified timestamp.
- Integrated LUFS.
- True peak dBFS.
- Calculated gain dB.
- Analysis version.

Invalidate when size or mtime changes. Write atomically through a temporary file and rename. Cap stale entries and remove entries for deleted tracks during routine cleanup.

### Scheduling

When normalization is enabled:

1. Use cached data immediately.
2. Prioritize the current track.
3. Then prioritize upcoming queue entries so crossfade gains are ready early.
4. Then scan the rest of the active playlist/library in the background.
5. Pause or lower priority while importing, downloading, or performing another FFmpeg-heavy task.

When the current track has no cache entry, start it at unity gain. Once analysis finishes, save the result but wait until the next load of that track to apply it. This avoids a noticeable volume jump halfway through a song.

If the user enables normalization while a cached current track is playing, ramp to the cached gain over roughly 250 milliseconds. Disabling normalization should ramp back to unity over the same period.

### Playback integration

Refactor volume calculation into one pure function:

```text
effectiveOutput =
  userVolume
  * crossfadeMultiplier
  * normalizationMultiplier
  * equalizerPreampMultiplier
```

Keep platform-specific output application after this calculation:

- Windows: media_kit volume property.
- Android: `AudioPlayer.setVolume` plus the existing `AndroidLoudnessEnhancer` when the effective value exceeds 1.

Store separate output contexts for:

- Active player.
- Incoming crossfade player.

The outgoing and incoming tracks can have different normalization gains and EQ curves. Equal-power crossfade multipliers must be applied on top of those independent base gains.

### Stream behavior

For YouTube/HTTP streams in v1:

- Do not download or pre-read the stream for analysis.
- Use unity normalization gain.
- Show normalization as enabled globally, but expose "Not analyzed for streams" in diagnostics/tooltip if needed.

On-the-fly dynamic normalization is explicitly deferred because it would behave differently across the two playback backends and could alter song dynamics.

## Feature 3 proposal: Pocket Vinyl

### Concept

Add a small rotating vinyl record that peeks out from behind the square artwork in the compact Now Playing card.

- The square cover remains fully visible and remains the artwork tap target.
- A dark grooved disc extends about 10–12 pixels beyond the right edge.
- Its center label uses the current player accent/artwork color.
- It rotates slowly while playing.
- It eases to a stop at its current angle when paused.
- A track change crossfades the center label instead of snapping.

This is noticeable in normal use, playful without becoming a full-screen gimmick, and does not duplicate the existing pulse aura.

### Implementation

Create `PocketVinylArtwork`:

- `Stack` with a `CustomPaint` disc behind the existing 42x42 artwork.
- One `AnimationController` at approximately one revolution per 10–12 seconds.
- Wrap the rotating disc in `RepaintBoundary`.
- Stop ticking when paused, the app is not visible, or the widget is offstage.
- Honor `MediaQuery.disableAnimations`/accessible navigation by showing a static disc.
- Exclude the decorative disc from semantics.

Integrate only in `NowPlayingCard` initially. Do not alter library-row artwork or the full standalone artwork until the compact version has been approved visually.

### Approval gate

Do not implement Pocket Vinyl until the user explicitly approves it. Rejecting it does not affect the equalizer or normalization work.

## Implementation sequence

### Phase 0: isolate the playback hotfix

1. Commit or otherwise checkpoint the issue-#46 bass/playback fix before beginning this feature.
2. Preserve the six-track Windows regression set.
3. Record baseline Windows and Android playback/build results.

### Phase 1: sound model and migration

1. Add `EqualizerSettings`, presets, validation, interpolation, and auto-preamp helpers.
2. Version `PlaybackAdjustments` persistence.
3. Add legacy Bass migration.
4. Add notifiers and public `PlayerHandler` APIs.
5. Update PC Companion message models additively.

### Phase 2: platform EQ backends

1. Replace the Windows bass builder with the combined five-band graph builder.
2. Add debounced latest-value application.
3. Replace Android bass application with logical-curve interpolation over device bands.
4. Apply EQ independently to incoming crossfade players.
5. Remove the bass-specific bridge after platform validation.

### Phase 3: equalizer UI

1. Replace Bass in the compact Playback Settings dialog with preset summary/Open Equalizer.
2. Build the responsive Equalizer screen.
3. Add the Equalizer Settings tile.
4. Update Playback Settings Scope copy.
5. Update Android companion controls.
6. Add semantics, keyboard support, and reduced-motion behavior.

### Phase 4: normalization engine and setting

1. Add loudness profile, analyzer, cache, and one-worker scan queue.
2. Add the global normalization notifier and persistence.
3. Add the Settings switch and progress subtitle.
4. Refactor output gain into the documented pure calculation.
5. Carry independent EQ preamp and normalization gain through both crossfade players.
6. Queue current/upcoming/library scans without blocking playback.

### Phase 5: optional Pocket Vinyl

Proceed only after explicit approval:

1. Build the painter/animation widget.
2. Integrate it into the compact Now Playing card.
3. Add reduced-motion and widget tests.

### Phase 6: hardening and release

1. Run formatter, analyzer, and the full Flutter test suite.
2. Build Windows release and Android release.
3. Run the manual regression matrix below.
4. Test on at least two Android devices or one physical device plus one emulator with a different equalizer band layout.
5. Verify a release upgrade from the old Bass persistence format.

## Test strategy

### Unit tests

- Preset arrays and labels are stable.
- Custom edits switch the preset to Custom.
- Gains clamp to -10/+10 dB.
- Android log-frequency interpolation handles fewer, equal, and more than five device bands.
- Auto-preamp is 0 dB for Flat/cut-only curves and offsets the largest positive band.
- Windows filter strings always preserve `scaletempo`.
- Windows active EQ uses exactly one combined `lavfi` graph and explicit format conversion.
- Windows filter strings never contain `bass=`.
- Legacy Bass values migrate correctly.
- Malformed v1/v2 settings fall back safely.
- Loudness summary parsing covers decimals, infinity/invalid files, mono, and missing audio streams.
- Gain calculation obeys both LUFS target and true-peak ceiling.
- Cache invalidates on size/mtime/version changes.
- Effective output gain combines all four multipliers in the correct order.

### Widget tests

- Playback Settings fits at 360, 500, and 1280 pixel widths.
- Equalizer screen has no overflow with 200% text scaling.
- Preset selection updates all sliders.
- Moving one slider selects Custom.
- Scope badge and Settings subtitle update.
- Normalization switch and scan progress are announced.
- Sliders expose frequency and signed dB semantics.
- Unsupported Android EQ shows a disabled explanatory state.
- Pocket Vinyl, if approved, starts/stops correctly and remains static with reduced motion.

### Windows integration matrix

For Flat plus every preset:

1. Play each of the six issue-#46 tracks.
2. Confirm position advances beyond 0:02.
3. Drag each band to both extremes while playing.
4. Change presets repeatedly.
5. Test Speed/Pitch combinations: 0.5/0.5, 1/1, 1.5/0.75, and 2/2.
6. Test click-to-play, Next, Previous, natural completion, Loop One, and Loop All.
7. Test crossfade between tracks using different per-track curves.
8. Relaunch with a non-Flat preset persisted.
9. Confirm no `Audio filter initialized failed`, `aresample not present`, or 0:00 stall.

Convert the successful feasibility probe into a maintained developer smoke tool under `tool/` or a Windows-only integration test.

### Normalization validation

Create or select fixtures with meaningfully different loudness:

1. Analyze both and verify cached LUFS/peak values.
2. Verify calculated gain against hand-computed values.
3. Render a short validation copy with the calculated constant gain and remeasure it.
4. Require output integrated loudness within approximately 1 LU of target when the true-peak limit does not constrain it.
5. Verify true peak does not exceed the configured ceiling before user volume boost/EQ.
6. Verify playback starts immediately on an uncached file.
7. Verify no mid-track jump when a new analysis completes.
8. Verify outgoing/incoming crossfade tracks retain independent gains.
9. Verify mute, 0–200% volume, EQ preamp, pause/resume, seek, and restart.
10. Verify corrupted cache recovery and cancellation during rapid track changes.

## Acceptance criteria

### Equalizer

- Presets and five custom bands audibly change sound on Windows and Android.
- Flat adds no EQ filter/effect and matches the existing neutral playback path.
- All six issue-#46 regression tracks start reliably at every preset.
- EQ never removes speed/pitch correction.
- Global and per-track settings survive restart and migrate from Bass correctly.
- Crossfade applies the correct independent curve to both tracks.
- Unsupported hardware is reported honestly.

### Normalization

- The setting is off by default.
- Enabling it never delays playback.
- Cached local tracks use a constant EBU R128-derived gain.
- Uncached tracks remain stable while scanning and use gain on a later load.
- Streams remain unaffected in v1.
- Crossfades do not jump in loudness because of shared state.
- Cache corruption or FFmpeg failure cannot prevent playback.

### Pocket Vinyl, if approved

- The animation is visible but does not cover metadata or controls.
- It consumes no animation ticks while paused/offstage.
- Reduced-motion users see a static decorative disc.
- Rejecting it requires no changes to the audio implementation.

## Principal risks and mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Reintroducing issue #46 through an invalid Windows graph | Critical | One combined `lavfi` graph, explicit format conversion, six-track smoke test |
| Android equalizer layouts differ by vendor | Medium | Logical curve plus log-frequency interpolation and device-reported clamps |
| EQ clipping | High | Automatic preamp based on maximum positive band |
| Normalization analysis delays playback | High | Never await scanning from `loadTrack`; cache and background worker |
| Crossfade shares the wrong gain/curve | High | Immutable per-player output context for active and incoming players |
| Abrupt volume change when analysis completes | Medium | Do not apply new uncached results mid-track |
| FFmpegKit maintenance changes | Medium | Analyzer interface isolates the package-specific adapter |
| Settings become crowded | Medium | Dedicated Equalizer screen; only summary controls in compact dialog |
| Companion clients become incompatible | Medium | Additive protocol fields and one-release legacy Bass mapping |
| Decorative animation adds jank/accessibility noise | Low | Repaint boundary, lifecycle pause, reduced-motion support, excluded semantics |

## Estimated effort

| Workstream | Estimate |
| --- | ---: |
| Model, persistence migration, and pure tests | 1–2 days |
| Windows and Android EQ backends | 2–3 days |
| Equalizer UI and companion updates | 2–3 days |
| Normalization analyzer, cache, scheduling, and output integration | 3–4 days |
| Cross-platform QA and hardening | 2–3 days |
| Pocket Vinyl, if approved | 0.5–1 day |

Expected total without Pocket Vinyl: approximately 8–12 focused development days.

## Deliberately deferred

- Ten-band or parametric EQ.
- User-defined preset names.
- Album-gain normalization.
- Dynamic compression/limiting.
- Live normalization for HTTP/YouTube streams.
- Writing ReplayGain tags back into user files.
- Cloud syncing EQ profiles or loudness caches.
- Replacing the current FFmpegKit fork solely for this feature.

## Primary references

- mpv audio-filter and `lavfi` behavior: <https://mpv.io/manual/master/#audio-filters>
- FFmpeg equalizer, EBU R128, and loudnorm filters: <https://ffmpeg.org/ffmpeg-filters.html>
- just_audio `AndroidEqualizer`: <https://pub.dev/documentation/just_audio/latest/just_audio/AndroidEqualizer-class.html>
- just_audio equalizer parameters and device-reported bands/ranges: <https://pub.dev/documentation/just_audio/latest/just_audio/AndroidEqualizerParameters-class.html>
- Android platform Equalizer API: <https://developer.android.com/reference/android/media/audiofx/Equalizer>
- Installed FFmpegKit Audio fork capabilities: <https://pub.dev/packages/ffmpeg_kit_audio_flutter>
- Original FFmpegKit retirement notice and package history: <https://github.com/arthenica/ffmpeg-kit>
