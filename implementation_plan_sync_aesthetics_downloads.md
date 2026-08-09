# Resonance Sync, Lyrics, Queue Artwork, Download Queue, and Android QR Import Plan

Last reviewed: 2026-08-09

Implementation status: implemented and validated on 2026-08-09 (static analysis, 196 Flutter tests, and release builds recorded in the implementation handoff)

## Executive decisions

| Area | Decision |
| --- | --- |
| Product name | Use **Resonance Sync** in the UI and `sync` in code/protocol names. |
| Supported Sync devices | Android host and Android peers only in the first release. Windows keeps PC Companion but does not host or join Sync. |
| Network model | Direct local WebSocket connection over the same Wi-Fi network or a host phone's hotspot. No backend and no audio relaying. |
| Pairing | Host displays a session QR code; peers scan it. The QR contains the host address, port, session ID, protocol version, and a short-lived random token. |
| Music sources | Only canonical streamed/YouTube entries participate in Sync. Each phone resolves and plays the source independently. |
| Mixed host playlist | Starting Sync from a mixed local/stream playlist creates and activates a persistent, uniquely named `Sync` playlist containing the streamed entries in their original order. |
| Fully streamed host playlist | Use the existing playlist directly; do not create a redundant host playlist. |
| No streamed entries | Create an empty `Sync` playlist and let the host add streams normally. |
| Peer playlist | Create a persistent `Sync - <host>` playlist on the peer, update it while the session is active, and retain it after leaving. |
| Session queue changes | Host additions, removals, and reorders of streamed entries propagate live. The peer queue is read-only. |
| Playback authority | Host controls play, pause, seek, next, previous, queue selection, loop, shuffle, speed, pitch, and equalizer. Each phone keeps independent volume. |
| Crossfade | Suppress crossfade for the duration of Sync without overwriting the user's saved preference. Restore normal behavior automatically when Sync ends. |
| Lyrics following | Timed lyrics follow by default. A real user scroll pauses following; the Follow button recenters the active line and resumes it. |
| Download queue lifetime | Jobs continue when Search is covered, closed, or backgrounded while the process remains alive. Jobs are intentionally not restored after full process termination in v1. |
| Download concurrency | One active download globally. Rapid presses enqueue FIFO and failures do not stop later entries. |
| Android download queue UI | Persistent compact progress bar on Search; tap or drag upward to open a `DraggableScrollableSheet`. |
| Windows download queue UI | Persistent right-side queue panel while queue mode is enabled or work remains. |
| Android QR images | Keep camera scanning and add multi-image upload using the existing local QR decoder. |

## Scope and non-goals

This plan covers:

- A coherent app-wide visual and motion polish pass.
- A substantially richer lyrics highlight and explicit follow control.
- Album artwork for every visible entry in the Windows and Android playback queues.
- Android-to-Android synchronized stream playback without a backend.
- A sequential, process-lifetime download queue controlled from Search.
- Android playlist QR import from one or more saved images.

The first release does not include:

- iOS support; this repository has no iOS target.
- Windows participation in Resonance Sync.
- Internet-wide Sync between unrelated mobile networks.
- Audio forwarding from host to peers.
- Local-file transfer or playback in Sync.
- Crossfade during Sync.
- Guest queue editing or guest transport controls.
- Persistent download-job recovery after the Android/Windows process exits.
- Cancellation of an already-running yt-dlp/FFmpeg operation unless a safe backend cancellation API is added separately.

## Confirmed current architecture

### Application and storage

- `lib/main.dart` owns the main library state, active playlist, playlist toolbar, Windows queue drawer, Android queue sheet, and app-level providers.
- `lib/core/storage/file_service.dart` stores numbered M3U8 playlists and display names. `createImportedPlaylist` already creates unique persistent names and preserves order/duplicates.
- Playlist mutation is currently spread across `MainApp`, Search, import flows, and services. There is no central playlist-change stream or per-playlist write serialization.
- `PlayerHandler` normally reads whichever playlist is globally active. Only standalone playlist playback currently pins an explicit playlist number.

### Playback

- `lib/core/audio/audio_service.dart` owns all transport entry points, stream resolution, queue order, crossfade, media-session state, equalizer state, and platform backends.
- Android uses `just_audio`; streamed playlist entries are canonical webpage URLs resolved through the existing Android yt-dlp bridge.
- Automatic crossfade creates a temporary incoming backend. Sync must not enter that path.
- Hardware media buttons, Android notifications, widgets, and UI controls ultimately reach `PlayerHandler`; hiding peer controls in Flutter alone would not enforce host authority.

### Playback queue artwork

- `PlaybackQueueEntry` already contains `artworkUri` and `_QueueArtwork` already renders file and network URIs.
- `playbackQueueSnapshot()` supplies `current.artworkUri` but constructs every upcoming entry without `artworkUri`.
- Resolving all local covers eagerly inside `Future.wait` would parse every queued file before the queue appears and could recreate the Android scrolling I/O bursts fixed in v2.3.0.

### Lyrics

- `_LyricsPanel` in `standalone_player_screen.dart` already parses plain, line-timed, estimated-word, enhanced-LRC, and TTML word timing.
- It follows lines by calling `Scrollable.ensureVisible`, suppressing that behavior for four seconds after a `UserScrollNotification`.
- Following is implicit, has no visible state, and `_follow` is called from the build path.
- Word highlighting jumps from muted to primary at each word's start despite every `LyricWord` already having start and end times.

