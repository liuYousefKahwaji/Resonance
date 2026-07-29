# Resonance Issues #50–#56 Implementation Plan

Last reviewed: 2026-07-29

Status: ready for implementation

Scope: GitHub issues #50, #51, #52, #53, #54, #55, and #56.

## Product decisions

| Issue | Decision |
| --- | --- |
| #50 | Obsidian with Full Theme Styling disabled is the classic neutral Resonance appearance. With it enabled, Obsidian receives a complete purple palette like the other full styles. |
| #51 | Add two theme styles named **Quartz** (white/silver) and **Aurum** (gold). Both receive light and dark full palettes and usable accent-only variants. |
| #52 | Metadata saves must complete even if the originating track row leaves the viewport or is disposed. A save stays open and reports success/failure instead of closing first and failing silently. |
| #53 | Long standalone-player metadata uses the existing back-and-forth motion, but the entire intrinsic text width must be rendered so the translated portion becomes visible. |
| #54 | The standalone gradient continuously drifts at a slow, subtle rate. It remains static for reduced-motion users and preserves the existing theme/artwork/OLED rules. |
| #55 | Keep the widget resizable, but declare a 4×2 maximum using Android's supported provider constraints. Treat enforcement as launcher-controlled on Android 12+ and document the pre-Android-12 limitation. |
| #56 | Remember one Custom equalizer curve in Global scope and a separate Custom curve in Per-track scope. Per-track Custom state follows the currently selected track, consistent with the existing per-track adjustment store. |

## Code map

| Area | Primary files |
| --- | --- |
| Theme definitions and generation | `lib/app/theme.dart` |
| Theme persistence and settings UI | `lib/providers/theme_provider.dart`, `lib/screens/settings/settings_screen.dart` |
| Metadata editor | `lib/widgets/library/track_tile.dart` |
| Player file-release coordination | `lib/core/audio/audio_service.dart` |
| Moving overflow text | `lib/widgets/common/overflowing_text.dart` |
| Standalone player gradient | `lib/screens/player/standalone_player_screen.dart` |
| Android widget size declaration | `android/app/src/main/res/xml/resonance_playback_widget_info.xml` |
| Android widget responsive rendering | `android/app/src/main/kotlin/com/example/resonance/widget/ResonancePlaybackWidget.kt` |
| Equalizer state and persistence | `lib/core/audio/equalizer_settings.dart`, `lib/core/audio/playback_preferences.dart`, `lib/core/audio/audio_service.dart` |
| Equalizer UI and companion | `lib/screens/settings/equalizer_screen.dart`, `lib/screens/settings/companion_screen.dart`, `lib/services/companion/companion_protocol.dart`, `lib/services/companion/companion_server_service.dart` |

## #50 — Give Obsidian a distinct full palette

### Confirmed cause

`_Palette` currently defaults to the same neutral surfaces that `buildResonanceTheme(..., fullPalette: false)` uses. Obsidian supplies only its purple accent colors, so its full and accent-only modes resolve to the same backgrounds, surfaces, elevated containers, and borders.

### Implementation

1. In `lib/app/theme.dart`, extract the classic neutral surface values into named constants so accent-only behavior is intentional and cannot silently drift.
2. Give `ResonanceThemeStyle.obsidian` explicit purple-tinted full-palette values rather than inheriting the classic defaults.
3. Keep Obsidian's existing purple primary/secondary accents in accent-only mode.
4. Use this initial full palette:

   | Role | Dark | Light |
   | --- | --- | --- |
   | Base | `#0F0918` | `#F7F1FC` |
   | Surface | `#191024` | `#FEFBFF` |
   | Elevated | `#261738` | `#EEE2F7` |
   | Highest | `#352149` | `#E2D1EF` |
   | Border | `#4A3161` | `#CFB7DF` |

5. Preserve the existing Void/OLED special case and Windows-native geometry.

### Tests

Extend `test/theme_test.dart` to assert:

- Obsidian full and accent-only modes retain the same primary accent.
- Obsidian full and accent-only backgrounds, surfaces, elevated containers, and borders differ in both brightness modes.
- Obsidian accent-only surfaces equal the shared classic Resonance surfaces.
- Every full style still has distinct light and dark environments.

### Acceptance

- Toggling Full Theme Styling visibly changes Obsidian.
- Disabling it produces the normal neutral Resonance appearance.
- Enabling it produces a cohesive purple environment, not only a purple accent.

