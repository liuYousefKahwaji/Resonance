# Resonance Authenticated YouTube Music Home Implementation Plan

Last reviewed: 2026-08-25

Implementation status: **executed**. The Suggestions/Home switch, expanded authenticated feed, distinct responsive Home layouts, standalone looping queues, Windows Unicode/helper fix, and Android EJS/QuickJS packaging are implemented. Automated verification and an on-device QuickJS/startup smoke test pass; only final human interaction checks for the formerly failing Android Play/Stream/Download flow remain.

## Outcome

Add an authenticated **YouTube Music Home** experience to Resonance on Windows and Android. It must use the YouTube/YouTube Music session the user has already connected through Resonance's v3 YouTube Access feature and must never make an unauthenticated home-feed request.

The finished feature should:

- Show personalized YouTube Music home shelves when the Search screen is empty.
- Work on Windows with the selected live browser session and on Android with the imported `cookies.txt` session.
- Render directly playable song/video recommendations as normal Resonance YouTube tracks, with Play, Stream, and Download actions.
- Preserve the existing local playlist-based Suggested Music feature as a separate switch option rather than deleting it.
- Show a clear Connect/Fix access state when the personalized home feed cannot run.
- Keep cookie values, authorization hashes, browser database contents, and private cookie-file paths out of Dart, preferences, stdout, logs, diagnostics, and method-channel results.
- Fix the separate Windows regression where the result card's main **Play** button fails with cookies connected even though adding the same result with **Stream** and playing it through the playlist works.
- Fix the Android cookie-connected media regression where direct Play reports `Source error 0`, playlist streaming does not play, and Download can exhaust the extractor attempts with signature/n-challenge failures and `Requested format is not available`.

## Research findings and consequences

### There is no supported official API for this feed

The official YouTube Data API exposes resources such as activities, videos, playlists, subscriptions, and search, but it does not expose the personalized YouTube Music home surface. It also requires an API key or OAuth token for its supported calls. Therefore, do not spend implementation time trying to build this feature on `youtube/v3`, and do not introduce a Google Cloud API key or OAuth flow.

Reference: <https://developers.google.com/youtube/v3/docs>

### The practical endpoint is YouTube Music's internal browse endpoint

`ytmusicapi` 1.12.2 implements `get_home(limit)` by POSTing a browse body containing `{"browseId": "FEmusic_home"}` and following section-list continuations. Its result is a list of titled rows. A row may mix songs, videos, albums, playlists, artists, and channels.

References:

- <https://ytmusicapi.readthedocs.io/en/stable/reference/browsing.html>
- <https://github.com/sigma67/ytmusicapi/blob/main/ytmusicapi/mixins/browsing.py>

This is an unofficial, reverse-engineered endpoint. Its response shape can change without notice. Use the maintained parser rather than copying its current JSON navigation into Dart, and isolate the dependency behind a narrow Resonance-owned contract.

### Browser authentication needs more than a raw cookie header

`ytmusicapi` browser authentication uses a YouTube Music cookie header, an `X-Goog-AuthUser` account index, the `https://music.youtube.com` origin, and a dynamically generated `SAPISIDHASH` authorization header. Its current implementation specifically requires `__Secure-3PAPISID`. Multiple signed-in Google accounts can return the wrong or empty library if the auth-user index is wrong; brand accounts require a separate on-behalf-of user ID.

References:

- <https://ytmusicapi.readthedocs.io/en/stable/setup/browser.html>
- <https://github.com/sigma67/ytmusicapi/blob/main/ytmusicapi/ytmusic.py>
- <https://github.com/sigma67/ytmusicapi/blob/main/docs/source/setup/browser.rst>

Consequences:

- Do not call `YTMusic()` without an authentication object, even though the library permits some anonymous calls.
- Default `X-Goog-AuthUser` to `0`, store it only as non-secret configuration, and provide an Advanced account-slot selector for users with multiple Google accounts.
- Treat brand-account selection as a documented limitation for the first implementation unless physical testing proves it is required for the intended user.
- Do not strengthen the existing global Android cookie validator to require only `__Secure-3PAPISID`; a session may remain valid for yt-dlp even if it cannot power YouTube Music Home. Report a home-specific capability error instead of breaking streaming/download access.

### The dependency is suitable for the existing Android runtime

The current `ytmusicapi` project requires Python 3.10 or newer, depends on `requests >= 2.22`, and is MIT licensed. Resonance's Chaquopy runtime is Python 3.10, so 1.12.2 is compatible with the current APK. Pin the exact version; do not use an unbounded dependency.

References:

- <https://github.com/sigma67/ytmusicapi/blob/main/pyproject.toml>
- <https://github.com/sigma67/ytmusicapi/releases/tag/1.12.2>

### Windows must not export browser cookies to a file automatically

yt-dlp can combine `--cookies-from-browser` and `--cookies` to create a Netscape file, but its own FAQ warns that this writes cookies for **all sites**, not only YouTube. That would reverse the v3 decision that Windows reads a browser profile live and never creates a Windows cookie export.

References:

- <https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp>
- <https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies>

Therefore, the Windows browser flow uses an in-memory helper process. A separate user-requested troubleshooting path now accepts an already-exported Netscape `cookies.txt` through the native file picker; it validates the file, passes only its path to yt-dlp as `--cookies`, and never exports or serializes browser cookies automatically.

### Android's current yt-dlp package is missing the complete EJS stack

yt-dlp's current official EJS guidance says full YouTube extraction requires both a supported external JavaScript runtime and the matching `yt-dlp-ejs` challenge-solver scripts. PyPI installations obtain the scripts from the `default` dependency group, but Resonance currently installs only bare `yt-dlp==2026.8.20.234504.dev0`. Chaquopy also has no Deno, Node, QuickJS, or Bun executable configured. The captured Android error explicitly reports both signature and n-challenge solving failures before only image formats remain.

Reference: <https://github.com/yt-dlp/yt-dlp/wiki/EJS>

The current cookie-free `android_vr` fallback can avoid JavaScript for some videos, but it is not a guarantee for every video/network/server response. The implementation must first prove what happened in each existing extractor attempt for the exact failing video `8mhMnaht-cM`; if `android_vr` cannot return playable media, Android needs a bundled, offline-capable EJS runtime rather than another format-string guess.

The Python 3.10 deprecation warning is not the cause of this particular failure, but it is now part of the required Android runtime work. Plan and validate a move to Python 3.11 before relying on future yt-dlp builds. Do not change the pinned yt-dlp nightly while diagnosing this regression.

## Verified repository baseline

The implementation must begin from the current v3.0.0 source, not the stale baseline in the previous cookie-authentication plan:

- Current HEAD is `afa640f` (`v3.0.0`), and `pubspec.yaml` is `3.0.0+3`.
- Windows ships `assets/bin/yt-dlp.exe`, `deno.exe`, and `ffmpeg.exe`; `windows/CMakeLists.txt` installs them into the release `bin` directory.
- `WindowsYtdlpRunner` is the only Dart owner of product yt-dlp launches. It adds Deno, IPv4, UTF-8 behavior, and the selected `--cookies-from-browser` browser.
- Android pins exactly `yt-dlp==2026.8.20.234504.dev0` in `android/app/build.gradle.kts` and runs it through Chaquopy.
- Android's canonical cookies file remains under `noBackupFilesDir`. `YoutubeCookieStore.createWorkingCopy()` creates one unique private copy per operation, and `MainActivity.withYoutubeCookieCopy` deletes it in `finally`.
- Android cookie contents do not cross into Dart. Preserve that boundary.
- `YoutubeAccessService` owns access method/state/revision. Windows persists only the browser ID and timestamps. Android obtains configuration metadata from the native store.
- Empty-query Search currently runs `SuggestedMusicService`, which builds a local playlist profile and performs up to six ordinary YouTube searches. It is not the user's YouTube Music home feed.
- `YoutubeSearchScreen._play` calls `PlayerHandler.playStandaloneStream` and immediately opens `StandalonePlayerScreen` after a successful load.
- `YoutubeSearchScreen._stream` does not start playback; it stores metadata, adds the YouTube URL to the current playlist, and returns to the library. Later playlist playback goes through `PlayerHandler.loadTrack`.
- Both Windows playback paths should ultimately use `PlayerHandler._resolveStream`, `WindowsYtdlpRunner`, and `_WindowsStreamProxy`. The reported Play-only failure is therefore a standalone activation/lifecycle regression until evidence shows otherwise; it is not a general cookie-streaming failure.

## Product decisions

| Area | Decision |
| --- | --- |
| Eligibility | Fetch YouTube Music Home only when `YoutubeAccessStatus.isConfigured` is true and the state is not `rejected`, `verificationRequired`, or `unavailable`. `configuredUntested` may fetch because Android restarts currently restore that state; a successful home response counts as an authenticated success. |
| No-cookie behavior | Do not call the home backend. Show a compact “Connect YouTube to see your Music Home” card linking to YouTube Access. Keep local Suggested Music below it. |
| Broken-session behavior | Do not fall back to an anonymous `FEmusic_home` response. Show Fix access and keep any local Suggested Music available. |
| Feed placement | The empty-query Search body becomes a vertically scrollable discovery surface. Authenticated YouTube Music shelves appear first; local “Based on this playlist” suggestions appear second. Search results continue to replace the discovery surface while a query is present. |
| Initial feed size | Request at most six shelves and retain at most twelve items per shelf. This bounds network work and usually requires no more than one continuation request. Do not poll in the background. |
| Playable scope | Display only items with a valid 11-character `videoId` in the first release. Preserve collection metadata in the internal model, but do not fake album/playlist/artist playback by searching its title. Hide collection-only shelves rather than showing dead controls. |
| Actions | Convert a playable home item to the existing `YoutubeTrack` model and reuse the same Play, Stream, and Download workflows as search results. |
| Cache | Use an in-memory 15-minute cache keyed by access revision and account slot. Do not persist a personalized feed to SharedPreferences. Clear it immediately on disconnect, cookie replacement, browser replacement, or account-slot change. |
| Refresh | One explicit Refresh Home action bypasses the cache. Coalesce simultaneous loads and ignore stale results using a generation token. |
| Account selection | Default to Google account slot `0`. Add an Advanced integer selector restricted to `0..9`; changing it increments the access revision and clears home/stream/search caches. Do not expose cookie/account IDs. |
| Brand accounts | Out of scope for the first pass. Document that a brand account may need a future optional 21-digit on-behalf-of ID after the primary account-slot implementation is verified. |
| Dependency | Pin `ytmusicapi==1.12.2` on both platforms. Keep the exact existing yt-dlp nightly pin wherever yt-dlp is embedded. |
| Security | Platform code may see cookie values in memory. Dart, method-channel payloads, stdout, stderr, files created by Resonance on Windows, preferences, and logs may not. |
| Failure isolation | A Music Home parser/server failure must not mark otherwise-working yt-dlp streaming/download access as disconnected. Only a clear missing/rejected authentication response should update YouTube Access to needs-attention. |
| Android extraction recovery | Preserve the current attempt order initially, but record every attempt by stable label. If cookie-free `android_vr` cannot resolve the failing fixture/video, bundle the matching `yt-dlp-ejs` scripts and a supported arm64 Android JavaScript runtime; do not enable remote component downloads as the permanent fix. |
| Android Python | Treat the Python 3.10 warning as scheduled runtime debt and validate Python 3.11 in the same Android media workstream, without changing the exact yt-dlp nightly pin. |

## Target architecture

```text
YoutubeSearchScreen
        |
        v
YoutubeMusicHomeService  <---- YoutubeAccessService status/revision/account slot
        |
        +---- WindowsYoutubeMusicHomeBackend
        |          |
        |          v
        |    resonance-ytmusic-home.exe
        |      - reads selected browser cookies into memory with pinned yt-dlp code
        |      - builds only the music.youtube.com Cookie header
        |      - calls pinned ytmusicapi get_home()
        |      - writes normalized non-secret JSON only
        |
        +---- AndroidYoutubeMusicHomeBackend
                   |
                   v
             resonance/android_youtube MethodChannel
                   |
                   v
             MainActivity.withYoutubeCookieCopy
                   |
                   v
             ytmusic_home_bridge.py
               - reads private Netscape copy
               - calls pinned ytmusicapi get_home()
               - returns normalized non-secret JSON only
```

`YoutubeMusicHomeService` must be the only UI-facing owner of cache, request coalescing, generation cancellation, payload validation, and platform selection. Platform backends must own authentication material and HTTP/API work.

## Shared contracts

### Dart models

Create `lib/core/youtube/youtube_music_home_models.dart` with immutable models:

```dart
enum YoutubeMusicHomeItemKind { song, video, album, playlist, artist, channel, unknown }

class YoutubeMusicHomeItem {
  String title;
  String subtitle;
  YoutubeMusicHomeItemKind kind;
  String? videoId;
  String? browseId;
  String? playlistId;
  String? thumbnailUrl;
  int? durationSeconds;
  bool get isPlayable;
  YoutubeTrack? toYoutubeTrack();
}

class YoutubeMusicHomeShelf {
  String title;
  List<YoutubeMusicHomeItem> items;
  List<YoutubeMusicHomeItem> get playableItems;
}

class YoutubeMusicHomeResult {
  int schemaVersion;
  List<YoutubeMusicHomeShelf> shelves;
  DateTime fetchedAt;
  int accessRevision;
  int authUserIndex;
}
```

Parsing requirements:

- Reject a top-level payload whose `schemaVersion` is not `1`.
- Limit shelf count, item count, and string lengths again in Dart even though helpers already limit them.
- Accept missing optional fields without crashing the complete feed.
- Require `videoId` to match `^[A-Za-z0-9_-]{11}$` before creating `https://www.youtube.com/watch?v=<id>`.
- Select the largest valid HTTPS thumbnail from the platform-normalized list, or accept a single normalized `thumbnailUrl`.
- Build artist text from the ordered `artists[].name` list. Fall back to `author[].name`, album name, then `YouTube Music`; never display `null` or a map's `toString()`.
- Drop empty titles, duplicate video IDs within a shelf, and duplicate video IDs in immediately adjacent shelves. Do not globally flatten the feed.

### Platform JSON schema

Both platform implementations must emit the same bounded schema:

```json
{
  "schemaVersion": 1,
  "shelves": [
    {
      "title": "Quick picks",
      "items": [
        {
          "kind": "song",
          "title": "Track title",
          "subtitle": "Artist",
          "videoId": "abcdefghijk",
          "browseId": null,
          "playlistId": null,
          "thumbnailUrl": "https://...",
          "durationSeconds": 213
        }
      ]
    }
  ]
}
```

Forbidden keys include `cookie`, `authorization`, `headers`, `sapisid`, `path`, `browserProfile`, raw response JSON, and account email. Add automated recursive tests that fail if forbidden keys appear at any depth.

### Backend interface

Create `lib/services/youtube/youtube_music_home_backend.dart`:

```dart
abstract interface class YoutubeMusicHomeBackend {
  Future<Map<String, Object?>> fetchHome({
    required int shelfLimit,
    required int itemLimit,
    required int authUserIndex,
  });
}
```

Provide injected fake/memory implementations for unit and widget tests. Production selection belongs in `YoutubeMusicHomeService`, not the widget.

## Authentication and status rules

Add a non-secret `youtube_access.auth_user_index` preference owned by `YoutubeAccessService`:

- Default: `0`.
- Valid values: `0..9`; reject or clamp anything outside the range at the service boundary.
- `setAuthUserIndex` increments `YoutubeAccessStatus.revision`, clears the last successful Music Home state, and notifies listeners.
- Do not clear the selected browser or imported Android cookie file when only the account slot changes.

Add `YoutubeAccessService.recordAuthenticatedSuccess()`:

- Transition `configuredUntested`, `testing`, or an old transient-unavailable state to `ready` only after a valid authenticated platform response.
- Persist `last_successful_test_at` for both platforms, not Windows only.
- On Android initialization, compare the persisted success timestamp with native `updatedAt`. Restore `ready` only if the success occurred after the current cookie import; otherwise restore `configuredUntested`.
- Do not increment credential revision for a health timestamp change.

Home eligibility state machine:

| Access state | Home request? | UI |
| --- | --- | --- |
| `notConfigured` | No | Connect card plus local suggestions |
| `configuredUntested` | Yes, once | Home loading; success records ready |
| `testing` | No second request | Keep current loading/current data |
| `ready` | Yes | Cached or live Home shelves |
| `verificationRequired` | No | Fix access card plus local suggestions |
| `rejected` | No | Reconnect/re-export card plus local suggestions |
| `unavailable` | No automatic retry | Retry and Details; do not silently use anonymous Home |

Map only explicit 401/403 authentication responses, missing `LOGIN_INFO`, missing `__Secure-3PAPISID`, or Google's login-required response to `sessionRejected`. Map timeouts/DNS to network, HTTP 429 to rate-limited, and parser-shape changes to a new `YoutubeFailureKind.musicHomeChanged` (or a similarly specific non-access kind). Do not label every HTTP 403 from media streaming as an expired session.

## Windows implementation

### Why a helper executable is required

Dart cannot safely receive browser cookies, and the existing standalone `yt-dlp.exe` cannot hand an in-memory cookie jar to another library. Exporting with `--cookies` writes every site cookie. The preferred Windows solution is therefore a dedicated one-shot helper executable which contains the same pinned yt-dlp cookie extraction code plus pinned `ytmusicapi`.

Add a source/build area such as:

```text
tool/windows_ytmusic_home/
  resonance_ytmusic_home.py
  requirements.lock.txt
  resonance_ytmusic_home.spec
  README.md
  tests/
```

Lock at minimum:

```text
yt-dlp==2026.8.20.234504.dev0
ytmusicapi==1.12.2
requests==<tested exact version>
pyinstaller==<tested exact version>
```

Do not run `yt-dlp --update` as part of the helper build. The embedded yt-dlp version must stay identical to Android and the current Windows nightly until a separate dependency update is intentionally made.

### Helper invocation

Use a narrow CLI with non-secret arguments only:

```text
resonance-ytmusic-home.exe home
  --browser firefox
  --auth-user 0
  --shelf-limit 6
  --item-limit 12
```

Rules:

- Validate browser against the same supported IDs as `WindowsBrowserDetector`.
- Never use a shell.
- Never accept cookie values, profile database paths, arbitrary URLs, output paths, or raw headers as arguments.
- Return exactly one normalized JSON document on stdout on success.
- Return a short machine code and sanitized summary on stderr on failure; never print a Python traceback in release mode.
- Impose a 30-second Dart timeout, kill the process on timeout, bound stdout/stderr to 1 MiB/64 KiB, and reject trailing non-JSON stdout.
- Add `--version` for packaging smoke tests. It should report helper schema, ytmusicapi version, and embedded yt-dlp version, without environment paths.

### In-memory cookie flow

Inside the helper:

1. Use the pinned yt-dlp Python cookie APIs to extract the selected browser's cookie jar in memory. Prefer a public/stable `YoutubeDL` option path over directly importing underscore-prefixed parser functions.
2. Ask the cookie jar for the Cookie header applicable to `https://music.youtube.com/youtubei/v1/browse`. This naturally excludes unrelated domains from the request.
3. Require a signed-in YouTube session and specifically `__Secure-3PAPISID` for the Music Home capability.
4. Build the `ytmusicapi` browser-auth dictionary in memory with `Accept`, `Content-Type`, `X-Goog-AuthUser`, origin, Cookie, and a valid SAPISIDHASH Authorization value. Do not create `browser.json`.
5. Instantiate `YTMusic(auth=<dict>, language="en")` and call `get_home(limit=shelfLimit)`.
6. Normalize and bound the result before JSON serialization.
7. Release references and exit. Do not write caches, cookies, auth JSON, diagnostics, or response dumps to disk.

The helper will necessarily decrypt/read the browser cookie database in its own memory, just as yt-dlp does now. Its output boundary is the security control.

### Dart Windows runner

Create `lib/services/youtube/windows_youtube_music_home_backend.dart`:

- Resolve the helper at `<resolvedExecutableDir>/bin/resonance-ytmusic-home.exe`.
- Read the browser ID and account slot from `YoutubeAccessService`; reject before launching if no browser is connected.
- Launch with `Process.start(..., runInShell: false)` and the same UTF-8 environment helpers used for yt-dlp.
- Collect stdout/stderr concurrently to prevent pipe deadlocks.
- Classify helper error codes into `YoutubeFailure` without exposing the raw browser profile or cookie database path.
- Call `YoutubeAccessService.observeFailure` only for explicit access failures.

Do not route this through `WindowsYtdlpRunner.run`, because it is a different executable and output contract. Continue routing every actual `yt-dlp.exe` invocation through `WindowsYtdlpRunner`; add a repository check proving no new direct yt-dlp launch was introduced.

### Packaging

- Add the helper executable to `assets/bin/` and to the install list in `windows/CMakeLists.txt`.
- Keep the helper source and lock file tracked even if the generated executable remains ignored like the existing runtime tools.
- Add the ytmusicapi MIT license and all required bundled-dependency notices to a tracked `third_party_licenses/` or equivalent release-notices location.
- Verify the release ZIP contains the helper beside yt-dlp, Deno, and FFmpeg.
- Record the helper SHA-256 during release packaging.

## Android implementation

### Dependency

In `android/app/build.gradle.kts`, add exactly:

```kotlin
install("ytmusicapi==1.12.2")
```

Keep the current yt-dlp nightly pin exactly unchanged. Confirm Chaquopy resolves pure-Python `requests` dependencies for arm64 and measure the APK size delta.

### Python bridge

Create `android/app/src/main/python/ytmusic_home_bridge.py` instead of crowding the already-large download bridge.

Implement:

```python
def get_home(cookie_file: str, auth_user: int, shelf_limit: int, item_limit: int) -> str
```

Flow:

1. Reject a missing cookie path without making a network request.
2. Load the private Netscape working copy with `http.cookiejar.MozillaCookieJar` or yt-dlp's tested cookie-jar implementation.
3. Derive only the header applicable to `https://music.youtube.com/youtubei/v1/browse`.
4. Require `__Secure-3PAPISID`; do not loosen or duplicate the broader import validator.
5. Construct the same in-memory ytmusicapi browser-auth dictionary as Windows.
6. Call `YTMusic(...).get_home(limit=shelf_limit)` on the IO dispatcher.
7. Normalize to schema version 1 and return a JSON string with no cookie/header/path fields.
8. Sanitize exceptions before they reach Kotlin. No `repr(cookie)`, request dumps, or unbounded server bodies.

Extract shared normalization concepts into similarly named functions on both platforms and drive both with the same checked-in redacted fixture. Do not try to share Python source between the APK and PyInstaller build through fragile relative paths unless the build proves reproducible.

### Kotlin and method channel

Extend the existing `resonance/android_youtube` content channel in `MainActivity.kt` with `getMusicHome`:

- Read and clamp `authUser`, `shelfLimit`, and `itemLimit`.
- Execute on `Dispatchers.IO`.
- Wrap the Python call in `withYoutubeCookieCopy`, preserving unique private copy creation and `finally` deletion.
- Return only the normalized JSON string.
- Use stable error codes such as `MUSIC_HOME_NOT_CONFIGURED`, `MUSIC_HOME_SESSION_REJECTED`, `MUSIC_HOME_NETWORK`, `MUSIC_HOME_RATE_LIMITED`, and `MUSIC_HOME_PARSE_CHANGED`.
- Never put `working.absolutePath` in `result.error` details.

Create `lib/services/youtube/android_youtube_music_home_backend.dart` to invoke the method and decode only the top-level map. Keep the existing `resonance/youtube_access` channel dedicated to import/status/launch/test operations.

## YouTube Music Home service

Create `lib/services/youtube/youtube_music_home_service.dart` as a `ChangeNotifier` or an injected service with explicit immutable state:

```dart
enum YoutubeMusicHomeLoadState {
  disconnected,
  loading,
  ready,
  needsAttention,
  networkError,
  parserChanged,
}
```

Responsibilities:

- Observe `YoutubeAccessService` and invalidate whenever credential revision or account slot changes.
- Refuse to call a backend when access is ineligible.
- Coalesce identical in-flight requests.
- Use a generation value so clearing the search field, typing a query, disconnecting, or changing credentials cannot apply stale results.
- Cache a successful result in memory for 15 minutes.
- On explicit refresh, bypass the cache but retain the old shelves until the refresh succeeds; show a small refresh indicator instead of blanking the whole page.
- On success, call `recordAuthenticatedSuccess()` and retain only shelves containing at least one playable item for the current UI.
- On auth rejection, discard the personalized cache and pass the structured failure to `YoutubeAccessService.observeFailure`.
- On network or parser failures, keep a still-valid cached result visible with an inline warning when possible.
- Dispose access listeners and cancel/ignore outstanding work correctly.

Wire one app-wide instance in `main.dart` beside `YoutubeAccessService`, or make it screen-scoped with an injected app-wide cache. Prefer app-wide provider composition because credential invalidation and account selection should not be recreated for every Search route.

## UI implementation and analysis

### Empty-query discovery layout

The current empty-query body can display only one local suggestion list. Replace that branch with a bounded `CustomScrollView`/sliver layout:

1. **YouTube Music Home header**
   - Title: `Your YouTube Music Home`
   - Subtitle: `Personalized from your connected YouTube session`
   - Refresh icon when eligible.
2. **Home status or shelves**
   - Not connected: one compact Connect YouTube card.
   - Needs attention: one Fix access card with the sanitized short message and optional Details.
   - Loading without cache: shelf skeletons, not a full-screen spinner.
   - Ready: vertically stacked titled shelves; each shelf is a horizontally scrolling row of compact artwork cards.
   - Refreshing: keep cards interactive and show progress in the header.
3. **Local suggestions section**
   - Rename visible heading to `Based on this playlist`.
   - Keep the current playlist profile, ranking, retry, and refresh behavior below the authenticated area.

Responsive behavior:

- Android: artwork cards about 148–168 logical pixels wide, horizontal shelf scrolling, at least 48-pixel action targets.
- Windows: cards about 180–220 pixels wide and mouse-wheel/shift-wheel-friendly horizontal scrolling; do not let shelves force the existing 330-pixel download queue pane off-screen.
- Use `PageStorageKey` per shelf so scroll offsets survive minor rebuilds.
- Use existing theme colors, cards, motion helpers, and thumbnail fallbacks. Do not imitate YouTube Music branding or copy its exact UI.
- Preserve keyboard focus and search preview behavior. Typing any non-empty query immediately hides discovery content and cancels/invalidates both home and local-suggestion generations.

### Home item actions

For every playable card:

- Tap artwork/title: invoke the same main Play action as a normal search result.
- Overflow or compact buttons: Play, Stream, Download.
- Construct `YoutubeTrack` once from the normalized model; do not perform a second title search.
- Continue using `TrackSourceRepository`, `MetadataCacheService`, `DownloadQueueController`, and `PlayerHandler` exactly as search results do.
- Do not report a home item as playable if it has no valid `videoId`.

Extract shared result actions out of private screen methods if needed, for example into a small `YoutubeTrackActions` collaborator. Avoid copying `_play`, `_stream`, and `_download` into home widgets.

### Settings

In `YoutubeAccessScreen`, add an Advanced `YouTube Music account slot` control only after access is configured:

- Default text: `Account 1 (slot 0)`.
- Choices: slots `0..9`, described as relevant only when multiple Google accounts are signed into the same browser/session.
- Explain that changing the slot changes which personalized Music Home is requested; it does not sign in or copy credentials.
- Provide a `Refresh Music Home`/test affordance only if it can reuse the same service call and structured errors. Do not add a second raw diagnostic path.

Do not display an account email, cookie name/value, SAPISID hash, or browser database path.

## Windows Play-button regression

This is a required parallel fix within the implementation, but it must be diagnosed as the reported action-specific bug:

- Working: with Windows browser cookies connected, the result can be added using **Stream**, and subsequent playlist streaming works.
- Broken: pressing the result card's filled **Play** button does not successfully begin standalone playback.
- Therefore, do not change cookie extraction globally or add a second resolver. Both paths must converge on `PlayerHandler._resolveStream` and `_WindowsStreamProxy`.

### Investigation sequence

1. Reproduce with one identical `YoutubeTrack` URL and connected browser session:
   - Play from result card.
   - Stream into playlist, then play from the library.
2. Capture sanitized stage markers, not secrets, for:
   - `YoutubeSearchScreen._play`
   - `PlayerHandler.playStandaloneStream`
   - `loadTrack` generation and standalone flag
   - `_resolveStream` cache hit/miss and access revision
   - `WindowsYtdlpRunner` exit/result classification
   - `_WindowsStreamProxy.register`
   - first loopback request status/range
   - `media_kit` open/playing/error state
3. Compare yt-dlp arguments. The direct Play path must include the exact same selected `--cookies-from-browser` arguments as playlist playback.
4. Verify the standalone load is not being cancelled by navigation, a competing queue load, `standaloneModeNotifier`, `_loadGeneration`, or the playback health check.
5. Verify `playStandaloneStream` does not report success before `media_kit` has actually opened the proxy URL and begun buffering/playing.
6. Verify the proxy preserves all yt-dlp-selected headers and the initial Range request in both paths.

### Fix constraints

- Keep `PlayerHandler` as the playback authority.
- Keep all Windows yt-dlp calls in `WindowsYtdlpRunner`.
- Keep `_WindowsStreamProxy`; do not expose Google cookies to media_kit or Dart HTTP headers.
- Refactor standalone and playlist activation to share one load-result contract. If `loadTrack` continues catching internally, return an explicit success/failure result or rethrow to the caller rather than relying on timing-sensitive notifier checks.
- Navigate to `StandalonePlayerScreen` only after the handler confirms that the intended generation owns the loaded source and the backend is no longer idle.
- On failure, keep Search visible and show the structured `YoutubeFailure` dialog with Fix access only for actual access failures.
- Do not make the Play button add the track to the playlist as a workaround; Play is intentionally temporary standalone playback.

### Regression tests

- A handler-level test with an injected/fake stream resolver proves standalone and playlist loads request the same source URL and authenticated revision.
- A load-generation test proves a successful standalone request cannot be mistaken for a cancelled/stale load.
- A failure-propagation test proves a resolver failure reaches `_play` and no standalone route is pushed.
- A widget test taps the filled Play button and verifies route push only after the fake handler reports a successful load.
- A Windows manual test verifies audible playback, seeking, pause/resume, and returning from standalone mode with cookies connected.

## Android Play, Stream, and Download regression

This is also required work, independent of the YouTube Music Home request itself. Use the reported video ID `8mhMnaht-cM` as a live physical-device regression target, while keeping automated tests fully offline.

Observed with cookies connected:

- Direct **Play** reaches just_audio/ExoPlayer and reports `Source error 0`.
- A URL added through **Stream** still does not play from the playlist.
- **Download** ends with `Requested format is not available` after signature and n-challenge solving fail and yt-dlp reports that only images are available.
- The same diagnostic includes the Python 3.10 deprecation warning.

The current `_extract_info` implementation tries:

1. Maintained default clients with cookies.
2. `android_vr` without cookies.
3. `web_embedded` with cookies.

However, it retains only the final attempt's exception/diagnostic. The supplied error therefore does not prove whether `android_vr` ran, what it returned, or why it failed. Fix observability before changing client order.

### Stage A — make extractor attempts auditable and safe

Replace anonymous `(opts, cookieFile)` tuples with a small internal attempt descriptor containing:

- Stable label: `authenticated-defaults`, `cookie-free-android-vr`, or `authenticated-web-embedded`.
- Whether cookies are intentionally attached; expose only `cookies=yes/no`, never a path/value.
- Extractor client name.
- Operation type: metadata, stream, or download.

For each attempt, capture a bounded sanitized summary containing only:

- Attempt label.
- Success/failure.
- Number of returned formats.
- Number of playable audio/combined formats.
- Selected format ID, extension, protocol, audio codec, and video codec on success.
- High-level failure phrases on error.

Never include media URLs, Cookie/Authorization headers, cookie paths, response bodies, or full option dictionaries. When all attempts fail, return a structured aggregate in actual attempt order rather than only the final `web_embedded` error. Extend the Details UI to display these three labeled summaries compactly.

Add a validator callback to `_extract_info` so an extractor result counts as success only when it satisfies the operation:

- Metadata/search: required ID/title fields exist.
- Stream: `_stream_payload` finds a valid HTTPS/HLS media URL and required headers.
- Download: yt-dlp selects a real playable format and begins the download; image-only metadata is not success.

This prevents an earlier attempt from returning unusable info and short-circuiting the fallback chain.

### Stage B — prove or repair the existing fallback

On a physical arm64 device, run three isolated diagnostic extractions for `8mhMnaht-cM` with the exact existing nightly:

1. Authenticated defaults only.
2. Cookie-free `android_vr` only.
3. Authenticated `web_embedded` only.

For each, run metadata/list-formats, stream resolution, and a bounded first-byte download probe. Do not infer download viability from metadata alone.

If `android_vr` returns a combined playable format such as format 18:

- Ensure the stream selector accepts combined audio/video formats as its final fallback.
- Ensure Download uses a selector that can fall back from audio-only to a directly downloadable combined format without requiring FFmpeg merging.
- Ensure `_extract_info` reaches the second attempt for both stream and download.
- Preserve the cookie-free nature of that attempt; yt-dlp intentionally skips `android_vr` when cookies are attached.
- Add an exact simulated regression where authenticated attempts return image-only/signature failures and `android_vr` returns a combined MP4.