### Search and downloads

- `YoutubeSearchScreen` uses one `_busyUrl`, so one action disables Play, Stream, and Download and prevents rapid download enqueueing.
- Download, import, source-record creation, lyric prefetch, progress UI, and route-pop behavior are all coupled inside `_download`.
- Windows progress is streamed from a child process; Android uses one shared EventChannel and therefore must remain serialized.
- Other playlist import flows can also invoke the same Android downloader, so serialization must be app-wide rather than local to one Search widget.

### QR import

- `PlaylistImportScreen._pickQrImages` and `PlaylistQrImageService.decodeFile` already support multiple PNG/JPEG files and local decoding.
- The Android receiving UI mounts only `MobileScanner`; the image-upload action is rendered only on non-Android platforms.
- No new decoding dependency or native Android channel is required for image import.

### Existing reusable networking

- PC Companion already demonstrates local `HttpServer` + WebSocket hosting, QR payloads, secure random tokens, message-size limits, authentication, reconnect, queue snapshots, and preferred LAN-address selection.
- Sync needs a separate protocol and lifecycle: the host is Android, peers play audio locally, credentials are session-scoped, clocks must be synchronized, and transport commands require scheduled execution.

## Cross-cutting foundations

### 1. Centralize safe playlist mutation

Extend `FileService` or introduce a small `PlaylistRepository` facade with:

- `readPlaylistTracks(int playlistNumber)` returning only normalized non-comment entries.
- `replacePlaylistTracks(int playlistNumber, List<String> tracks)` that does not depend on the globally active playlist.
- `appendTrack`, `removeOccurrence`, and `reorder` methods that accept an explicit playlist number.
- Per-playlist asynchronous write serialization so a rapid Stream add, download completion, reorder, and Sync refresh cannot overwrite one another.
- Atomic replacement through a temporary sibling file and rename where supported.
- A `PlaylistMutation` broadcast/`ValueNotifier` containing playlist number, revision, and mutation kind.

Keep existing `FileService` public methods as compatibility wrappers until all call sites are migrated. Every successful playlist mutation must publish exactly one revision.

This foundation is required by live Sync queue propagation and by rapid Search actions.

### 2. Add app-level coordinators

Create and provide these before `runApp`:

- `DownloadQueueController` on Windows and Android.
- `SyncSessionService` on Android; expose an inert unsupported state on Windows so shared widgets do not need platform-specific provider lookups.

Add them to the existing `MultiProvider` next to `PlayerHandler` and `ThemeProvider`. They must not be owned by `YoutubeSearchScreen`, because route disposal must not stop downloads or the Sync socket.

### 3. Establish a motion language

Add a `ResonanceMotionTheme` `ThemeExtension` with named tokens instead of introducing unrelated durations per widget:

- instant: 0 ms under reduced motion.
- press: 110-140 ms.
- state change: 180-240 ms.
- content transition: 320-440 ms.
- emphasized navigation: 480-560 ms.
- standard `easeOutCubic`, emphasized `easeOutQuart`, and exit `easeInCubic` curves.

Provide a helper that resolves durations to zero when `MediaQuery.disableAnimationsOf(context)` is true. Continuous decorative tickers must also stop under disabled `TickerMode`, reduced motion, or offstage UI.

## Feature A: app-wide aesthetic polish

### Design direction

Preserve Resonance's current themes, artwork-derived palette, animated standalone background, pulse, and vinyl identity. The polish pass should make state and hierarchy feel intentional rather than add motion everywhere.

Use these visual rules:

- Accent color communicates current, selected, connected, or completed state.
- Surface elevation and border contrast communicate interaction layers.
- Motion explains content changes, queue movement, playback transitions, and completed actions.
- Decorative animation remains subtle and never competes with lyrics or artwork.
- Repeated list rows animate their state, not every rebuild or scroll recycle.

### Library and playlist surface

In `track_tile.dart` and `track_list.dart`:

1. Add a 2-3 px animated accent rail for the current track.
2. Crossfade artwork/fallback changes instead of snapping.
3. Animate current-track background, title color, and playing glyph together using the motion tokens.
4. Add a brief, bounded highlight sweep when Search/import reveals a newly added track; reuse the existing pulse rather than stacking another perpetual ticker.
5. Give Windows hover a slight tonal lift and Android press a short scale/opacity response.
6. Preserve stable keys and do not stagger rows merely because they are recycled during scrolling.

### Search and action feedback

In `youtube_search_screen.dart`:

1. Fade/slide only the first visible result set for a new search generation; cap staggered entrance to the first 6-8 cards.
2. Animate preview-to-full-result replacement with stable URL keys.
3. Show inline state transitions for `Added`, `Queued`, `Downloading`, and `Failed` instead of only disabling buttons.
4. Keep Play visually dominant; Stream and Download remain secondary.
5. Add hover elevation on Windows without expensive blur.

### Player, queue, and overlays

1. Animate queue current-entry changes and artwork arrival with `AnimatedSwitcher`/fade.
2. Add a restrained accent glow around the current queue item and Sync indicator.
3. Standardize modal/sheet headers, drag handles, empty states, and error-to-retry transitions.
4. Do not add another full-screen continuous animation; the standalone gradient already fills that role.