## #51 — Add Quartz and Aurum theme styles

### Implementation

1. Append `quartz` and `aurum` to `ResonanceThemeStyle` in `lib/app/theme.dart`.
2. Add stable UI/storage labels:

   - `quartz` → `Quartz`
   - `aurum` → `Aurum`

3. Define explicit accent and full-surface palettes.

   **Quartz**

   | Role | Dark | Light |
   | --- | --- | --- |
   | Primary | `#F1F3F5` | `#4B5563` |
   | Secondary | `#C9CED6` | `#6B7280` |
   | Base | `#0C0D0F` | `#F4F5F7` |
   | Surface | `#17191D` | `#FFFFFF` |
   | Elevated | `#23262B` | `#E8EAED` |
   | Highest | `#30343A` | `#DADDDF` |
   | Border | `#464B53` | `#C5C9CF` |

   Quartz uses a bright silver/white accent in dark mode and a darker quartz-gray accent in light mode so controls remain visible.

   **Aurum**

   | Role | Dark | Light |
   | --- | --- | --- |
   | Primary | `#F2C14E` | `#946200` |
   | Secondary | `#D89B26` | `#B7791F` |
   | Base | `#151006` | `#FFF8E7` |
   | Surface | `#211809` | `#FFFCF4` |
   | Elevated | `#30230D` | `#F7EBC7` |
   | Highest | `#413015` | `#EEDCA3` |
   | Border | `#5B4315` | `#D8BE73` |

4. Stop hard-coding white content on every primary-colored control. Derive `ColorScheme.onPrimary` from the actual primary color and use it for elevated/filled controls and selected switch details. This is required for Quartz's light accent on dark surfaces.
5. Keep `ResonanceThemeStyleLabel.fromStorage` backward compatible; unknown or removed values still fall back to Obsidian.
6. The settings dropdown already iterates `ResonanceThemeStyle.values`, so it will expose both styles without a separate UI branch.
7. Update the Themes section in `README.md` to list Quartz and Aurum and describe Quartz's adaptive silver/gray accent.

### Tests

Extend `test/theme_test.dart` to cover:

- Quartz and Aurum labels and storage round-trips.
- Unique primary accents and full surfaces across all seven styles.
- Readable `primary`/`onPrimary` contrast in light and dark modes.
- Quartz buttons do not use white-on-white foreground/background colors.
- Accent-only mode still shares classic surfaces while retaining Quartz/Aurum accents.

### Acceptance

- Quartz and Aurum appear in Settings and persist across restarts.
- Both work in light, dark, full-palette, and accent-only modes.
- Primary controls remain readable, especially Quartz in dark mode.
- Android widget colors update automatically through the existing theme snapshot.

## #52 — Make metadata saves independent of track-row lifetime

### Confirmed failure path

The metadata editor is owned by a lazily built `TrackTile`. Its Save handler currently:

1. pops the dialog immediately;
2. then obtains `PlayerHandler` through `this.context`, which belongs to the source row;
3. performs the write;
4. reports errors only when that row is still mounted.

The final rows are the most likely to leave the active viewport when Android resizes for the keyboard/dialog. If their tile state is disposed, the post-pop provider lookup uses a deactivated context and throws. The catch block then suppresses the error because `mounted` is false. This exactly produces “Save closes, no error, no change,” without requiring either track to have been played.

### Implementation

1. Refactor `_showMetadataEditor` in `lib/widgets/library/track_tile.dart` so the edit operation captures stable dependencies before presenting the dialog:

   - immutable track path;
   - `PlayerHandler`;
   - a stable `ScaffoldMessengerState` or an error field owned by the dialog;
   - metadata read/write callbacks;
   - initial title, artist, and artwork.

2. Introduce a small immutable metadata-edit result/model instead of reading controllers after the dialog has been popped.
3. Keep the dialog open while Save is running:

   - set a `saving` flag;
   - disable Cancel, Save, cover selection, and repeat submission;
   - show compact progress in the Save action;
   - write metadata through the already captured handler;
   - update `MetadataCacheService` and `_CoverArtMemoryCache`;
   - pop only after the write and cache updates succeed.

4. On failure, keep the dialog open and show the actual error. Do not gate error visibility on the source row's `mounted` state.
5. Treat the row repaint as optional:

   - if the original tile is still mounted and still represents the same path, update its local title/artist/cover state;
   - if it was disposed, rely on the shared metadata cache so the rebuilt row immediately shows the saved values.

