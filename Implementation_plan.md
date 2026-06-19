# Resonance — Plan: Android Support + Drag-to-Reorder

STATUS: APPROVED, READY TO EXECUTE. When told to start, follow this
document directly — do not re-ask the questions already answered in
PART 0.5 below.


## PART 0 — Source-of-truth note

Treat the LATEST uploaded main.dart (the one with the expanded TODO
list: "switch song order", "one window limit", "Iconize", "fade-in and
out in settings", "platfromatize (fix android)", "android background
support", "android notification controls", "android discord rich
presence", etc.) as the current ground truth for main.dart. It already
includes: desktop_drop/DropZone/DropOverlay, MediaKeysService
(Windows-only native hotkey plugin), DiscordPresenceService (already
correctly guarded to non-Android desktop platforms), SharedPreferences-based
discord_enabled toggle, and TrayMode/SettingsService.

For all other files (file_service.dart, track_list.dart, track_tile.dart,
hotkey_service.dart, hotkey_settings_tile.dart, tray_service.dart,
tray_settings.dart, settings_screen.dart, player_controls.dart,
player_modes.dart, volume_bar.dart, seek_bar.dart, album_cover.dart,
discord_presence_service.dart, drop_zone.dart, drop_overlay.dart,
import_track_button.dart, import_service.dart, metadata_cache_service.dart,
media_keys_service.dart, pubspec.yaml), use whatever was most recently
uploaded in this conversation. If a file is referenced but its content
isn't available in context when implementation starts, STOP and ask for
it explicitly rather than reconstructing it from memory — see PART 3
pre-flight checklist.

The new TODOs visible in this latest main.dart ("android notification
controls", "android discord rich presence") confirm the scope of "make
android work" the user wants — notification media controls are already
covered by this plan's section 2.4 (audio_service is Android-native and
should provide this once background playback works correctly). Android
Discord rich presence is explicitly listed as a SEPARATE future TODO by
the user, not something this plan attempts — `dart_discord_presence` is
a desktop-only package; if/when the user wants Discord presence on
Android, that would need a completely different approach (e.g. a
different package or a custom integration) and should be scoped as its
own future task, not bundled into this Android-support pass. Do not
attempt it as part of this plan unless the user explicitly asks during
implementation.


## PART 0.5 — Decisions already confirmed by the user (do not re-ask)

1. **Storage approach: Option A confirmed.** Broad media permission
   (`READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE`), keep using real file
   paths in-place exactly as today, NO file-copying into app sandbox
   storage. Do not implement Option B or C from the original draft.
2. **Android folder already exists** in the project (.gradle, .kotlin
   directories visible — `flutter create` already scaffolded android/
   at some point). Do NOT run `flutter create --platforms=android .`
   or assume Android support needs scaffolding from scratch. This is
   "edit the existing manifest/gradle files," not "create them." Since
   this plan was written without direct filesystem access to the
   user's android/ folder, the FIRST implementation step must be to
   ask the user to upload the current
   android/app/src/main/AndroidManifest.xml (and ideally
   android/app/build.gradle or build.gradle.kts) so edits are made
   against the real file, not a guessed/reconstructed default
   template.
3. **Drag handle UI:** proceed with a dedicated drag-handle icon
   (`Icons.drag_handle`), NOT whole-tile dragging. Reasoning: avoids
   gesture conflicts with tap-to-play and the trailing delete
   IconButton, and gives touch users (Android) a clear, discoverable
   drag affordance.
4. **Execution order: Android support FIRST, then drag-to-reorder,
   then verify drag-to-reorder works on BOTH platforms.** Reasoning the
   user agreed with: drag-to-reorder is a shared feature that needs to
   work on Android too, so it's more efficient to land Android support
   first, then implement+test reordering once on a codebase that
   already runs on both targets — avoids building reorder against
   Windows only and then discovering Android-specific touch-drag
   issues in a separate second pass. The PART 1 / PART 2 section labels
   below are CONTENT groupings only, not execution order — the actual
   execution order is PART 4.


---

## PART 1 — Android support (content)

### 1.1 Desktop-only packages/code — must be conditionally excluded

Confirmed desktop-only (Windows/Linux/macOS), NOT available on Android:

| Package/file | Used in | Android plan |
|---|---|---|
| `hotkey_manager` / `hotkey_manager_windows` | hotkey_service.dart, hotkey_settings_tile.dart, main.dart | Guard `HotkeyService.init(...)` call behind `Platform.isWindows \|\| Platform.isLinux \|\| Platform.isMacOS`. Skip entirely on Android. Hide the "Hotkeys:" section of SettingsScreen on Android. |
| `tray_manager` / `window_manager` | tray_service.dart, tray_settings.dart, main.dart's WindowListener/TrayListener mixins | Guard `windowManager.ensureInitialized()`, `windowManager.setPreventClose(true)`, `TrayService.init()`, and all close-to-tray/minimize-to-tray logic behind the same desktop check. Keep the `WindowListener`/`TrayListener` mixins on `_MainAppState` (harmless if `addListener` is simply never called on Android), but skip `addListener` calls on Android in `_loadTrayModeAndSetup`. Hide "System Tray:" section of SettingsScreen on Android. |
| `desktop_drop` (DropZone/DropOverlay/DropTarget in main.dart's build()) | main.dart, drop_zone.dart, drop_overlay.dart | Wrap the outer `DropTarget` and the `DropZone`+`DropOverlay` usage in main.dart's `build()` with a desktop platform check, falling back to plain `TrackList` (no drop target, no overlay) on Android. |
| `just_audio_windows` | pubspec only | Federated plugin, Windows-only activation. No Dart changes needed. |
| `audio_service_win` | pubspec, Windows backend | Federated/Windows-specific. audio_service's Android support is its primary platform — no changes needed there. |
| `dart_discord_presence` | discord_presence_service.dart, main.dart, settings_screen.dart | Already correctly guarded in main.dart (`Platform.isWindows \|\| Platform.isLinux \|\| Platform.isMacOS) && discordEnabled`). Also hide the Discord toggle UI in SettingsScreen on Android (verify current settings_screen.dart — if unconditional, wrap it). |
| Custom native media_keys_plugin (C++) | windows/runner/*, lib/services/media_keys_service.dart | Lives in windows/runner/, untouched by Android's build. The `MediaKeysService.register(...)` call in main.dart is already guarded behind `Platform.isWindows`. `MediaKeysService.unregister()` in `dispose()`/`_exitApp()` is currently UNGUARDED — verify it's safe to call on Android (the service's own try/catch should make this a harmless no-op returning false/swallowing the MissingPluginException, but confirm empirically on a real Android run rather than assuming). |
| `tray_icon.ico` asset | pubspec assets | Harmless unused asset on Android. No action needed. |
| `restart_app` | settings_screen.dart | Cross-platform (Android included) per official docs, but only reachable from the desktop-only TraySettings restart dialog — naturally unreachable on Android once that section is hidden. |

### 1.2 THE BIG ONE: file path persistence on Android (scoped storage)

CONFIRMED APPROACH: Option A (PART 0.5 item 1). Do not implement
Option B or C.

**The problem, concretely:** `file_picker`'s returned path works
immediately after picking, but on Android 10+ (API 29+), paths sourced
via Android's Storage Access Framework can lose their access grant
after reboot or over time unless the app calls
`ContentResolver.takePersistableUriPermission` — which `file_picker`
does not do automatically, and which this codebase's plain `.path`
usage doesn't trigger. Since `FileService`'s `playlist.m3u8` stores raw
path strings and assumes indefinite validity (true on Windows, NOT
reliably true on Android via SAF), a user could import songs, reboot
their phone, and find some/all tracks unplayable despite the `.m3u8`
still listing them.

**Option A implementation:** request the broad `READ_MEDIA_AUDIO`
(Android 13+) / `READ_EXTERNAL_STORAGE` (Android ≤12) runtime
permission. With this granted, `File(path)` access doesn't depend on
SAF's per-document grant lifecycle at all — same mechanism every other
Android music player (VLC, Poweramp, etc.) uses.

1. Add to `android/app/src/main/AndroidManifest.xml`:
   ```xml
   <uses-permission android:name="android.permission.READ_MEDIA_AUDIO" />
   <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
       android:maxSdkVersion="32" />
   ```
2. Add `permission_handler: ^11.x` to pubspec.yaml (verify latest
   stable version at implementation time via web search/pub.dev rather
   than hardcoding "11.x" blindly).
3. NEW FILE: `lib/platform/android/storage_permission_service.dart`.
   Responsibilities:
   - `Future<bool> hasPermission()` — checks current grant status.
   - `Future<bool> requestPermission()` — triggers the OS prompt,
     returns whether granted.
   - Internally select `Permission.audio` (maps to READ_MEDIA_AUDIO on
     13+) vs `Permission.storage` (maps to READ_EXTERNAL_STORAGE on
     ≤12) based on the device's Android SDK level — verify exact
     `permission_handler` API names/behavior against its current docs
     at implementation time, since this mapping can shift between
     major versions of that package.
4. Wire this into `ImportTrackButton`'s Android flow: before invoking
   `FilePicker.pickFiles(...)`, check/request permission on Android. If
   denied, show an explanatory dialog/snackbar ("Resonance needs access
   to your music files to import songs") with a button to open app
   settings (`openAppSettings()` from permission_handler), and don't
   proceed with the file picker.
5. No changes needed to `FileService`, `audio_service.dart`, or
   `audio_metadata_extractor` usage beyond this — once the broad
   permission is granted, paths behave exactly like Windows paths do
   today (this is the entire point of Option A: zero architecture
   change beyond the permission gate).
6. `FileService`'s `playlist.m3u8` location
   (`getApplicationDocumentsDirectory()`) already works on Android via
   path_provider — no change needed.

### 1.3 UI/UX adjustments for Android

- `player_controls.dart` already has a responsive `screenWidth < 500`
  mobile branch with no desktop-only references — verify it still
  looks right on a real device, but no code change anticipated unless
  testing reveals an issue.
- `SettingsScreen`: hide Hotkeys section, System Tray section, and
  Discord toggle on Android (wrap each in a platform check). Add a
  small Android-only "Permissions" row/entry that calls into
  `storage_permission_service.dart` to let the user re-trigger the
  permission flow or jump to app settings if previously denied.
- Album art (`AlbumCover` showing only a generic icon, not the actual
  `coverData` from `AudioMetadata`) is a pre-existing gap across ALL
  platforms, not Android-specific. NOT in scope for this plan unless
  the user explicitly asks for it as a separate follow-up.

### 1.4 audio_service / background playback + notification controls on Android

This satisfies the "android background support" and "android
notification controls" TODOs directly. `audio_service` is Android-first
in design, and `AudioServiceConfig` in main.dart already has Android
fields filled in (`androidNotificationChannelId`,
`androidNotificationChannelName`, `androidNotificationIcon`). To
implement/verify:

1. Confirm `androidNotificationIcon: 'mipmap/ic_launcher'` resolves —
   should already exist under `android/app/src/main/res/mipmap-*` by
   default; verify against the real project structure once available
   (see pre-flight checklist) rather than assuming.
2. Verify AndroidManifest.xml contains whatever `audio_service` needs
   for its Android foreground service (it normally self-merges this via
   its own manifest, but must be explicitly checked post-build) —
   foreground service declaration/type, and `POST_NOTIFICATIONS`
   permission for Android 13+. Check audio_service's current official
   setup docs (web search) at implementation time, cross-referenced
   against the exact pinned version in pubspec.yaml (`audio_service:
   ^0.18.18` as of the last known pubspec — verify this hasn't
   changed), since manifest requirements can shift between package
   versions.
3. `MediaItem.id` as a raw file path string + `Uri.file()` already
   handles POSIX-style Android paths correctly — no Windows-specific
   quirks apply here (those were specific to Windows drive letters/UNC
   paths and Unicode percent-encoding issues solved earlier in this
   project).
4. Once background playback + notification controls are confirmed
   working, Next/Previous/Play/Pause from the Android notification
   should work out of the box via `audio_service`'s standard Android
   notification integration — this does NOT need the custom
   Win32-specific media_keys_plugin workaround built earlier (that was
   purely for Windows hardware keyboard media keys bypassing a Windows
   SMTC bug; Android's notification controls go through a completely
   different, already-correct code path in audio_service).

### 1.5 Permissions & AndroidManifest.xml summary (all in one place)

- `READ_MEDIA_AUDIO` (API 33+)
- `READ_EXTERNAL_STORAGE` with `maxSdkVersion="32"` (API ≤32)
- Whatever `audio_service` requires for Android 13+ notifications
  (`POST_NOTIFICATIONS`) — verify against current docs at
  implementation time.
- No other new permissions needed for anything currently in scope
  (YouTube integration remains a separate future TODO).


---

## PART 2 — Drag-to-reorder (content)

### 2.1 Current architecture relevant to this feature

- `FileService` owns `playlist.m3u8` (first line `#` header, then one
  path per line). Exposes `writeTextToFile` (overwrite/append),
  `readTextFromFile` (self-healing header), `removeFromPlaylist`
  (filter + full rewrite). NO reorder method exists yet.
- `main.dart`'s `_MainAppState.playlist` (in-memory `List<String>`) is
  the render source of truth, loaded once via `_loadPlaylistFromDisk()`,
  mutated via `setState` on add/delete; `.m3u8` is kept in sync ad-hoc.
- `TrackList` is a plain `ListView.builder`. No reorder capability.
- `TrackTile` is a `StatefulWidget` using `MetadataCacheService` then
  `AudioMetadata.extract` fallback, rendering a `ListTile` wrapped in
  `Material(type: MaterialType.transparency)` (fixes a known "ListTile
  background color or ink splashes may be invisible" warning — keep
  this wrapper, reordering UIs rely on Material ink/elevation for drag
  feedback).
- `PlayerHandler.next()`/`previous()` re-read the playlist FRESH FROM
  DISK every time via `_getCleanPlaylist()` — they never use the UI's
  in-memory list. This means reordering MUST update the actual
  `.m3u8` file's line order, not just the in-memory `playlist` in
  main.dart, or skip behavior would use stale order.
- Shuffle mode's `shuffledList` is a separate shuffled copy, untouched
  by reordering — reordering the real list should still take effect
  once shuffle is turned off.

### 2.2 New FileService method

```dart
Future<void> reorderPlaylist(List<String> newOrder) async {
  final file = await _localFile;
  final buffer = StringBuffer('#\n');
  for (final path in newOrder) {
    buffer.write('$path\n');
  }
  await file.writeAsString(buffer.toString());
}
```
(Exact implementation detail to confirm against the real, current
file_service.dart at implementation time — this mirrors the existing
full-rewrite pattern already used by `removeFromPlaylist`.)

### 2.3 UI change: TrackList → ReorderableListView

Replace `TrackList`'s `ListView.builder` with
`ReorderableListView.builder` (built into Flutter, no new dependency).
Works identically across touch (Android) and mouse (Windows) input.

- Key each item with `ValueKey('$index-${tracks[index]}')` — combining
  position + path guarantees uniqueness even with duplicate imported
  paths.
- Apply the standard `onReorder` index-correction:
  ```dart
  if (newIndex > oldIndex) newIndex -= 1;
  ```
- Drag handle: dedicated `Icons.drag_handle` icon wrapped in
  `ReorderableDragStartListener` (start with the plain, non-delayed
  variant; switch to `ReorderableDelayedDragStartListener` only if
  testing reveals it conflicts with the list's vertical scroll gesture
  on touch). Place as a new leading element alongside the existing
  "now playing" icon, BEFORE it — avoids gesture-arena conflicts with
  `onTap` (play) and the trailing delete `IconButton`.
- WINDOWS-SPECIFIC RISK TO VERIFY POST-IMPLEMENTATION: `TrackList` sits
  inside `DropZone` (desktop_drop) on Windows. Confirm
  `ReorderableListView`'s in-app drag gesture doesn't conflict with
  `DropTarget`'s OS-level file-drag detection — these are two
  different systems (Flutter's gesture arena vs. Windows OS drag-drop
  events) that should be independent, but haven't been combined in
  this codebase before, so verify empirically on a real Windows build.
  On Android this concern doesn't apply (DropZone isn't used there).

### 2.4 Wiring

`TrackList` gets a new required callback:
```dart
final Function(int oldIndex, int newIndex) onReorder;
```

In `main.dart`'s `_MainAppState`:
```dart
void _handleReorder(int oldIndex, int newIndex) async {
  if (newIndex > oldIndex) newIndex -= 1;
  setState(() {
    final item = playlist.removeAt(oldIndex);
    playlist.insert(newIndex, item);
  });
  await FileService().reorderPlaylist(playlist);
}
```
In-memory update first (instant UI feedback), disk write follows
asynchronously — file writes are near-instant, so this is a non-issue
for next()/previous() consistency in practice. Don't add complexity to
guard against a race condition that isn't realistically reachable by a
human pressing buttons.

### 2.5 Deliberately unchanged

Shuffle semantics, loop mode, now-playing highlight logic (keyed by
path, not position), metadata cache validity (keyed by path, not
position), delete behavior (exact path match).

### 2.6 Testing checklist (run on BOTH Windows and Android)

- Reorder via drag handle; confirm `.m3u8` line order updates (check
  the file directly in the app's documents directory on both
  platforms).
- After reordering, confirm Next/Previous follow the NEW order.
- Reorder while shuffle is ON, confirm shuffle keeps playing
  uninterrupted; turn shuffle OFF and confirm non-shuffled order
  reflects the reorder.
- Reorder during active playback; confirm no stutter/restart.
- Windows: confirm drag-and-drop file IMPORT (desktop_drop) still
  works alongside the new reorder gesture.
- Android: confirm touch-drag feels responsive and doesn't fight the
  list's scroll gesture (switch to the delayed-drag variant per 2.3 if
  it does).
- Long-list (50+ tracks) performance check.


---

## PART 3 — Pre-flight checklist (run through before writing ANY code)

1. Confirm which files are needed but not yet present in the active
   conversation context. At minimum, explicitly request from the user:
   - Current `android/app/src/main/AndroidManifest.xml`
   - Current `android/app/build.gradle` or `build.gradle.kts`
   - Current `pubspec.yaml` (confirm exact current dependency versions
     before adding `permission_handler`)
   - `lib/services/metadata_cache_service.dart` and
     `lib/services/media_keys_service.dart` if not already visible in
     this conversation's history
   - Current `lib/screens/settings/settings_screen.dart`,
     `lib/core/storage/file_service.dart`,
     `lib/widgets/library/track_list.dart`,
     `lib/widgets/library/track_tile.dart`,
     `lib/widgets/library/import_track_button.dart` (latest versions,
     in case any have changed since last seen)
   Do not guess/reconstruct any of these from memory — if the user
   can't provide one, say so explicitly and proceed with a clearly
   labeled best-effort reconstruction, flagging the risk plainly.
2. Read every provided file fully before writing any code.
3. Web-search, AT IMPLEMENTATION TIME (don't trust this document's
   specifics blindly if time has passed):
   - audio_service's current Android manifest/permission requirements
     for the exact pinned version in pubspec.yaml.
   - permission_handler's current API surface/version for
     audio/storage permission requests.


## PART 4 — Phased implementation order (ACTUAL execution order)

1. Run the PART 3 pre-flight checklist.
2. Platform-guard all desktop-only initialization in `main.dart`
   (hotkeys, tray/window manager, drop zone/drop target) behind
   `Platform.isWindows || Platform.isLinux || Platform.isMacOS`.
   Verify Windows behavior is unchanged — pure refactor, not a feature
   change, for the desktop side.
3. Hide desktop-only SettingsScreen sections on Android (Hotkeys,
   System Tray, Discord toggle).
4. Add `permission_handler` to pubspec.yaml. Create
   `lib/platform/android/storage_permission_service.dart`. Add the two
   manifest permissions to the REAL AndroidManifest.xml (from PART 3).
   Wire the permission check/request into `ImportTrackButton`'s
   Android flow.
5. Verify/adjust AndroidManifest.xml for audio_service's Android
   requirements (foreground service/notification permission),
   cross-referenced against the actual pinned audio_service version.
6. STOP and ask the user to do a real build+run on an Android
   device/emulator, reporting back before proceeding. Test: import a
   file, confirm library display, metadata extraction, playback,
   background playback survives backgrounding, notification
   play/pause/next/previous controls function, app restart resumes
   library + last-played track, storage permission prompt + re-trigger
   flow works.
7. Once Android is confirmed working, implement drag-to-reorder (PART
   2 content): `reorderPlaylist` in FileService, `ReorderableListView`
   in TrackList, drag handle in TrackTile, wiring in main.dart.
8. Test drag-to-reorder on BOTH Windows and Android per PART 2.6.
9. Final pass: confirm no desktop-specific code leaked into the
   Android build, and no Android-specific code (permission flow)
   accidentally runs/prompts on Windows. Re-read every changed file
   end-to-end once more before considering this done.


## PART 5 — Summary of all files expected to change

Android support:
- lib/main.dart (platform guards around desktop-only init: hotkeys,
  tray/window manager, drop zone/drop target)
- lib/screens/settings/settings_screen.dart (hide desktop-only
  sections, add Android Permissions entry)
- pubspec.yaml (add permission_handler)
- android/app/src/main/AndroidManifest.xml (permissions, possibly
  audio_service-required entries)
- lib/widgets/library/import_track_button.dart (request permission
  before file_picker flow on Android)
- NEW: lib/platform/android/storage_permission_service.dart

Drag-to-reorder:
- lib/core/storage/file_service.dart (add reorderPlaylist method)
- lib/widgets/library/track_list.dart (ListView.builder →
  ReorderableListView.builder)
- lib/widgets/library/track_tile.dart (add drag handle leading icon)
- lib/main.dart (add onReorder wiring — separate change from the
  Android-guarding change above)

No changes anticipated to: audio_service.dart's core playback logic,
hotkey_service.dart/hotkey_settings_tile.dart internals (only call
sites guarded), discord_presence_service.dart (already correctly
guarded), tray_service.dart/tray_settings.dart internals (only call
sites guarded), the native Windows media_keys_plugin C++ code (lives in
windows/runner/, untouched by Android's build).

Explicitly OUT OF SCOPE for this plan (separate future TODOs per the
user's own list): Android Discord rich presence, "one window limit",
"Iconize", "fade-in and out in settings", YouTube integration, themes,
taskbar buttons, UI revamp, album art rendering.