### Performance and accessibility

- Honor reduced motion for every new animation.
- Wrap custom-painted or continuously changing elements in `RepaintBoundary`.
- Stop animations while the Windows app is hidden or the route is offstage.
- Avoid whole-list `AnimatedSize` and backdrop blur on Android.
- Keep semantic labels stable while visuals animate.
- Verify text scaling at 1.0, 1.3, and 2.0 and keyboard focus on Windows.

## Feature B: lyrics highlighting and explicit auto-follow

### State model

Replace `_manualScrollUntil` with explicit state:

```text
LyricsFollowState.following
LyricsFollowState.pausedByUser
```

Rules:

1. Every timed lyric document starts in `following`.
2. A drag initiated by the user changes it to `pausedByUser`.
3. Programmatic `ensureVisible` calls must not be interpreted as manual scrolling.
4. Pressing Follow sets `following` and immediately recenters the currently active line.
5. Pressing a timed lyric line seeks, resumes following, and recenters the new active line.
6. Loading another track or lyric candidate resets to `following`.
7. Plain lyrics show the control disabled with a tooltip explaining that timing is unavailable.

Move position-follow side effects out of `build`. Subscribe to `handler.positionStream` in state, compute active-line changes there, and schedule at most one pending scroll operation.

### Follow control UI

Add an icon button in the lyrics header, immediately before Change Lyrics:

- Following: selected `my_location_rounded`/`gps_fixed_rounded`, tooltip `Following current lyric`.
- Paused: tonal `my_location_outlined`, tooltip `Return to current lyric`.
- Disabled for plain lyrics.

When paused, allow a small `Follow` label on wider layouts; retain icon-only presentation on narrow phones. Do not use a floating overlay that covers lyric text.

### Continuous karaoke highlighting

Add pure helpers:

```text
wordProgress(position, word.start, word.end) -> 0...1
lineProgress(position, line.start, line.end) -> 0...1
```

Replace discrete `TextSpan` color changes with a dedicated `KaraokeLyricLine` renderer:

1. Use `TextPainter` with the actual direction, scale, width, and style to preserve normal wrapping.
2. Paint the muted paragraph first.
3. Derive glyph boxes for each word/syllable range.
4. Paint the primary-colored paragraph through clips whose width follows each word's continuous progress.
5. Use the word's real start/end timing for enhanced LRC and TTML.
6. Use the already-estimated timings for line-only LRC, retaining the `word flow estimated` disclosure.
7. Fall back to a line-wide sweep when a timed line has no usable word ranges.

Smooth the relatively coarse position-stream updates with a short linear interpolation toward the latest position. Do not invent progress while playback is paused. Reduced motion uses completed/current/upcoming colors without the moving sweep.

### Active-line treatment

- Active line: stronger weight, 1.01-1.025 transform scale, subtle accent-tinted background/glow, full contrast.
- Past lines: approximately 45-52% opacity.
- Upcoming lines: approximately 28-36% opacity.
- Transition the active surface, opacity, and scale over the standard state duration.
- Keep line padding stable; use transforms rather than changing enough padding to make the list jump.
- Add a single semantics label such as `Current lyric: ...`; exclude duplicate painted text from semantics.

### Lyrics tests

Add unit/widget coverage for:

- Progress at before/start/mid/end/after boundaries and zero-length timing.
- Native syllable timing, enhanced LRC, and estimated line timing.
- Wrapped text, RTL direction, and increased text scale.
- Default following and active-line centering.
- Real drag pauses following; programmatic scrolling does not.
- Follow immediately recenters and resumes future movement.
- Tapping a timed line seeks and resumes following.
- Plain lyrics disable Follow.
- Reduced motion removes sweep/scale animation without removing the active cue.
- Track and manual-candidate changes reset follow state safely.

## Feature C: artwork for every playback queue entry

### Data and resolver changes

Keep `PlaybackQueueEntry.artworkUri`, but avoid eager extraction for an entire large queue.

1. Add a public `PlayerHandler.queueArtworkUri(String trackId)` wrapper around the existing cached artwork resolver.
2. While building `playbackQueueSnapshot()`:
   - Keep `current.artworkUri` as today.
   - Populate upcoming stream artwork immediately from `MetadataCacheService`.
   - Leave uncached local artwork lazy.
3. Add an optional `loadArtwork` callback to `UpcomingQueuePanel` and pass `handler.queueArtworkUri` from Windows, Android, standalone queue, and the peer Sync screen.
4. Make `_QueueArtwork` stateful or use `FutureBuilder`, keyed by entry ID. Resolve only rows that Flutter builds.
5. Reuse `_artUriCache` and temporary extracted notification artwork; do not create a second on-disk cover cache.
6. Fade from fallback to artwork and guard late results when a recycled row changes entry.
7. Continue using network thumbnails for streams and embedded artwork for local tracks.

### Queue artwork tests

- Current and upcoming network art render.
- A visible local upcoming row invokes lazy artwork resolution.
- Offscreen rows are not all resolved eagerly.
- Late artwork for an old entry cannot overwrite a recycled row.
- Missing/corrupt images retain the fallback.
- Windows drawer, Android sheet, and Sync peer queue pass the resolver.