6. Retain `PlayerHandler.withTrackFileReleased` for current-track safety. No Android playback-release change is required for the reported reproduction because the affected songs were not active.
7. Dispose text controllers in a `finally` path after the dialog completes.

### Testability changes

Expose the editor workflow to tests through either:

- optional metadata reader/writer callbacks on `TrackTile`; or
- a small `TrackMetadataEditor` helper with injectable read/write functions.

Avoid mocking the native `metadata_god` implementation directly in widget tests.

### Tests

Add `test/track_metadata_editor_test.dart` with these regressions:

- Open an editor, remove/dispose the source `TrackTile`, press Save, and verify the writer still runs.
- Verify a successful save closes only after the asynchronous writer completes.
- Verify a failed writer keeps the editor open and displays the error.
- Verify rapid repeated taps cannot launch duplicate writes.
- Verify a rebuilt tile loads the new title/artist from `MetadataCacheService`.
- Verify cover replacement/removal follows the same lifecycle-safe path.

Manual Android validation:

1. Use a playlist long enough to scroll.
2. Edit the second-to-last and last songs with the keyboard open.
3. Test title-only, artist-only, cover replacement, and cover removal.
4. Repeat with playback stopped and with an unrelated track playing.

### Acceptance

- The final two rows save exactly like every other row.
- Save never silently closes on failure.
- Editing remains correct when the source row scrolls away or is rebuilt.

## #53 — Render the complete moving title

### Confirmed cause

`OverflowingText` measures its text without a width constraint and correctly calculates the travel distance. The actual `Text`, however, is still laid out under the viewport's finite width. The paragraph is clipped/truncated at that width before `Transform.translate` moves it, so the animation reveals empty/clipped space instead of the remaining title.

### Implementation

1. Keep `ClipRect` as the fixed viewport.
2. Lay out the moving child at its measured intrinsic width using an explicit `SizedBox`/`OverflowBox` arrangement before applying `Transform.translate`.
3. Keep the current end pauses and back-and-forth motion.
4. Reconfigure when any layout input changes:

   - text;
   - effective text style;
   - text scale;
   - directionality;
   - available width.

5. Preserve a single full-title semantics label and exclude the moving visual duplicate from accessibility.
6. Honor `textAlign` when the text fits; use a deterministic leading-edge origin while it overflows.

### Tests

Extend `test/overflowing_text_test.dart`:

- The rendered paragraph is wider than the viewport for an overflowing title.
- At maximum travel, the translation equals intrinsic width minus viewport width.
- Changing the title, text scale, or viewport width recalculates the distance.
- Short text remains static.
- Semantics exposes the full title once.

Add a standalone-player regression in `test/standalone_player_layout_test.dart` using a very long song name at Android phone width.

### Acceptance

- Every character of an overflowing title and artist becomes visible during the cycle.
- Fitting text remains stationary.
- The text stays clipped to the metadata viewport rather than drawing over controls.

## #54 — Add a subtle animated standalone gradient

### Current behavior

The standalone screen uses an `AnimatedContainer`, but it only interpolates when the theme/artwork colors change. The gradient geometry is static between track changes.

### Implementation

1. Extract the background into a private/stateful `StandaloneGradientSurface` in `lib/screens/player/standalone_player_screen.dart` or a focused `lib/widgets/player/standalone_gradient.dart`.
2. Preserve `standaloneGradientColors` as the single palette-generation entry point.
3. Add a slow repeating controller, initially 24 seconds per cycle.
4. Animate only gradient geometry:

   - horizontal begin/end drift of at most ±0.12 alignment units;
   - middle-stop drift of at most ±0.04;
   - smooth sine/cosine motion with no visible seam when the loop repeats.

5. Continue crossfading palette changes over approximately 520 ms when theme, style, or artwork colors change.
6. Do not tie the gradient to audio amplitude; the existing visualizer already provides reactive motion.
7. Stop or avoid the ticker when:

   - `MediaQuery.disableAnimationsOf(context)` is true;
   - the computed gradient is a single preserved OLED color;
   - the route is under a disabled `TickerMode`.

8. Reduced-motion and OLED modes use the existing static top-to-bottom geometry.
9. Put the gesture surface and player scaffold above the gradient exactly as they are now, so hit testing and swipe behavior do not change.

### Tests