If `android_vr` returns no playable format or a PO-token/server restriction for this video, proceed to Stage C. Do not add more hard-coded player clients blindly.

### Stage C — add an Android EJS runtime when fallback is insufficient

Full EJS support requires both components:

1. The exact `yt-dlp-ejs` version required by the pinned yt-dlp nightly.
2. A supported JavaScript runtime executable.

Implementation spike and decision gate:

- Read the pinned nightly's own `pyproject.toml`/package metadata during implementation and pin its exact required `yt-dlp-ejs` version. The current upstream line is `0.8.0`, but verify the `2026.8.20.234504.dev0` artifact rather than assuming master matches it.
- Prefer a reproducibly built QuickJS-NG arm64 executable because it is much smaller than Deno/Node and can run fully offline. Use a current optimized QuickJS-NG release; avoid versions the yt-dlp guide warns can take minutes.
- Build the executable as a PIE binary with the Android NDK. Package it in a location Android permits the app to execute (normally the app's native library directory, potentially with a library-style filename). Prove execution with `--version` on API 24 and the current target API before integrating yt-dlp.
- Configure the Python API with `js_runtimes: {"quickjs": {"path": runtimePath}}`; obtain the path in Kotlin/native code and pass only that non-secret app-owned path to Python.
- Bundle `yt-dlp-ejs` in Chaquopy. Do not depend on `--remote-components ejs:github` or `ejs:npm` for production: runtime downloads are network-dependent, update code outside an APK release, and npm mode requires Deno/Bun.
- Add all QuickJS-NG and `yt-dlp-ejs` licenses/notices required by their exact bundled versions.

If Android platform policy or Chaquopy packaging prevents a reliable standalone runtime executable, stop and document the blocker before attempting a WebView/JNI challenge-provider rewrite. Do not ship a writable copied executable or weaken Android execution security as a workaround.

After EJS integration, authenticated defaults should remain the first attempt and use the bundled runtime/scripts. Keep `android_vr` as the second resilience path and `web_embedded` last unless live evidence supports a new maintained order.

### Stage D — upgrade embedded Python to 3.11

- Confirm the installed Chaquopy plugin version supports Python 3.11 for arm64 and configure it explicitly.
- Confirm the build host uses the matching Python 3.11 build interpreter.
- Rebuild/test yt-dlp, yt-dlp-ejs, ytmusicapi, requests, FFmpegKit integration, and all current Python bridges.
- Measure APK size and startup impact.
- Keep this change separable from extractor-order fixes so a Python packaging regression can be reverted without losing diagnostics.

Python 3.11 removes the deprecation warning and future-proofs the embedded runtime; it does not replace EJS and must not be presented as the signature-solving fix by itself.

### Stage E — stream and ExoPlayer verification

`Source error 0` is a playback-backend symptom, not a useful root cause. Improve the Android playback boundary so the app can distinguish:

- No stream URL returned by yt-dlp.
- CDN/manifest HTTP 401, 403, 404, or 429.
- Missing required User-Agent/Referer/Cookie header.
- Unsupported container/codec/manifest.
- Expired URL or network timeout.

Required behavior:

- Continue returning only the selected format's URL and URL-scoped headers from Python/Kotlin; do not expose the imported cookie jar.
- Log/display a sanitized PlaybackException error code/subcode and HTTP status when available, never the URL query or headers.
- On the first source failure for a YouTube stream, invalidate that track's resolved-stream cache and perform at most one fresh yt-dlp resolution. Do not create an infinite retry loop.
- Verify URL-scoped Cookie, User-Agent, Referer, Origin, and Range behavior reach `AudioSource.uri` exactly as selected by yt-dlp.
- If a first-byte probe is added, make it bounded and reuse the exact selected headers. Avoid probing every successful stream if ExoPlayer already provides enough diagnostic data.
- Map final extraction failure to the existing YouTube failure dialog instead of leaving the user with raw `Source error 0`.

### Android regression tests

- All three extraction attempts execute in order when earlier attempts are image-only/unplayable.
- `android_vr` never receives a cookie file.
- Authenticated defaults and `web_embedded` do receive the private working copy.
- Aggregate diagnostics include all attempt labels and contain no secret/path/media URL.
- Stream selection accepts a valid combined MP4 when no audio-only format exists.
- Download selection accepts a directly downloadable combined format without requesting an unavailable merge.
- EJS smoke test reports the exact script package and QuickJS runtime as available.
- A mocked signature/n-challenge fixture succeeds once EJS is enabled.
- just_audio source failure triggers exactly one cache invalidation/re-resolution, then a structured final error.
- The exact live ID `8mhMnaht-cM` passes Play, playlist Stream playback, and Download on a physical device with cookies configured.

## File-by-file execution map

### New shared Dart files

- `lib/core/youtube/youtube_music_home_models.dart`
  - Bounded schema parsing, item kinds, playable validation, `YoutubeTrack` conversion.
- `lib/services/youtube/youtube_music_home_backend.dart`
  - Backend interface and test fake.
- `lib/services/youtube/youtube_music_home_service.dart`
  - Cookie gating, cache, in-flight coalescing, access observation, structured state.
- `lib/services/youtube/windows_youtube_music_home_backend.dart`
  - Helper process launch, bounded output, timeout, failure mapping.
- `lib/services/youtube/android_youtube_music_home_backend.dart`
  - Method-channel call and payload decoding.
- `lib/widgets/youtube/youtube_music_home_section.dart`
  - Header, shelves, cards, skeletons, Connect/Fix/error states.

### Existing Dart files

- `lib/core/youtube/youtube_access_models.dart`
  - Add a Music Home parser-change failure kind only if needed; avoid overloading `unsupported`.
- `lib/services/youtube/youtube_access_service.dart`
  - Account slot preference/setter, authenticated-success recording, Android tested-timestamp restoration, revision invalidation.
- `lib/main.dart`
  - Construct/provide/dispose the Home service and clear related caches on revision changes.
- `lib/screens/youtube/youtube_search_screen.dart`
  - Discovery sliver layout, home service consumption, shared track actions, Play-button fix integration.
- `lib/screens/settings/youtube_access_screen.dart`
  - Advanced account-slot UI and Home-specific recovery copy.
- `lib/core/audio/audio_service.dart`
  - Evidence-based Windows standalone Play fix, Android source-failure retry/classification, and test seams; preserve platform stream architectures.
- `lib/widgets/youtube/youtube_failure_dialog.dart`
  - Add concise parser-changed/home-unavailable copy without showing raw response data.

### Android files

- `android/app/build.gradle.kts`
  - Exact `ytmusicapi==1.12.2` pin, exact matching `yt-dlp-ejs` pin if Stage C is required, and Python 3.11 configuration; leave yt-dlp pin untouched.
- `android/app/src/main/python/ytmusic_home_bridge.py`
  - Authenticated request and normalized schema.
- `android/app/src/main/python/ytdlp_bridge.py`
  - Labeled aggregate attempts, operation validators, EJS runtime configuration, playable combined-format fallback, and safe diagnostics.
- `android/app/src/main/kotlin/com/example/resonance/MainActivity.kt`
  - `getMusicHome` method-channel handler using `withYoutubeCookieCopy`; pass only the app-owned JS-runtime path into Python.
- `android/app/src/main/jniLibs/arm64-v8a/` or the verified equivalent
  - Reproducibly built QuickJS-NG runtime only if the Stage C execution spike passes.
- `android/app/src/test/...`
  - Channel argument bounds/error mapping where practical.

### Windows helper/build files

- `tool/windows_ytmusic_home/resonance_ytmusic_home.py`
- `tool/windows_ytmusic_home/requirements.lock.txt`
- `tool/windows_ytmusic_home/resonance_ytmusic_home.spec`
- `tool/windows_ytmusic_home/README.md`
- `tool/windows_ytmusic_home/tests/`
- `windows/CMakeLists.txt`
  - Install the generated helper into `bin`.
- `third_party_licenses/`
  - ytmusicapi and helper bundle notices.

### Tests

- `test/youtube_music_home_models_test.dart`
- `test/youtube_music_home_service_test.dart`
- `test/youtube_music_home_section_test.dart`
- `test/windows_youtube_music_home_backend_test.dart`
- Extend `test/youtube_access_service_test.dart`.
- Extend `test/youtube_search_screen_test.dart` for gating, generation cancellation, refresh, and Play routing.
- Extend or add PlayerHandler/standalone activation tests.
- `test/python/test_android_ytmusic_home_bridge.py`.
- Extend `test/python/test_android_ytdlp_bridge.py` with aggregate-attempt, combined-format, secret-redaction, and EJS availability cases.
- Windows helper pytest suite using redacted cookie jars and recorded/hand-built response fixtures; no live credentials in source control.

## Detailed implementation sequence

Follow this order so each step has a testable contract and the lesser model does not start with UI guesswork.

### Phase 1 — Shared model and security contract

1. Add the Dart models/parser and exhaustive bounds tests.
2. Create one redacted mixed-shelf fixture containing song, video, album, playlist, artist, missing fields, duplicates, invalid thumbnail schemes, and malformed IDs.
3. Define the normalized schema and forbidden-key recursive assertion.
4. Implement the backend interface and fake.

Exit criteria: fixture parses deterministically; only valid song/video IDs convert to `YoutubeTrack`; oversized/malformed payloads fail safely.

### Phase 2 — Android backend first

1. Pin ytmusicapi.
2. Implement Python cookie-header construction, exact Music Home cookie check, auth dictionary, `get_home`, normalization, limits, and sanitized errors.
3. Add offline Python tests with mocked `YTMusic` and cookie jars.
4. Add Kotlin channel method with working-copy cleanup.
5. Add Dart Android backend.

Exit criteria: an Android unit/integration fixture returns schema v1; no secret crosses the channel; working files are deleted on success, timeout, and exception.

### Phase 3 — Windows helper

1. Build the source helper with in-memory browser extraction.
2. Add mocked-browser and mocked-ytmusicapi tests before packaging.
3. Pin the build environment and generate the one-file helper.
4. Add the Dart runner with bounded concurrent output and failure mapping.
5. Add CMake packaging and license notices.

Exit criteria: helper succeeds against a manually connected supported browser, creates no files, emits only schema v1, and release packaging contains the executable.

### Phase 4 — Access state and orchestration

1. Add account slot and tested-timestamp behavior to `YoutubeAccessService`.
2. Implement `YoutubeMusicHomeService` gating/cache/generations.
3. Test every access-state row in the state table.
4. Test revision/account changes during an in-flight request.

Exit criteria: no backend call is possible without configured access; stale personalized results cannot appear after disconnect/replace.

### Phase 5 — UI

1. Refactor empty-query discovery into scrollable sections.
2. Add Home status/header/shelves/cards.
3. Move current Suggested Music under `Based on this playlist` without changing its algorithm.
4. Reuse shared Play/Stream/Download actions.
5. Add account-slot UI in settings.
6. Verify Android/Windows responsive layouts and queue pane coexistence.

Exit criteria: connected users see personalized shelves; disconnected users see no anonymous home data; ordinary search remains unchanged.

### Phase 6 — platform playback regressions

1. Reproduce the Windows Play-only failure and add stage-level diagnostics/tests.
2. Identify the first Windows divergence from playlist playback.
3. Fix the shared Windows handler/load-result contract, not authentication globally.
4. Add labeled Android extractor-attempt aggregation and reproduce `8mhMnaht-cM` attempt-by-attempt.
5. Repair the `android_vr` format/fallback contract if it has playable media; otherwise complete the bundled QuickJS-NG plus matching yt-dlp-ejs Stage C.
6. Upgrade/validate Android Python 3.11 as a separable runtime step.
7. Add the bounded one-retry Android playback recovery and structured source-error mapping.
8. Prove Windows direct Play and playlist playback use the same authenticated resolver/proxy behavior, and prove Android Play/Stream/Download all work with cookies connected.

Exit criteria: Play begins audible standalone playback on Windows with cookies connected; Android Play, playlist Stream playback, and Download succeed for the live regression ID with cookies connected; neither platform exposes credentials in diagnostics.

### Phase 7 — Verification and documentation

1. Run formatting, static analysis, Flutter tests, Python tests, Android unit tests, and both release builds.
2. Perform the complete manual matrix below.
3. Inspect release contents and binary versions.
4. Update `docs/ARCHITECTURE.md`, `README.md`, dependency/license notices, and `docs/CODEX_CONTEXT.md` only after implementation is verified.

## Automated verification commands

Adapt exact Python executable paths to the configured local toolchain, but run at minimum:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
python -m pytest test/python tool/windows_ytmusic_home/tests
Set-Location android
./gradlew.bat app:testDebugUnitTest
Set-Location ..
flutter build apk --release
flutter build windows --release
```

Repository safety checks:

```powershell
rg -n "Process\.(start|run).*yt-dlp|ytDlpPath" lib
rg -n -i "cookie|authorization|sapisid" lib/services/youtube/*music_home* android/app/src/main/python/ytmusic_home_bridge.py tool/windows_ytmusic_home
```

The first check must show no direct `yt-dlp.exe` launch outside `WindowsYtdlpRunner`. The second is a review list: expected in-memory auth code is allowed in platform Python, but secret values must not be serialized/logged or appear in Dart payloads.

## Manual QA matrix

### Windows

- No browser connected: no Home backend process launches; Connect card works; local suggestions remain.
- Edge, Chrome, Firefox, and one Chromium variant: connect, fetch Home, refresh, Play, Stream, Download.
- Browser open vs fully closed; locked Chromium cookie DB produces the existing close-browser recovery message.
- Multiple Google accounts: slot 0 and another known slot show the intended different feed or a clear empty/wrong-slot recovery message.
- Disconnect while Home is loading: result is discarded and cached shelves disappear.
- Replace browser while Home is cached: revision invalidates cache.
- Network offline, timeout, 429, 401/403, parser fixture mismatch.
- Confirm no new files appear in temp, app data, release `bin`, or working directory after a Home request.
- Inspect stdout/stderr/Flutter logs for cookie names/values, auth hashes, profile paths, emails, and raw JSON.
- Main Play button: audible standalone playback, pause/resume, seek, return; then repeat via Stream into playlist.

### Android

- No imported file: no Python Home call; Connect card opens YouTube Access tutorial.
- Valid current-site private Firefox export: Home loads and refreshes.
- Valid yt-dlp cookie file missing exact `__Secure-3PAPISID`: regular YouTube access remains configured; Home shows re-export guidance only.
- Expired/rejected file, Replace cookies, Clear cookies, disconnect during fetch.
- Confirm unique working copy deletion after success/failure/process interruption.
- Slot change, airplane mode, slow network, 429, server/parser change.
- Play/Stream/Download a direct home song, including one with missing duration/artwork.
- Relaunch app: valid post-import tested timestamp restores ready correctly; a replaced cookie file returns to untested until a successful call.
- With cookies connected, run `8mhMnaht-cM` through direct Play, Stream into playlist then playback, and Download; retain all three labeled extractor-attempt summaries if any fail.
- Confirm the app no longer ends at raw `Source error 0`; the first failure performs at most one fresh resolution and the final UI is structured/sanitized.
- If EJS is required, verify the bundled runtime and solver scripts work in airplane mode after the media URL has already been resolved/cached only where meaningful; no challenge component may be downloaded at runtime.
- Verify Python reports 3.11 and no longer emits the 3.10 deprecation warning.

### Cross-platform UI

- Empty playlist and populated playlist.
- Search typed while Home and local suggestions are loading; neither stale result may overwrite search results.
- Clear search to return to discovery and reuse valid memory cache.
- Narrow Android portrait, Android landscape, 900px Windows, wide Windows with queue mode on.
- Keyboard navigation, focus order, screen-reader labels, reduced motion, dark/light themes.

## Acceptance criteria

The feature is complete only when all are true:

- Resonance never calls YouTube Music Home without configured cookies/browser access.
- Windows uses the selected live browser session without creating a cookie export or exposing cookie data to Dart.
- Android uses only a unique private working copy and deletes it in `finally`.
- Both platforms return the same bounded schema and show titled personalized shelves.
- At least direct song/video recommendations can Play, Stream, and Download through existing Resonance architecture.
- Disconnect/replace/account-slot changes immediately invalidate personalized data.
- Anonymous or generic Home content is never used as a silent fallback.
- Home-specific breakage does not disable otherwise-working yt-dlp behavior unless authentication is explicitly rejected.
- The Windows result-card Play button begins standalone playback with cookies connected, matching the working playlist stream path.
- Android direct Play, playlist Stream playback, and Download succeed with cookies connected for `8mhMnaht-cM`, with every extractor fallback visible in sanitized Details if they do not.
- Android either proves the cookie-free `android_vr` fallback is sufficient or ships a tested offline EJS solver/runtime stack; image-only extraction is never accepted as a playable result.
- Android no longer surfaces an unexplained raw `Source error 0`, and it performs no more than one automatic fresh-resolution retry.
- Android uses Python 3.11 without changing `yt-dlp==2026.8.20.234504.dev0`.
- All automated suites and both release builds pass.
- The Windows release contains the helper and required license notices; the Android APK contains the pinned ytmusicapi dependency.

## Non-goals

- Google OAuth, Google username/password entry, embedded Google login, or a Google Cloud API project.
- A Resonance browser extension.
- Reading Android Firefox's private profile directly.
- Exporting Windows browser cookies to disk, even temporarily.
- Sending cookie/auth data through Dart, method channels, preferences, logs, diagnostics, Companion, Sync, or analytics.
- Replacing yt-dlp search/stream/download with ytmusicapi.
- An unauthenticated YouTube Music home fallback.
- Mutating YouTube Music history, likes, subscriptions, playlists, or library.
- Full in-app browsing of album, playlist, artist, channel, podcast, or episode home cards in the first pass.
- Automatic dependency updates at runtime.
- Changing the pinned nightly yt-dlp build.
- Treating Python 3.11 alone as a JavaScript challenge solver.
- Relying on runtime GitHub/npm challenge-component downloads as the permanent Android solution.

## Risks and rollback boundaries

- **Internal endpoint drift:** `FEmusic_home` or renderers may change. Contain this inside pinned ytmusicapi/platform normalization and expose a parser-changed error. Updating the dependency should not require rewriting Flutter UI.
- **Account mismatch:** cookie files do not preserve the browser request's visible `X-Goog-AuthUser` header. Default slot 0 plus an Advanced selector is the least invasive remedy; do not guess by making many authenticated probe requests.
- **Windows browser decryption changes:** reuse the same pinned yt-dlp cookie implementation already trusted by Resonance. A helper failure must map to existing browser recovery states.
- **Binary/APK growth:** ytmusicapi is small on Android, but a second Windows PyInstaller executable duplicates Python/yt-dlp code. Measure release size before shipping. Do not trade the security boundary for a temporary all-site cookie file merely to save size.
- **Account risk/rate limiting:** fetch only on opening discovery, cache for 15 minutes, cap continuations, and refresh only on user action. Retain the current warning recommending careful use of authenticated YouTube sessions.
- **Play regression scope:** if investigation shows the failure is proxy/media-kit lifecycle rather than cookies, fix that shared lifecycle without changing Home authentication. Keep this as an independently revertible commit or patch segment.
- **Android executable policy:** Android may reject or prevent executing a bundled QuickJS command-line binary depending on packaging/API behavior. Prove the native-library-directory approach on the minimum and target API before integrating it. If it fails, stop at the documented decision gate rather than copying an executable into writable storage.
- **EJS version lock:** yt-dlp rejects unsupported solver-package versions. Derive and pin the exact `yt-dlp-ejs` requirement from the retained nightly artifact and update both only in an intentional future dependency release.
- **Android account/network variance:** the exact video can vary by account, region, IP, and rollout. Keep deterministic simulated tests for attempt order/format selection and also require the physical-device live test; neither alone is sufficient.

Rollback should be possible at three clean layers:

1. Hide/remove the discovery UI and service while leaving platform code dormant.
2. Remove one platform backend/helper without affecting existing yt-dlp operations.
3. Revert the standalone Play fix independently if it regresses ordinary playlist playback.