## Feature D: Resonance Sync

### Session playlist behavior

Add a pure `SyncPlaylistProjection` helper.

On Start Sync:

1. Read the current playlist with an explicit playlist number.
2. Keep valid canonical streamed entries in original order, including any existing duplicate entries.
3. If every entry is streamed, pin the existing playlist as the session playlist.
4. If any entry is local, create and activate a uniquely named persistent `Sync` playlist containing only the projected streams.
5. If no stream exists, create and activate an empty `Sync` playlist.
6. Cache/canonicalize metadata for every session entry.
7. Pin `sessionPlaylistNumber`; do not let later library browsing silently change the playback queue used by Sync.

The underlying playlist remains a normal Resonance playlist. While a session is active, the synchronized playback projection contains only stream entries. If a local file is later added, retain it in the playlist but exclude it from the shared queue and show `Not available in Sync` on that row. Trying to play it should offer to end Sync rather than desynchronize peers.

Host stream additions, removals, and reorders publish a playlist mutation. Debounce re-reading the pinned playlist by about 100-150 ms, increment a session queue revision, update peers, and preserve the current track when possible.

On a peer:

1. Create `Sync - <host name>` through the unique-name helper on first authenticated state.
2. Save the host's canonical base playlist order with an explicit playlist-number replacement API.
3. Apply later host revisions to that same playlist atomically.
4. Preserve the peer playlist when leaving or when the host ends the session.

### Protocol

Create `lib/services/sync/sync_protocol.dart` with protocol version 1.

Pairing payload:

```text
resonance://sync?v=1&host=<ipv4>&port=<port>&session=<id>&token=<token>&name=<host>
```

Core models:

- `SyncRole`: none, host, peer.
- `SyncConnectionStatus`: idle, starting, waiting, connecting, connected, reconnecting, error, ended.
- `SyncTrack`: stable ID, video ID/canonical URL, title, artist, artwork URL, duration.
- `SyncQueueState`: base playlist, effective playback order, current ID, revision, shuffle, loop.
- `SyncPlaybackAnchor`: track ID, playing, position, host monotonic timestamp, speed, pitch, equalizer.
- `SyncPeer`: device ID, display name, readiness, RTT, drift, last seen.

Message types:

- `authenticate`, `accepted`, `error`, `end`.
- `state` for authoritative queue/playback snapshots.
- `playlist` for base-order changes.
- `prepareTrack`, `trackReady`, `commitTrack`.
- `transport` for scheduled play/pause/seek and mode/effect changes.
- `anchor` for periodic drift checks.
- `ping`, `pong` for clock estimation and liveness.

Protocol rules:

- JSON object messages only, maximum 64 KiB.
- Cap playlist length and metadata string lengths before decoding/allocating.
- Reject unsupported versions and mismatched session IDs.
- Use canonical source URLs, never resolved CDN/HLS URLs.
- Include monotonically increasing command and queue revisions; ignore stale/duplicate messages.
- Keep all host state authoritative; peers never send transport or queue commands.

### Hosting and pairing

Create `SyncHostService` using patterns from Companion but not its persisted device credentials:

1. Android only; bind `InternetAddress.anyIPv4` to a dedicated default port with ephemeral-port fallback.
2. Select the most plausible Wi-Fi/hotspot IPv4 address and show it in diagnostics.
3. Generate a cryptographically random session ID and token.
4. Token is valid only for the current session and expires/rotates after pairing display timeout.
5. Keep authenticated sockets in a peer map and broadcast authoritative snapshots.
6. Limit simultaneous pending/authenticated sockets to a reasonable personal-session cap, initially eight.
7. End all sockets and invalidate the token when the host ends Sync.

Host UI:

- Add a Sync action to the Android library toolbar/compact menu.
- Starting opens a host sheet containing QR, session playlist name, connected peers, readiness/latency, and End Sync.
- While active, show a compact `SYNC • N` pill in the app bar/toolbar and a linked accent cue around Currently Playing.
- Tapping the indicator reopens the host sheet.
- Keep the normal library/player UI and route every host control through the Sync-aware control layer.

### Joining and peer UI

Create a Join Sync flow using `MobileScanner` with an image-upload fallback if practical to share with the QR-import picker.

After authentication and initial playlist creation, show `SyncPeerPlayerScreen`, a limited composition of the standalone player:

- Artwork, animated/theme-aware background, title, artist, and playback state remain visible.
- Only the app volume slider and queue button are present.
- Queue is read-only; omit `onPlay`.
- Horizontal next/previous swipes and downward exit swipe are disabled.
- Upward queue gesture remains enabled.
- Add an explicit Leave Sync action so a peer is never trapped.
- Notification, headset, widget, keyboard, and media-session transport commands are ignored while in peer role.
- If the socket drops, keep the current audio state briefly, show Reconnecting, and stop after the reconnect grace period expires.

### Enforcing playback authority

Add a `PlaybackControlPolicy`/Sync delegate at the `PlayerHandler` boundary:

- normal: existing behavior.
- syncHost: local transport is converted into scheduled host commands.
- syncPeer: public/local transport is rejected; only authenticated internal Sync commands may call private backend methods.