- Add pure tests for deterministic gradient geometry at key controller values.
- Verify the geometry moves within the defined subtle bounds and loops continuously.
- Verify reduced-motion mode has no active animation/ticker.
- Verify preserved OLED surfaces remain solid.
- Retain all current dark/light/artwork gradient color tests.
- Verify track palette changes still animate rather than snapping.

### Acceptance

- The standalone background has visible but restrained continuous motion.
- Controls, text readability, gestures, and artwork transitions are unaffected.
- Reduced-motion users receive a static background.

## #55 — Restrict the Android home-screen widget to 4×2

### Platform decision

Android exposes cell-based values for the target/default size, but maximum resize limits are dimension-based and were added in Android 12/API 31. The launcher ultimately maps those dimensions to its own grid and may ignore maximums on older Android versions.

Use the Android design guidance's conservative minimum bounds for a handheld 4×2 widget:

- `maxResizeWidth="245dp"`
- `maxResizeHeight="115dp"`

These values are intended to prevent crossing into a fifth column or third row while still allowing the host to allocate the larger orientation-specific physical bounds of a 4×2 widget.

### Implementation

1. In `android/app/src/main/res/xml/resonance_playback_widget_info.xml`:

   - keep `targetCellWidth="4"`;
   - keep `targetCellHeight="1"` so the default placement remains the current compact 4×1 widget;
   - keep horizontal and vertical resizing so users can shrink or expand within the supported range;
   - add `maxResizeWidth="245dp"`;
   - add `maxResizeHeight="115dp"`.

2. Move min/max dimensions into named Android dimension resources if resource qualifiers are needed during launcher testing.
3. Keep the compact, standard, and expanded RemoteViews. A two-row allocation should continue selecting the expanded layout through the existing size breakpoints.
4. Add a concise comment in the provider XML explaining that the maximum attributes are API-31 launcher constraints, not runtime resizing commands.
5. Do not attempt to resize a placed widget programmatically; Android does not provide the app with authority to force the launcher's grid allocation.
6. If a pre-Android-12 or noncompliant launcher supplies a larger size, continue filling the provided bounds with the expanded layout rather than rendering a broken or letterboxed widget.

### Verification

- Run Android resource processing/assembly to verify the API-31 attributes compile.
- On Android 12+ with a standard launcher:
  - place the widget at 4×1;
  - resize to 4×2;
  - verify the resize handles cannot cross the declared maximum.
- Test portrait and landscape.
- Test at least one pre-Android-12 device/emulator and document that the launcher may allow larger sizes there.
- Confirm all controls still work in compact, standard, and expanded layouts.

### Acceptance

- Compliant Android 12+ launchers stop resizing at the 4×2 range.
- The default widget remains 4×1.
- Unsupported launchers still render a valid expanded widget if they ignore the cap.

## #56 — Remember Custom equalizer curves by playback scope

### Current behavior

Moving a band changes the active preset to Custom and persists the active equalizer. Selecting a built-in preset constructs a brand-new `EqualizerSettings`, which discards the former custom gains. The Custom chip is also rendered only while Custom is active, so there is no way to return to the curve after switching presets.

### State model

Extend `EqualizerSettings` with an optional remembered custom curve:

```text
enabled
active preset
active gains
remembered custom gains (nullable)
```

Rules:

1. Editing any band activates Custom.
2. A non-flat Custom curve becomes the remembered Custom curve.
3. Selecting Flat or another built-in preset keeps a non-flat remembered Custom curve.
4. Selecting Custom restores the remembered gains.
5. If Custom is returned to five flat/zero bands, its remembered value becomes null.
6. After switching away from a flat Custom curve, the Custom choice disappears.
7. Use a small epsilon when determining flatness so serialization is not affected by floating-point noise.

### Persistence and scope behavior

1. Add optional `customGainsDb` serialization in `lib/core/audio/equalizer_settings.dart`.
2. Keep decoding backward compatible:

   - old active Custom data seeds `customGainsDb` when non-flat;
   - old built-in data loads with no remembered Custom;
   - malformed custom arrays are normalized or ignored.

3. Do not create one unrelated global preference. Keep the remembered curve inside `EqualizerSettings` so existing persistence naturally provides:

   - one Global Custom in `_globalPlaybackAdjustments`;
   - a separate Custom inside each track's `PlaybackAdjustments` in `PlaybackPreferenceStore`.