Refactor public actions into policy-aware wrappers and private immediate operations. This must cover:

- `play`, `pause`, `playPause`, `seek`, `seekBySeconds`.
- `next`, `previous`, queue entry selection.
- loop and shuffle.
- speed, pitch, and equalizer.
- completion/loop handling internal to backend stream listeners.
- Android audio-service, notification, headset, and widget entry points.

Volume and mute remain device-local and bypass Sync propagation. Peer UI exposes volume; host volume changes affect only the host phone.

In peer role, publish a media-session state without actionable transport controls where Android permits, while still retaining the policy gate as the security/correctness backstop.

### Crossfade suppression

Do not write `crossfade_enabled = false` when Sync starts.

- Add `crossfadeAllowed`/session policy to `_maybeStartAutomaticCrossfade`.
- Disable the Crossfade setting control while Sync is active and explain `Crossfade is unavailable during Sync`.
- Cancel any in-progress crossfade before entering the session.
- Use the saved preference again immediately after Sync ends.

### Clock synchronization and scheduled transport

Use monotonic time (`Stopwatch`/elapsed microseconds), not wall-clock `DateTime`, for execution scheduling.

1. On join, peer performs 5-7 ping/pong samples.
2. Estimate host offset using NTP-style timestamps and retain the lowest-RTT samples.
3. Refresh estimates periodically and after reconnect.
4. For play/pause/seek on an already prepared track, host broadcasts an execution timestamp about 400-700 ms in the future and schedules its own action for the same host timestamp.
5. For a track change, host broadcasts `prepareTrack`; every peer resolves and preloads independently.
6. Host waits until peers are ready or a bounded preparation deadline expires, then sends `commitTrack` with a future start timestamp and target position.
7. A late peer starts at the expected current position rather than delaying the entire session indefinitely.

Add Android prepared-source support to `PlayerHandler` using a separate just_audio backend built through `_createJustAudioBackend`. Because Sync suppresses crossfade, the prepared player is never competing with an incoming crossfade player. On commit, promote the prepared backend, attach listeners, apply host speed/pitch/EQ and local volume, seek to the scheduled target, and dispose the outgoing backend.

### Drift correction

Host sends authoritative anchors approximately once per second while playing and immediately after every state change.

Peer computes expected host position at receipt:

```text
expected = anchor.position + (localHostTimeNow - anchor.hostTime) * hostSpeed
drift = localPosition - expected
```

Initial policy, tune with real devices:

- Absolute drift below about 80 ms: no correction.
- About 80-250 ms: temporarily bias playback speed by at most 1-1.5%, then restore exact host speed.
- Above about 250 ms, after buffering, after reconnect, or after a seek: direct seek to expected position.
- Never compound correction with stale anchors.
- Expose per-peer drift/RTT only in the host diagnostics sheet, not the normal player.

Automatic completion must remain host-driven. Peers wait for the next host command rather than advancing independently; loop-one and loop-all are scheduled by the host using the same mechanism.

### Network and lifecycle handling

- A peer needs internet access as well as LAN access because it resolves the stream itself.
- Same-Wi-Fi AP isolation can prevent direct connection; surface a specific diagnostic rather than claiming the QR is invalid.
- Hotspot host-address selection must be tested across common Android vendors.
- Reconnect with capped exponential backoff while the session is still valid.
- Keep the socket alive while Android background playback is active; verify screen-off behavior with the existing foreground audio service and wake lock.
- If the host process dies, peers stop after timeout, retain the playlist, and return to the library with an explanation.

### Sync tests

Unit tests:

- Pairing URI round-trip and malformed/version/token rejection.
- Message size/field/list limits and stale revision rejection.
- Mixed, all-stream, no-stream, duplicate, and malformed-source playlist projection.
- Explicit playlist replacement preserves peer playlist number and order.
- Clock offset selection with asymmetric latency/outliers.
- Scheduled execution conversion between host and peer clocks.
- Drift thresholds and correction direction.
- Host state machine, peer reconnect, token expiry, and end-session cleanup.
- Crossfade preference is suppressed, not overwritten.
- Peer command policy blocks every local transport path while allowing volume and authenticated remote application.

Widget tests:

- Host indicator and peer count.
- Peer screen exposes volume, queue, and Leave only.
- Peer queue has no playable rows.
- All disallowed gestures do nothing; swipe-up opens queue.
- Crossfade setting displays the session explanation.
- Local rows added to a session playlist are marked unavailable.

Real-device matrix:

- Two, three, and at least four Android phones.
- Same Wi-Fi and host-phone hotspot.
- Play/pause, long seek, rapid seek, next/previous, shuffle, loop-one/all, speed, pitch, and EQ.
- One slow/buffering peer, temporary internet loss, Wi-Fi loss/reconnect, screen off, app background, host termination, and peer leave.
- Queue additions/removals/reorders during playback.
- At least one long playlist and one duplicate stream entry.
- Measure start skew and steady-state drift; record thresholds before release acceptance.

## Feature E: sequential download queue

### Models

Add `DownloadQueueEntry` with:

- immutable ID.
- `YoutubeTrack` snapshot.
- destination playlist number/name captured at enqueue time.
- queued timestamp and optional start/end timestamps.
- state: queued, preparing, downloading, processing, importing, completed, failed.
- progress 0-100 and status text.
- resulting local paths and failure message.