4. Existing `setPlaybackSettingsScope` already swaps the complete adjustments object. Once the remembered curve is part of that object, changing Global/Per-track scope automatically changes which Custom chip/curve is shown.
5. Preserve the existing v1 bass migration and v2 per-track adjustment store. Adding an optional JSON field does not require discarding existing user data.

### Equalizer APIs

Add intent-preserving model operations instead of constructing replacement presets directly:

- `withBandGain(index, gainDb)`
- `selectPreset(preset)`
- `restoreCustom()`
- `hasRememberedCustom`
- `isFlatCurve`

`selectPreset` must carry the remembered Custom curve forward when activating a built-in preset.

### Main equalizer UI

In `lib/screens/settings/equalizer_screen.dart`:

1. Show the Custom chip when Custom is active or a remembered Custom exists.
2. Selecting a built-in chip calls `_settings.selectPreset(...)`.
3. Selecting Custom restores its remembered curve.
4. When the user flattens Custom and switches away, remove the Custom chip.
5. Listen to `handler.equalizerNotifier` while the screen is open so external scope changes or companion changes cannot leave stale local UI.
6. Retain the current save-on-slider-end behavior and applying indicator.

### Companion compatibility

The Android PC Companion can also replace equalizer state, so it must not erase remembered curves.

1. Add optional `equalizerCustomGainsDb` to state snapshots in:

   - `lib/services/companion/companion_server_service.dart`
   - `lib/services/companion/companion_protocol.dart`

2. Update `lib/screens/settings/companion_screen.dart` to:

   - show Custom when active/remembered;
   - restore remembered gains when selected;
   - carry remembered gains through built-in preset changes.

3. When accepting older `setEqualizer` commands without a custom field, merge them with the handler's current remembered curve instead of deleting it.
4. Keep the new field optional and retain protocol version 1; older clients ignore it and newer clients can fall back when it is absent.

### Tests

Extend `test/audio_effects_test.dart` and `test/playback_preferences_test.dart`:

- A non-flat Custom survives switching to every built-in preset.
- Selecting Custom restores the exact five gains.
- A flat Custom is not retained after switching away.
- JSON round-trips active built-in plus remembered Custom.
- Old Custom JSON migrates to a remembered curve.
- Invalid or incomplete custom arrays are normalized safely.
- Global and per-track remembered curves remain independent.
- Switching scope restores the correct active and remembered curve.
- Two different tracks retain separate per-track Custom curves.

Add/extend UI tests:

- Custom remains visible after selecting a default preset.
- Selecting it restores slider positions.
- It disappears after being flattened and left.
- Scope switching changes the displayed Custom curve.

Extend `test/companion_protocol_test.dart`:

- New custom-gain fields parse correctly.
- Old snapshots still parse.
- A legacy command does not erase the server's remembered Custom curve.

### Acceptance

- Users can tune Custom, switch to a default preset, and return to Custom unchanged.
- Flat Custom curves are not retained.
- Global and Per-track modes expose their own Custom state.
- Per-track Custom follows the current track.
- Restarting the app and using the companion preserve the same behavior.

## Implementation order

1. Theme foundation: #50 and #51 together, including contrast handling and theme tests.
2. Metadata lifecycle fix: #52 and its failing widget regression.
3. Overflow rendering fix: #53.
4. Standalone animated gradient: #54.
5. Android widget provider cap: #55.
6. Equalizer state/schema/UI/companion work: #56.
7. Run the full verification suite and perform Android-specific manual checks.
8. Update README/release notes only after behavior and names are final.

## Verification gates

Run after each relevant group and again at the end:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Android validation:

```powershell
Set-Location android
.\gradlew.bat :app:processDebugResources
.\gradlew.bat :app:assembleDebug
```

Final manual matrix:

| Platform | Checks |
| --- | --- |
| Windows | All theme combinations, long standalone titles, animated gradient, Global/Per-track Custom persistence |
| Android | Same UI checks plus last-two-row metadata editing, keyboard lifecycle, home-widget resizing, and companion EQ behavior |
| Reduced motion | Static standalone gradient; no loss of readability or navigation |
| Restart | Quartz/Aurum selection and both equalizer scope states restore correctly |

## Out of scope

- Replacing `metadata_god` or changing Android storage architecture without evidence of a separate storage-permission failure.
- Adding user-created names or multiple arbitrary equalizer presets; this issue retains one Custom slot per persisted playback scope.
- Programmatically forcing widget dimensions on launchers that ignore provider constraints.
- Audio-reactive gradient motion.