`DownloadQueueController` exposes an immutable list, active entry, pending/completed counts, and operations to enqueue, remove a queued entry, retry a failed entry, and clear finished entries.

### Shared task runner

Extract the body of `YoutubeSearchScreen._download` into `DownloadTaskRunner`:

1. Select Windows or Android backend.
2. Download and report progress/status.
3. Import every result into the captured playlist number.
4. Save source mappings.
5. Trigger lyric prefetch without blocking completion.
6. Return added paths.

Keep download-history recording in one layer only; avoid double success/failure records after the refactor.

Move platform downloader logic out of UI widgets over time, using `lib/core/youtube/download_manager.dart` or focused backend files. Keep thin compatibility wrappers for legacy `WindowsYoutube`/`AndroidYoutube` dialogs until they can be removed.

Add a global `YoutubeDownloadGate` used by Search queue jobs and `YoutubeTransferService.downloadVideo`. On Android this prevents multiple operations from sharing the untagged EventChannel. On Windows it enforces the product's one-download rule.

### Worker behavior

1. `enqueue` adds synchronously so rapid taps are never lost.
2. One guarded drain loop takes FIFO entries.
3. Await every download, conversion, import, source save, and final state update before taking the next entry.
4. Failure marks one entry failed and continues with the next.
5. Do not persist entries to disk in v1.
6. The worker belongs to the app-level controller and is not disposed with Search.
7. Prevent duplicate queued/active `(canonical URL, playlist number)` jobs; allow retry after failure/completion.
8. On process shutdown, let the existing bounded shutdown policy win; do not delay Windows exit indefinitely.

### Search interaction rules

Add a queue-mode toggle to the Search app bar with a clear label/tooltip and selected state.

Queue mode off:

- Play: unchanged.
- Stream: add to captured playlist, return to playlist, reveal track.
- Download: submit through the global serial worker, await completion, return to playlist, reveal first result.

Queue mode on:

- Play: unchanged and never blocked by another track's queued download.
- Stream: add immediately, remain on Search, show an inline check/snackbar, and update the playlist mutation stream.
- Download: enqueue immediately, remain on Search, and let the user enqueue other results rapidly.

Turning queue mode off affects future button presses only. Existing jobs continue. Split `_busyUrl` into action-specific state so downloading one result does not disable unrelated Play/Stream/Download buttons.

### Windows UI

- When queue mode is on or entries exist, show a 300-360 px right-side panel within Search.
- On narrow Windows windows, collapse it into a bottom panel/button rather than crushing result cards.
- Show thumbnail, title, artist, destination playlist, state, current progress, and queue position.
- Actions: remove queued, retry failed, clear finished. Running entry is non-removable unless backend cancellation is implemented safely.
- Animate entry/status changes with stable job IDs and motion tokens.

### Android UI analysis and decision

Use a two-level surface:

1. A compact persistent bar at the bottom of Search showing current title, progress, and `N queued`.
2. Tapping the bar or dragging its handle upward opens a `DraggableScrollableSheet` with initial/min/max extents suitable for phone screens.

The sheet contains the same job details/actions as Windows. It must use `SafeArea`, remain usable with keyboard/text scaling, and not steal ordinary vertical scrolling from result cards except from its visible handle/bar.

When Search is covered by the standalone player or removed, the controller continues. If the user later reopens Search, it reconstructs the panel from controller state.

### Download queue tests

- Twenty rapid enqueues are retained in FIFO order.
- Instrumented backend proves maximum concurrency is exactly one.
- A failed middle job does not stop later jobs.
- Duplicate active jobs are rejected cleanly.
- Every job imports into its captured playlist even if active playlist changes.
- Normal mode waits and pops/reveals; queue mode remains.
- Queue-mode Stream remains; normal Stream pops.
- Play remains usable while another download runs.
- Controller survives Search disposal and is visible after reopening.
- Completed/failed/queued UI and retry/remove/clear behavior.
- Android mini-bar and draggable sheet layout on compact and tall screens.
- Windows panel collapses at narrow width.
- Existing Unicode, progress, history, and playlist-import download tests remain green.

## Feature F: Android QR import from saved images

### UI and flow

Reuse `_pickQrImages` and `PlaylistQrImageService.decodeFile`.

1. Keep the Android camera preview.
2. Add a clearly visible `Upload QR Images` button below or over the lower edge of the preview, outside the scanner's error content.
3. Allow multiple PNG, JPG/JPEG, and WebP images.
4. Stop/pause camera scanning before opening the picker so camera frames cannot race selected-file processing.
5. Decode selected images sequentially and feed every payload through `_acceptRawPayload`, preserving duplicate/out-of-order validation.
6. Stop once the transfer becomes complete; report invalid images individually without discarding accepted chunks.
7. Resume the camera if selection is cancelled or the selected set is incomplete.
8. Show `Add more images` and `Start over` on Android after partial receipt, matching Windows behavior.
9. Keep upload available when camera permission is denied or camera initialization fails.
10. Use the system file picker/SAF; do not add broad image-storage permissions.

Refactor `_processingInput` so only one owner sets/clears it. The current method temporarily clears it inside the loop to call `_acceptRawPayload`; replace that with an internal acceptance method or explicit source-processing guard to avoid camera/picker races.

### QR image tests

- Android receiving UI exposes camera and Upload QR Images.
- Picker cancellation resumes scanning and changes no session state.
- Multiple images complete a multi-chunk transfer in and out of order.
- Duplicate and unreadable images are nonfatal and visible in notices.
- Partial image import can continue by camera or another image selection.
- Completion stops the scanner and ignores later files safely.
- Camera error/permission denial does not hide upload.
- Existing generated-PNG decode and filename tests remain green.

## File-level implementation map

### Existing files to modify

| File | Planned responsibility |
| --- | --- |
| `lib/main.dart` | Register app-level controllers, add Android Sync actions/indicator, react to playlist revisions, preserve existing Windows drawer. |
| `lib/app/theme.dart` | Register motion extension and shared interaction-state styling. |
| `lib/core/storage/file_service.dart` | Explicit numbered reads/replacements, serialized mutations, mutation notifications. |
| `lib/core/audio/audio_service.dart` | Lazy queue artwork API, pinned Sync playlist, control policy, prepared Android stream backend, scheduled commands, crossfade suppression, peer completion behavior. |
| `lib/models/playback_queue_snapshot.dart` | Preserve artwork/source identity needed for lazy resolution and Sync serialization. |
| `lib/screens/player/standalone_player_screen.dart` | Extract/enhance lyrics, add explicit follow behavior; keep normal standalone gestures unchanged. |
| `lib/widgets/player/upcoming_queue.dart` | Lazy artwork resolution, animated artwork arrival, read-only peer configuration. |
| `lib/widgets/player/player_controls.dart` | Reusable volume-only surface or primitives for peer player. |
| `lib/widgets/library/track_tile.dart` | Current-track visual polish and Sync-ineligible local-row state. |
| `lib/widgets/library/track_list.dart` | Motion integration without scroll recycling animation. |
| `lib/widgets/player/album_cover.dart` | Host Sync indicator cue and consistent transition tokens. |
| `lib/screens/youtube/youtube_search_screen.dart` | Queue-mode behavior, action-specific busy state, platform queue surfaces. |
| `lib/widgets/youtube/windows_youtube.dart` | Extract/refactor downloader backend while retaining compatibility UI. |
| `lib/widgets/youtube/android_youtube.dart` | Extract/refactor backend and route downloads through global gate. |
| `lib/services/youtube_transfer_service.dart` | Participate in global one-download gate. |
| `lib/screens/settings/settings_screen.dart` | Explain/disable crossfade while Sync is active if Settings is opened. |
| `lib/screens/playlist_transfer/playlist_import_screen.dart` | Android image upload button and race-free camera/picker coordination. |
| `lib/services/playlist_qr_image_service.dart` | Accept WebP if supported and expose testable decode/picker helpers if needed. |
| `README.md` | Document Sync requirements/limitations, queue behavior, lyrics Follow, queue art, and Android QR image import. |

### New focused files

```text
lib/app/resonance_motion.dart
lib/models/download_queue_entry.dart
lib/services/download/download_queue_controller.dart
lib/services/download/download_task_runner.dart
lib/services/download/youtube_download_gate.dart
lib/widgets/youtube/download_queue_panel.dart
lib/widgets/youtube/android_download_queue_sheet.dart
lib/widgets/lyrics/karaoke_lyric_line.dart
lib/widgets/lyrics/lyrics_follow_control.dart
lib/services/sync/sync_protocol.dart
lib/services/sync/sync_clock.dart
lib/services/sync/sync_playlist_projection.dart
lib/services/sync/sync_host_service.dart
lib/services/sync/sync_peer_service.dart
lib/services/sync/sync_session_service.dart
lib/screens/sync/sync_host_sheet.dart
lib/screens/sync/sync_join_screen.dart
lib/screens/sync/sync_peer_player_screen.dart
lib/widgets/sync/sync_status_indicator.dart
```

The exact split may be adjusted to keep files cohesive, but networking, protocol parsing, clock math, playlist projection, download execution, and visual widgets must not be collapsed into `main.dart` or `audio_service.dart` unnecessarily.

## Recommended implementation sequence

### Phase 0: baseline and safety fixtures

1. Keep the current clean `main` worktree as baseline.
2. Record that Python bridge tests pass (6/6 on 2026-08-09).
3. Resolve or document the local Flutter tool startup hang before relying on analyzer/test results; it currently emits no diagnostic before timeout.
4. Add fixtures for long/duplicate/mixed playlists, embedded/no/corrupt artwork, enhanced LRC/TTML, and fake download/network backends.

### Phase 1: shared foundations

1. Add motion tokens and reduced-motion helper.
2. Add explicit, serialized, observable playlist mutations.
3. Add app-level `DownloadQueueController` and inert/Android `SyncSessionService` providers.
4. Add injectable clocks, sockets, download adapters, picker/decoder callbacks, and artwork resolvers for deterministic tests.

### Phase 2: contained UI wins

1. Fix lazy artwork for upcoming queue entries.
2. Implement lyrics follow state/button and continuous karaoke renderer.
3. Add Android QR multi-image upload and camera coordination.
4. Apply the first motion polish to these touched surfaces.
5. Run their unit/widget tests before starting networking work.

### Phase 3: download queue

1. Extract the shared task runner and global download gate.
2. Implement the FIFO controller and immutable job model.
3. Refactor Search behavior and busy state.
4. Add Windows panel and Android mini-bar/sheet.
5. Integrate playlist mutation notifications and verify imports/Sync filtering.
6. Run rapid enqueue, failure continuation, route disposal, Unicode, and history regressions.

### Phase 4: Sync protocol and playlist lifecycle

1. Implement pure protocol, limits, pairing URI, clock estimator, drift policy, and playlist projection.
2. Implement Android host server/authentication and peer client/reconnect with fake-socket tests.
3. Implement start behavior for mixed/all-stream/no-stream playlists.
4. Implement persistent peer playlist creation and live atomic replacement.
5. Add host QR/join flows and connection state UI before controlling audio.

### Phase 5: synchronized playback

1. Refactor `PlayerHandler` into policy-aware wrappers/private immediate operations.
2. Enforce peer control restrictions across UI and native/media-session entry points.
3. Add prepared Android stream backend and prepare/ready/commit handshake.
4. Add scheduled transport, automatic completion ownership, anchors, and drift correction.
5. Suppress crossfade without changing its saved preference.
6. Add peer standalone UI, read-only queue, and host indicator.
7. Validate on multiple real phones before tuning timing constants.

### Phase 6: broader aesthetic pass

1. Apply motion tokens to library, Search, queue, player state, and session/download feedback.
2. Audit every new/modified animation for reduced motion, offstage tickers, repaint boundaries, stable keys, and semantics.
3. Test Windows hover/focus and Android touch/text scaling.

### Phase 7: hardening and release work

1. Run full `flutter analyze`, `flutter test`, and Python tests once the local Flutter toolchain starts normally.
2. Build Windows and Android release artifacts.
3. Perform same-Wi-Fi/hotspot and multi-peer matrices.
4. Verify no regression in PC Companion, playlist QR transfer, external playlist imports, background playback, notification controls, widgets, tray shutdown, Unicode downloads, and artwork palettes.
5. Update README, third-party notices only if dependencies change, and release patch notes.

## End-to-end acceptance criteria

### Aesthetics and lyrics

- Motion feels consistent across changed surfaces and becomes static under reduced motion.
- Lyrics use continuous timed fill, an unmistakable active line, and readable past/upcoming hierarchy.
- Timed lyrics follow by default; manual drag pauses; Follow immediately returns and stays locked to the current line.
- No animation causes list jumps, clipped text, duplicate semantics, or background CPU regression.

### Playback queue artwork

- Current and every visible upcoming queue row show the correct stream or local album cover on Windows and Android when artwork exists.
- Large queues open promptly and do not extract every cover at once.

### Resonance Sync

- Mixed playlists create a persistent stream-only Sync playlist; fully streamed playlists are used directly.
- Every peer receives and retains a new playlist with canonical links, metadata, order, and live host changes.
- Only the host can change shared playback/queue state; peers can change only their own volume and view the queue.
- Crossfade never runs during Sync and returns afterward according to the saved setting.
- Playback starts together after preparation, corrects meaningful drift, survives ordinary buffering/reconnect, and stops cleanly when the host/session ends.
- Same-Wi-Fi and host-hotspot sessions work without any backend.

### Download queue

- Queue mode allows rapid enqueueing and exactly one active download.
- Queue mode Stream and Download remain on Search; Play is unchanged.
- Normal Stream/Download retain existing return-and-reveal behavior.
- Jobs continue across Search/navigation/background for the process lifetime, target the captured playlist, and remain observable on reopening Search.
- Windows and Android expose platform-appropriate queue visibility and failures never block later jobs.

### Android QR images

- Android users can scan with camera or select one/multiple saved QR images.
- Image and camera chunks can be mixed, unordered, duplicated, or partially invalid without losing accepted progress.
- Upload remains available when the camera cannot be used.

## Principal risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Independent YouTube resolution/buffering creates start skew | Prepare/ready/commit handshake, future execution times, late-peer catch-up, periodic anchors. |
| Phone clocks differ | Monotonic NTP-style offset estimation; never schedule from wall clock. |
| Hotspot/Wi-Fi address is wrong or clients are isolated | Ranked address selection, QR diagnostics, connection test, explicit AP-isolation error. |
| Peer controls leak through Android media APIs | Enforce policy at `PlayerHandler`, remove advertised actions where possible, test notification/headset/widget paths. |
| Host switches library playlist during Sync | Pin session playlist number; shared playback never follows global active playlist implicitly. |
| Rapid playlist/download writes overwrite one another | Explicit playlist numbers, serialized per-playlist mutations, atomic replacement, mutation revisions. |
| Queue artwork causes large I/O burst | Resolve only built rows, reuse existing cache/temp files, guard recycled rows. |
| Android EventChannel mixes concurrent downloads | One app-wide download gate, sequential worker, apply gate to transfer imports too. |
| App is killed with queued jobs | Accepted v1 behavior: process-lifetime only; history records completed/failed work, queued jobs are not claimed as resumed. |
| Visual polish raises GPU/CPU usage | Motion tokens, capped entrance animation, no list-wide blur, offstage/reduced-motion shutdown, repaint boundaries. |
