# Resonance YouTube Access and Cookie Authentication Implementation Plan

Last reviewed: 2026-08-21

Implementation status: planning only. No product code has been changed for this feature.

## Outcome

Implement one app-wide **YouTube Access** system that turns yt-dlp's raw “Sign in to confirm you're not a bot” failure into a guided, recoverable workflow:

- On Windows, Resonance opens YouTube in the user's browser and uses yt-dlp's live `--cookies-from-browser` support. Resonance stores the selected browser identifier, never a copied cookie file or Google credentials.
- On Android, Resonance provides a precise Firefox Android tutorial, imports a Netscape-format `cookies.txt`, validates it, stores it inside Resonance's app-private no-backup directory, and supplies it to every Android yt-dlp operation.
- Search, metadata, streaming, downloads, playlist imports, transfer lookups, and cover lookup all use the same access state and error model.
- Authentication failures produce a compact “YouTube verification required” dialog with a route to the new settings page instead of displaying raw multi-line yt-dlp output in a snackbar.
- Replacing or clearing access credentials invalidates resolved-stream caches so stale guest URLs are not reused.

This feature does not replace the current nightly yt-dlp builds. The Windows executable and the Android `yt-dlp==2026.8.20.234504.dev0` pin remain exactly as they are unless a separate extractor-update task changes them.

## Executive decisions

| Area | Decision |
| --- | --- |
| Settings placement | Add a separate **YouTube Access** section before Downloads. Authentication affects search, playback, imports, covers, and downloads, so it must not be buried inside Download settings. |
| Windows primary path | Detect the default browser when possible, open YouTube, then test that browser with `--cookies-from-browser`. Store only the yt-dlp browser ID and non-secret status timestamps. |
| Windows cookie lifetime | Extract the current browser session on each authenticated yt-dlp invocation. Do not export or persist a Windows cookie file. |
| Windows fallback | If default-browser detection fails, show a supported-browser picker. Do not add a raw-cookie text box in v1. |
| Android browser | Use Firefox Android because it supports the requested `cookies.txt` add-on and private-browsing extension access. |
| Android export scope | The tutorial must say **Current Site → Download**. It must explicitly warn against **ALL**, which would export unrelated site credentials. |
| Android export page | Export from `https://www.youtube.com/robots.txt` in the same private tab used to sign in, then close all private tabs. This follows yt-dlp's current cookie-rotation guidance and is more durable than exporting from an open `m.youtube.com` page. |
| Android redirect prevention | Put Firefox's **Open links in apps → Never** step before any YouTube link. Include Android's YouTube app “Open by default” settings as a fallback. Resonance cannot change either setting silently. |
| Android storage | Store the validated file at a fixed path under `noBackupFilesDir`, using an atomic native write. Do not store cookie contents in SharedPreferences, Downloads, logs, sync, history, or analytics. |
| Android import UX | File import is the primary path. Do not add a visible paste field in v1; a credential-sized text box is easier to leak, log, or partially corrupt. |
| Auth usage | Access is explicit opt-in. Once configured and verified, use it for all yt-dlp-backed YouTube operations until the user clears it. This avoids a failed anonymous request before every operation on a challenged network. |
| Streaming | Return a structured stream result containing the URL and scoped request headers. Never blindly promote all exported cookies into an HTTP `Cookie` header. |
| Error classification | Match explicit verification/login phrases. A generic HTTP 403 is not enough to label a failure as authentication-related. |
| Browser extension | Do not build a “Resonance Cookies” extension in v1. The Firefox add-on already covers Android; an extension adds store review, broad permissions, trust, and maintenance obligations. |
| PO tokens/OAuth | Do not add OAuth, PO-token providers, or new forced YouTube player clients in this work. OAuth is no longer supported by yt-dlp for YouTube, and PO tokens are a separate problem. |

## Scope

This plan covers:

- The Windows browser-session connection and verification flow.
- The Android Firefox/cookies.txt tutorial, import, validation, storage, testing, replacement, and clearing flow.
- Centralized Windows yt-dlp process construction so every call site receives the same authentication arguments and diagnostics behavior.
- Android Kotlin-to-Python cookie-path propagation for every yt-dlp operation.
- Structured access status, structured YouTube failures, concise user-facing recovery UI, and queue integration.
- Stream URL/header propagation and cache invalidation after credential changes.
- Unit, widget, Python, native, manual, and release validation on both supported platforms.
- User-facing documentation and session handoff updates after implementation.

## Non-goals

Do not include any of the following in the first implementation:

- A custom Chromium/Firefox Resonance browser extension.
- A Google username/password form or embedded YouTube login page.
- OAuth login.
- Automatic Android yt-dlp updates after installation; Android's Python package remains embedded in the signed APK.
- A PO-token provider, forced `mweb` client, or changes to the existing `android_vr` / `web_embedded` fallback.
- Importing Windows cookie files or keeping a plaintext Windows cookie cache.
- Automatically changing Firefox or Android app-link settings.
- Deleting the user's original Android export from Downloads without a separate, explicit Storage Access Framework grant.
- Treating all network errors, all 403 responses, or all unavailable videos as sign-in problems.
- Uploading, syncing, backing up, or transferring credentials through Resonance Sync or PC Companion.

## Confirmed current repository state

The implementation model must begin from these verified facts, not older documentation:

- `pubspec.yaml` is `2.9.2+2`; current HEAD is `0e737ac` / `v2.9.2`.
- Windows ships yt-dlp nightly `2026.08.20.234504` in the release `bin` directory.
- Android pins `yt-dlp==2026.8.20.234504.dev0` through Chaquopy.
- The working tree already contains unrelated edits to `.gitignore` and `release/v2.9.2/patchnotes.md`. Preserve them and do not stage them as part of this feature.
- `PlayerHandler` remains the playback authority. `FileService` remains the playlist mutation authority.
- The active targets are Windows and Android only.

### Current Windows yt-dlp call sites

Direct yt-dlp processes currently exist in all of these paths:

1. `lib/widgets/youtube/windows_youtube.dart`
   - Search: `MediaDownloader._runSearch`
   - Single-link metadata: `MediaDownloader.lookup`
   - Download: `MediaDownloader._downloadAudioUnlocked`
   - Dialog metadata: `_fetchMetadata`
2. `lib/core/audio/audio_service.dart`
   - Stream extraction: `PlayerHandler._resolveStreamUrl`
3. `lib/screens/settings/settings_screen.dart`
   - Cover lookup: `_lookupFirstThumbnail`
4. `lib/services/external_playlist_service.dart`
   - YouTube playlist metadata: `_fetchWindowsYoutubePlaylistJson`

Search currently drains and discards stderr and does not reject a nonzero exit before parsing. Downloads eventually reduce the failure to `yt-dlp exited with code N`. Both behaviors hide the authentication message needed for recovery.

All direct launches must move behind one Windows runner. After migration, this verification command should find no direct yt-dlp launch outside that runner:

```powershell
rg -n "Process\.(start|run).*yt-dlp|ytDlpPath" lib
```

References to a binary path for existence checks are acceptable; process construction is not.

### Current Android boundary

- Dart uses `resonance/android_youtube` in `lib/widgets/youtube/android_youtube.dart`, `PlayerHandler`, Settings cover lookup, and external playlist import.
- `MainActivity.kt` starts Chaquopy and dispatches search, metadata, playlist metadata, first-thumbnail lookup, download, and stream resolution to `ytdlp_bridge.py`.
- Python's `_make_ydl` applies `_BASE_OPTS`, while `_extract_info` tries yt-dlp defaults and then the existing Android-safe `android_vr,web_embedded` fallback.
- No Python function currently accepts `cookiefile`.
- `get_stream_url` discards both underlying exceptions and raises a generic final message, so the original sign-in error cannot be classified.
- Android downloads use one EventChannel and are intentionally serialized by `YoutubeDownloadGate`.

### Current settings and error UI

- `SettingsScreen` uses section headers, bordered surface cards, and `_SettingsTile`. It has no width cap and tiles constrain subtitles to two lines.
- Downloads currently contains download location, history, and cover lookup.
- Raw errors are inserted into snackbars in `youtube_search_screen.dart`, both platform YouTube dialogs, cover lookup, and queue entries. This is the source of the oversized pink error shown by the user.
- `DownloadQueueEntry` stores only a free-form error string, so it cannot offer an authentication-specific action.

### Current streaming behavior

- `PlayerHandler._resolveStreamUrl` caches `Map<String, String>` by webpage URL.
- Windows parses a full yt-dlp info object and registers a loopback `_WindowsStreamProxy`, which forwards `http_headers` and range requests.
- Android returns only a raw URL and constructs `AudioSource.uri` without headers.
- Changing authentication without invalidating the cache can reuse a guest-resolved URL or old request headers.

## Research-backed constraints

The implementation must preserve the following externally verified behavior:

1. [yt-dlp authentication options](https://github.com/yt-dlp/yt-dlp#authentication-options) define `--cookies FILE` as a Netscape-format cookie file and `--cookies-from-browser BROWSER[+KEYRING][:PROFILE][::CONTAINER]` for browser-session extraction. Supported Windows choices include Edge, Chrome, Firefox, Brave, Chromium, Opera, Vivaldi, and Whale.
2. The [yt-dlp cookie FAQ](https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp) requires the first cookie-file line to be `# HTTP Cookie File` or `# Netscape HTTP Cookie File`. It also warns that combining browser extraction with `--cookies` can export cookies for every site; Resonance must not do that.
3. The [yt-dlp YouTube extractor guide](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies) says YouTube rotates cookies in open tabs. Its durable export sequence is: private window, sign in, same tab open `youtube.com/robots.txt`, export YouTube cookies, close the private window, and never reopen that session.
4. The same yt-dlp guide warns that an account used with yt-dlp can be restricted or banned and recommends using cookies only when needed or using a separate account. The UI must disclose this before connection/import.
5. The requested [cookies.txt Firefox add-on](https://addons.mozilla.org/en-US/firefox/addon/cookies-txt/) is listed on Mozilla Add-ons, is available for Firefox Android, and exports Netscape HTTP Cookie Files. It is third-party software by Lennon Hill, not a Resonance or Mozilla-authored extension.
6. Mozilla documents that Firefox Android can enable an extension for private browsing under Extensions and that installation offers an **Allow in private browsing** choice: [Firefox Android extension help](https://support.mozilla.org/en-US/kb/find-and-install-add-ons-firefox-android).
7. Mozilla's [Open links in apps guidance](https://support.mozilla.org/en-US/kb/set-firefox-android-open-links-native-apps) gives the exact path: menu → Settings → Advanced → Open links in apps → Never.
8. Flutter's official [`url_launcher`](https://pub.dev/packages/url_launcher) supports Android and Windows and opens `https` URLs in an external handler. Call `launchUrl` and handle failure rather than disabling actions solely because `canLaunchUrl` returned false.
9. Android's [`getNoBackupFilesDir`](https://developer.android.com/reference/android/content/Context#getNoBackupFilesDir()) is app-private and excluded from remote automatic backup. No storage permission is required for the app to read or write there.
10. yt-dlp's cookie jar exposes a URL-scoped header operation in [`YoutubeDLCookieJar.get_cookie_header`](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/cookies.py#L1290-L1300). Use that only for the selected media URL; never concatenate an entire cookie file into a header.

The add-on menu wording **ALL / Current Site / Current Container / Current Container and Site**, each with Copy and Download actions, was verified by the user in Firefox Android. Product copy must use the exact **Current Site → Download** wording.

## Product and UI specification

### Settings entry

Add this section between PC Companion and Downloads:

```text
YOUTUBE ACCESS
┌──────────────────────────────────────────────────────────────┐
│ [verified-user icon] YouTube access                     [>] │
│                     No authenticated session configured     │
└──────────────────────────────────────────────────────────────┘
```

The subtitle is derived from `YoutubeAccessStatus`:

- Not configured: `No authenticated session configured`
- Windows ready: `Using Edge browser session · tested 2 min ago`
- Android ready: `YouTube cookies imported · tested 2 min ago`
- Configured but untested: `Session configured · test required`
- Auth challenge observed: `YouTube verification required`
- Previously configured but rejected: `Session expired or was rejected`
- Test/network failure: `Could not verify session · tap for details`

Use an `AnimatedBuilder`/provider listener so the subtitle updates after setup without reconstructing Settings manually.

### Dedicated screen structure

Create `lib/screens/settings/youtube_access_screen.dart`.

- Use an `AppBar` titled **YouTube access**.
- On Windows, center content with a maximum width of approximately 720 logical pixels.
- On Android, use the full available width with 16-pixel horizontal padding.
- Use the current theme's `surface`, `surfaceContainer*`, `outline`, `primary`, and `error` colors. Do not hard-code a second design system.
- Use compact custom cards rather than Flutter's stock `Stepper`; stock Stepper is visually heavy on desktop and tends to overflow when steps contain several actions.
- Keep tap targets at least 48 logical pixels, support keyboard focus on Windows, and preserve readability at 2.0 text scale.
- Status must always include an icon and text; do not communicate ready/error state with color alone.

The top status card contains:

- Icon: `verified_user_rounded`, `shield_outlined`, or `warning_amber_rounded` according to state.
- Heading: `Ready`, `Setup required`, `Verification required`, `Testing…`, or `Could not verify`.
- One short explanation.
- Last successful test time when available.
- No cookie names, cookie counts, account email, profile filesystem path, or raw yt-dlp output.

### Windows flow

#### Primary flow

1. User presses **Connect browser session**.
2. Detect the current `https` default browser using the read-only Windows `UserChoice` association. Map the ProgID or associated executable name to a supported yt-dlp browser ID.
3. If detection succeeds, hold the browser choice as pending and open `https://www.youtube.com/` in the default browser.
4. Show an in-app waiting card/dialog:
   - `Sign in to YouTube or complete any verification page in the browser.`
   - `Return to Resonance when YouTube opens normally.`
   - Primary action: **I'm signed in — test access**
   - Secondary action: **Cancel**
5. Test the pending browser with an authenticated, non-downloading yt-dlp extraction and a 30-second timeout.
6. Save the browser ID only after a successful test. Increment the access revision, update status, and clear stale resolution/search caches.
7. Show `Browser session ready` and return to the access screen.

There is no reliable callback from a normal browser login to Resonance. Do not fake a fully automatic completion. The one explicit **I'm signed in — test access** press is required and makes failures understandable.

Use a normal Windows browser session, not an incognito/private window. The durable private-window export sequence is for Android's static cookie file; yt-dlp's Windows browser extractor does not read the private session, and Resonance instead reads the current regular session afresh for each invocation.

#### Browser detection and selection

Implement a Windows-only detector behind an injectable interface:

1. Read, never write, this value:

   ```text
   HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice\ProgId
   ```

2. Recognize common ProgID prefixes directly (`MSEdgeHTM`, `ChromeHTML`, Firefox URL IDs, `BraveHTML`, Vivaldi, Opera, Chromium).
3. For an unknown ProgID, query its `shell\open\command`, extract the executable basename, and map known names such as `msedge.exe`, `chrome.exe`, `firefox.exe`, `brave.exe`, `vivaldi.exe`, `opera.exe`, and `chromium.exe`.
4. Keep registry parsing in a small class with fixture-driven tests. Do not scatter `reg.exe` output parsing through widgets.
5. If detection is unsupported or permission fails, show a browser picker. Precede it with: `Choose the browser where you are signed in to YouTube.`
6. The picker may include Edge, Chrome, Firefox, Brave, Vivaldi, Opera, Chromium, and Whale. Do not show Safari on Windows.
7. yt-dlp defaults to the most recently accessed profile when no profile is supplied. Keep v1 profile-free. A failed test should explain that the signed-in profile must be the browser's currently active/recent profile.

If the user chooses a non-default browser, resolve and launch that installed executable with `Process.start(executable, [url], runInShell: false, mode: detached)`. Search registered App Paths and validated common install locations; never interpolate the URL into a shell command. If no executable can be located, leave the selection intact, copy/open the URL through the default handler, and tell the user to open it in the selected browser manually.

#### Windows ready state

Show these actions:

- **Test access**
- **Reconnect** (opens YouTube again with the current browser pending)
- **Choose another browser**
- **Disconnect** (confirmation required; clears only browser selection/status)

Include this disclosure near the actions:

> yt-dlp reads the selected browser's cookies locally when Resonance uses YouTube. Resonance does not save a Windows cookie file or your Google password.

Map common extraction failures to specific guidance:

- Cookie database missing: `No browser profile was found. Open the browser once, sign in, and retry.`
- Chromium cookie database locked/copy denied: `Close all browser windows, then retry the test.`
- Cookie decryption failed: `Windows could not unlock this browser session. Try Firefox or another supported browser.`
- Wrong/recent profile: `YouTube may be signed in under another browser profile. Make that profile active, then retry.`

### Android flow

The first-time screen is a vertical tutorial. Each card has a number, short title, two or three lines of body text, and at most two actions.

#### Step 1 — Install Firefox

Copy:

```text
Install Firefox for Android. Resonance uses Firefox because it can export a
YouTube session as the cookie file yt-dlp understands.
```

Actions:

- **Install Firefox** → `https://play.google.com/store/apps/details?id=org.mozilla.firefox`
- If already installed: **Open Firefox**

The native launcher should try `org.mozilla.firefox`, then known Firefox Beta/Nightly packages, before falling back to the Play Store or default browser.

#### Step 2 — Keep YouTube inside Firefox

This step must appear before any button which opens YouTube.

Copy:

```text
In Firefox, open ⋮ → Settings → Advanced → Open links in apps, then choose Never.
This stops YouTube links from jumping into the YouTube app while you sign in.
```

Actions:

- **View Firefox instructions** → Mozilla's official link-in-app help page.
- **YouTube app settings** → Android application details for `com.google.android.youtube`.

Fallback copy beneath the second action:

```text
If links still jump away, open “Open by default” in YouTube's app settings and
turn off supported-link opening, then return to Firefox.
```

Do not claim Resonance changed these settings; it only opens the relevant help/settings surface.

#### Step 3 — Install cookies.txt

Copy:

```text
Install the “cookies.txt” add-on by Lennon Hill from Mozilla Add-ons. During
installation, allow it in private browsing so it can export the session below.
```

Action:

- **Open cookies.txt add-on** in Firefox, using the exact link:
  `https://addons.mozilla.org/en-US/firefox/addon/cookies-txt/`

Also show an expandable permission note: the third-party add-on requests access to site data, tabs, downloads, and the clipboard. Link to the Mozilla listing; do not call it an official Mozilla add-on.

#### Step 4 — Create a durable YouTube session

Copy:

```text
Open one new private Firefox tab and sign in at youtube.com. In that same tab,
open youtube.com/robots.txt. Keep it as the only private tab.
```

Actions:

- **Open YouTube in Firefox** → `https://www.youtube.com/`
- **Open robots.txt in Firefox** → `https://www.youtube.com/robots.txt`

If the add-on is absent in the private tab, show this inline fix:

```text
Firefox ⋮ → Extensions → cookies.txt → Run in private browsing → On
```

An optional **Why robots.txt?** expansion should explain in plain language that YouTube changes account cookies while normal YouTube tabs remain open, and yt-dlp recommends this export sequence.

#### Step 5 — Export only YouTube cookies

Copy with typographic emphasis:

```text
While robots.txt is open, open cookies.txt and choose Current Site → Download.
Do not choose ALL. Then close every private Firefox tab and do not reopen that session.
```

If Firefox displays `m.youtube.com` during login, that is acceptable while signing in, but the final export page must be `www.youtube.com/robots.txt` so the tutorial and validation are deterministic.

#### Step 6 — Import into Resonance

Copy:

```text
Import the downloaded .txt file. Resonance validates it, keeps an app-private
copy, and tests it without downloading audio.
```

Actions:

- Primary: **Import cookies.txt**
- Secondary: **Choose another file** after a failed validation

After a successful import and test:

- Replace the tutorial with a compact ready card.
- Show **Test access**, **Replace cookies**, **Show guide**, and **Clear cookies**.
- Show a persistent reminder: `Delete the original cookies.txt from Downloads. Treat it like a password.`
- Do not delete the source automatically; the file picker may expose only a copied cache path or lack delete permission for the original document.

### Account safety disclosure

Before the first Windows connection or Android import, show a compact warning card:

```text
This uses a signed-in YouTube session. Automated requests can cause YouTube to
temporarily restrict or permanently disable an account. Use only when YouTube
requires verification, avoid large batches, and consider a separate account.
```

Require an acknowledgement for the first setup only. Persist a non-secret boolean so the warning is not shown on every test. Clearing access does not need to reset the acknowledgement.

## Technical architecture

### 1. Shared status and failure models

Create models under `lib/core/youtube/` or `lib/models/`:

```dart
enum YoutubeAccessMethod { none, windowsBrowser, androidCookieFile }

enum YoutubeAccessState {
  notConfigured,
  configuredUntested,
  testing,
  ready,
  verificationRequired,
  rejected,
  unavailable,
}

class YoutubeAccessStatus {
  final YoutubeAccessMethod method;
  final YoutubeAccessState state;
  final String? browserId;
  final DateTime? configuredAt;
  final DateTime? lastTestedAt;
  final String? shortMessage;
  final int revision;
}
```

Use immutable values and `copyWith`. `revision` increments only when the effective credential source changes: successful browser connect/change/disconnect, Android import/replace/clear. A status-only test does not increment it.

Create a structured exception:

```dart
enum YoutubeFailureKind {
  verificationRequired,
  sessionRejected,
  browserProfileMissing,
  browserCookiesLocked,
  browserDecryptionFailed,
  invalidCookieFile,
  rateLimited,
  network,
  unavailable,
  unsupported,
  unknown,
}

class YoutubeFailure implements Exception {
  final YoutubeFailureKind kind;
  final String userMessage;
  final String technicalSummary; // sanitized and bounded
  final String? sourceUrl;
}
```

The classifier must:

- Recognize case-insensitive forms of `Sign in to confirm you're not a bot`, `Use --cookies-from-browser or --cookies`, and `LOGIN_REQUIRED` as `verificationRequired` when no access is configured.
- Classify the same response as `sessionRejected` when authenticated access was actually used.
- Recognize browser-database not found, copy/permission, and decryption messages separately.
- Recognize explicit request-limit wording separately.
- Preserve unavailable/private/deleted/geo-restricted video errors as content failures.
- Treat a bare `403 Forbidden` as unknown/network unless an explicit authentication phrase is also present.
- Remove ANSI codes, collapse whitespace, cap diagnostics to approximately 4 KiB, and redact user-profile/cookie file paths.
- Never include cookie file contents, header values, or process arguments containing a profile path in a user-visible detail string.

### 2. `YoutubeAccessService`

Create an injectable `ChangeNotifier` service, for example:

```text
lib/services/youtube/youtube_access_service.dart
lib/services/youtube/youtube_access_backend.dart
lib/services/youtube/windows_youtube_access_backend.dart
lib/services/youtube/android_youtube_access_backend.dart
```

Responsibilities:

- Initialize the platform backend and publish `YoutubeAccessStatus`.
- Expose `isConfigured`, `isReady`, `revision`, and the settings subtitle.
- Coordinate acknowledge/connect/test/import/replace/clear operations.
- Record access-relevant failures observed outside Settings and update the state.
- Provide Windows auth arguments internally to the Windows runner; widgets must not build them.
- Notify `PlayerHandler` and search services when the effective credential source changes.

Persist only non-secret data in SharedPreferences:

```text
youtube_access.warning_acknowledged
youtube_access.windows_browser_id
youtube_access.windows_configured_at
youtube_access.last_successful_test_at
```

Do not persist Android cookie contents, account information, a cookie path, or HTTP headers in Dart preferences. Query the Android native store for Android status.

Initialize the service in `main.dart` before creating UI providers. Pass it into `PlayerHandler` through constructor injection, with a test-friendly optional fake. Add it to `MultiProvider` beside `PlayerHandler`, `DownloadQueueController`, and `SyncSessionService`.

Avoid calling platform methods from a widget constructor. Initialization must be idempotent and return a stable status even if a platform method fails.

### 3. Central Windows yt-dlp runner

Create `lib/services/youtube/windows_ytdlp_runner.dart`. Do not put new live code in the currently empty legacy `lib/core/youtube/ytdlp_service.dart` without either deleting/redirecting that legacy file or documenting why it became authoritative.

The runner owns:

- `yt-dlp.exe` and `deno.exe` path resolution relative to `Platform.resolvedExecutable`.
- Required common arguments:
  - `--js-runtimes deno:<path>`
  - `--force-ipv4`
  - `windowsYtDlpUtf8Arguments`
- `windowsYtDlpUtf8Environment` and parent-environment inclusion.
- Appending `--cookies-from-browser <browserId>` only when access is configured or a pending browser is being tested.
- Process startup with `runInShell: false`.
- Two APIs:
  - `start(...)` for streaming progress/cancellable searches.
  - `run(...)` for bounded stdout/stderr collection and optional timeout.
- A structured result containing exit code, stdout, sanitized stderr tail, and whether authenticated arguments were used.
- Throwing `YoutubeFailure` on nonzero exit, timeout, missing binary, or invalid output.

Do not put global `--no-warnings` in the runner; some callers can request it, but the runner needs stderr for classification. Do not print the full argument list when it contains a browser profile. Do not use a shell string.

Use a bounded tail buffer (32–64 KiB) for diagnostics rather than allowing a long playlist process to retain unlimited stderr. Preserve existing line-by-line download progress and the `_backgroundSearchProcesses` cancellation behavior.

Migrate every verified Windows call site to this runner. In particular:

- Search must check the exit code before returning/caching results.
- Search must not cache an empty result caused by an authentication failure.
- Download must preserve a bounded stderr tail and stop immediately on authentication/browser-cookie errors rather than repeating the same request three times.
- The current three-attempt retry remains only for transient network failures.
- Playlist imports and cover lookup keep their existing timeouts and user semantics.

### 4. Windows connection test

The backend test should use a known, stable public test video unless the recovery dialog provides the URL which just failed. Prefer the failed source URL because it proves the exact challenged extraction.

Fallback test URL:

```text
https://www.youtube.com/watch?v=BaW_jenozKc
```

Run an authenticated simulation with no media download, one video only, and a 30-second timeout. Require a valid extracted video ID or info object, not merely exit code zero. Never print cookies or dump them to a file.

Commit a pending browser selection only after a successful test. If the test fails for ordinary network reasons, retain it in screen state but do not mark the app ready.

### 5. Android cookie validator

Create one pure Dart validator for immediate UI feedback and an equivalent native validation gate before storage. Native code must not trust that the Dart validator was called.

Validation rules:

1. Reject null, empty, or larger-than-1-MiB data.
2. Strip a UTF-8 BOM and accept CRLF or LF line endings.
3. Require the first non-empty line to be exactly `# HTTP Cookie File` or `# Netscape HTTP Cookie File`.
4. Parse non-comment rows as seven tab-separated Netscape fields: domain, include-subdomains flag, path, secure flag, expiry, name, value.
5. Treat `#HttpOnly_...` rows as cookie rows by removing the prefix before parsing; do not discard them as comments.
6. Require valid TRUE/FALSE flags, a non-empty name, and a numeric expiry or `0`.
7. Require at least one cookie whose normalized domain is `youtube.com` or ends in `.youtube.com`.
8. Do not require hard-coded cookie names; YouTube can change them.
9. Do not rewrite the file to only a guessed list of cookie names. The user's **Current Site** export is the scope control.
10. Return counts/domains only internally for validation; never show names or values in UI or logs.

Validation messages must be specific:

- `This file is empty.`
- `Choose the Netscape cookies.txt file downloaded by the Firefox add-on.`
- `This file does not contain YouTube cookies. Export Current Site while youtube.com/robots.txt is open.`
- `This cookie file is too large. Do not export ALL sites.`

### 6. Android native storage and access channel

Add focused Kotlin classes instead of expanding every concern directly inside the already-large `MainActivity.kt`, for example:

```text
android/app/src/main/kotlin/com/example/resonance/YoutubeCookieStore.kt
android/app/src/main/kotlin/com/example/resonance/YoutubeAccessBridge.kt
android/app/src/main/kotlin/com/example/resonance/FirefoxLauncher.kt
```

Use a dedicated channel:

```text
resonance/youtube_access
```

Proposed contract:

| Method | Arguments | Result |
| --- | --- | --- |
| `getStatus` | none | `{configured, updatedAt, sizeBytes}`; never contents |
| `importCookies` | `{bytes: Uint8List}` | validated status map |
| `clearCookies` | none | updated status map |
| `testCookies` | `{url?: String}` | `{ok, testedAt}` or structured platform error |
| `isFirefoxInstalled` | none | boolean |
| `openFirefoxUrl` | `{url: String}` | `{launched, package?}` |
| `openYoutubeAppSettings` | none | boolean |

Storage requirements:

- Fixed target: `<noBackupFilesDir>/resonance_youtube/cookies.txt`.
- The Dart side never supplies a destination path.
- Create the directory only as needed.
- Use `android.util.AtomicFile` or equivalent temp/finish/fail semantics so a crash cannot leave a half-written credential file.
- Before each Python operation, create a uniquely named working copy under `<noBackupFilesDir>/resonance_youtube/work/`, pass that copy to yt-dlp, and delete it in `finally`. yt-dlp writes cookie files on close; per-invocation copies prevent a long download from locking or corrupting the canonical file while search/playback runs.
- Serialize only the short canonical-file copy/import/clear operation. Do not serialize the full yt-dlp lifetime. Remove stale working copies during access-service startup in case the process previously crashed.
- Keep ordinary Android app-UID filesystem protection; no storage permission is needed.
- Derive updated time from the file or store non-secret metadata separately.
- `clearCookies` performs an ordinary file delete and clears status metadata. Do not claim secure flash erasure.
- Return no cookie text, names, domains, or values over the channel after import.

Add narrow `<queries>` entries in `AndroidManifest.xml` for known Firefox packages if installation detection is used. Do not request `QUERY_ALL_PACKAGES`.

The Firefox launcher must:

- Validate that URLs are `https` and belong to the fixed allow-list used by the tutorial.
- Prefer standard Firefox, then Beta/Nightly when installed.
- Use an explicit package intent for YouTube and add-on links so the YouTube app cannot intercept the launch.
- Catch `ActivityNotFoundException` and return a clean fallback result.

### 7. Android Python propagation

Update every public Python entry point to accept an optional native-supplied cookie path:

```text
search(query, limit, cookie_file=None)
get_metadata(url, cookie_file=None)
get_playlist_metadata(url, cookie_file=None)
get_first_thumbnail(query, cookie_file=None)
get_stream_data(url, cookie_file=None)
download(url, output_dir, event_sink, cookie_file=None)
test_access(url, cookie_file)
```

Kotlin asks `YoutubeCookieStore` for a per-invocation working copy of the fixed canonical file, passes that copy to the Python call, and deletes it in `finally`. Dart does not repeat any cookie path on existing YouTube operations.

Change `_make_ydl` / `_extract_info` so a present, readable cookie file becomes yt-dlp's `cookiefile` option. Preserve these invariants:

- `_BASE_OPTS` remains unchanged unless directly required for cookies.
- The default-client attempt still runs first.
- The exact existing `android_vr,web_embedded` fallback remains second.
- No OAuth, visitor data, `mweb`, PO token, or forced additional client is added.
- If all stream format attempts fail, rethrow the most informative underlying exception rather than the current generic `Could not resolve stream URL` message.

`YoutubeDL` may save updates back to its cookie file on close. Those updates remain confined to the disposable working copy; do not merge them blindly into the canonical export. This preserves concurrent search/playback during a long download and keeps the private Firefox export as the stable credential source. No module-level lock should serialize full authenticated operations.

`test_access` must perform extraction only, require a valid video ID, and never download media.

### 8. Structured stream result

Create a shared in-memory model:

```dart
class ResolvedYoutubeStream {
  final Uri uri;
  final Map<String, String> headers;
  final int accessRevision;
}
```

#### Android

Replace `getStreamUrl`'s raw string with JSON/map data from Python:

```json
{
  "url": "https://...",
  "headers": {
    "User-Agent": "...",
    "Referer": "..."
  }
}
```

Select headers from the same chosen format as the returned URL, falling back to top-level `http_headers`. While the `YoutubeDL` instance is still open, call `ydl.cookiejar.get_cookie_header(streamUrl)` and include it only if the jar says cookies are scoped to that exact media URL. Do not add all cookie-file rows. Never log or persist the returned headers.

Construct Android `AudioSource.uri(resolved.uri, headers: resolved.headers)`. Add a compatibility parser only if required during migration; remove the old raw-string contract once Kotlin, Python, and Dart land together.

#### Windows

Keep the loopback proxy so media_kit receives a simple local URL and range behavior remains stable. Continue forwarding the selected format's `http_headers`.

Do not turn yt-dlp's top-level `cookies` info field into a global `Cookie` header. yt-dlp intentionally scopes cookies to target URLs. Validate real challenged-IP playback; if a selected media URL needs a cookie, add only a URL-scoped cookie through a safe helper, never the whole browser jar.

#### Cache invalidation

- Cache `ResolvedYoutubeStream` against both webpage URL and access revision, or clear the URL cache whenever the revision changes.
- Do not remove a Windows proxy entry currently serving playback merely because access changed; that could turn the current track into a 404. Clear future resolution cache entries and let old proxy registrations expire naturally.
- Bound Windows proxy registrations and stream-cache entries to prevent unbounded credential/header retention in memory.
- Clear the Windows search cache when browser access changes so an empty/guest result is not reused.

### 9. Failure presentation and recovery

Create one reusable presenter/widget, for example:

```text
lib/widgets/youtube/youtube_failure_dialog.dart
```

For `verificationRequired` or `sessionRejected`, show:

```text
Title: YouTube verification required
Body: YouTube blocked this request until a signed-in session is provided.
Actions: Not now | Open YouTube access
```

If access was configured but rejected, change the body to:

```text
Your saved YouTube session was rejected or expired. Reconnect the browser session
or replace cookies.txt, then retry.
```

The recovery action pushes `YoutubeAccessScreen`, optionally passing the source URL which failed so **Test access** can validate that exact video. Do not automatically restart a download after credentials change; the user explicitly taps Retry to avoid surprising network or disk activity.

For non-auth failures, show a short message and optional **Details** expansion/copy action. Details are sanitized and bounded. Never put full raw stderr in the main snackbar/dialog body.

Apply the presenter/classifier to:

- Search and suggested-search failures.
- Play-now and playlist-stream resolution failures.
- Immediate and queued downloads.
- Both legacy platform YouTube dialogs if they remain active.
- External playlist import.
- Playlist transfer YouTube lookup/download paths.
- Fill Missing Covers.

### 10. Download queue and history

Extend `DownloadQueueEntry` with a structured failure kind or `YoutubeFailure` summary rather than only a raw string.

For an access failure, the queue row shows:

```text
Verification required
[Fix access] [Retry]
```

- **Fix access** navigates to `YoutubeAccessScreen` with the failed source URL.
- **Retry** remains explicit and should be disabled while access setup/testing is in progress.
- Later queued entries continue according to current FIFO semantics; one failed entry must not stop the worker.
- Preserve the existing one-active-download constraint and Android EventChannel serialization.

Pass a compact user message to `DownloadHistoryRepository.recordFailure`. Do not store multi-line stderr or credential paths in history.

## File-by-file change map

| File / area | Planned change |
| --- | --- |
| `pubspec.yaml` | Add current compatible `url_launcher` dependency; run `flutter pub get`. |
| `lib/main.dart` | Initialize/provide `YoutubeAccessService`; inject it into `PlayerHandler`. |
| `lib/core/youtube/` or `lib/models/` | Add access status, failure, classifier, validator, and resolved-stream models. |
| `lib/services/youtube/` | Add access coordinator, platform backends, Windows browser detector, and centralized Windows yt-dlp runner. |
| `lib/screens/settings/settings_screen.dart` | Add separate YouTube Access section/tile; migrate cover lookup to the Windows runner and structured failures. |
| `lib/screens/settings/youtube_access_screen.dart` | Add responsive Windows connection UI and Android guided import UI. |
| `lib/core/audio/audio_service.dart` | Inject access service, use central runner, accept structured Android stream data/headers, and invalidate caches by revision. |
| `lib/widgets/youtube/windows_youtube.dart` | Migrate search/lookup/download/metadata to runner; preserve progress/cancel behavior; expose structured failures. |
| `lib/widgets/youtube/android_youtube.dart` | Normalize PlatformExceptions/events into `YoutubeFailure`; parse structured stream result where appropriate. |
| `lib/screens/youtube/youtube_search_screen.dart` | Replace raw snackbars with failure presenter and recovery navigation. |
| `lib/services/external_playlist_service.dart` | Use central runner/structured Android failures and preserve current timeouts. |
| `lib/services/youtube_transfer_service.dart` and import UI | Propagate structured failures without changing playlist/source semantics. |
| `lib/services/download_history_repository.dart` | Persist only the compact user-safe failure summary/code, never raw multi-line process output. |
| `lib/models/download_queue_entry.dart` | Add failure kind/summary. |
| `lib/services/download/download_queue_controller.dart` | Store structured failures and keep retry explicit. |
| `lib/widgets/youtube/download_queue_panel.dart` | Add compact Fix access action and bounded text. |
| `android/app/src/main/kotlin/.../MainActivity.kt` | Wrap every existing Python operation in creation/final cleanup of a private cookie working copy; register access bridge. |
| New Kotlin access/store/launcher files | Atomic storage, native revalidation, status, testing, Firefox launching, app settings. |
| `android/app/src/main/python/ytdlp_bridge.py` | Optional cookie path everywhere, structured stream data, test method, and informative errors; no full-operation global lock. |
| `android/app/src/main/AndroidManifest.xml` | Narrow Firefox package visibility declarations only if queried. |
| Tests | Add classifier, validator, service, runner, browser detection, UI, queue, stream, Python, and native parser coverage. |
| `README.md`, release notes, `docs/CODEX_CONTEXT.md` | Document setup/security, record implementation decisions and verification after code is complete. |

## Implementation sequence

Execute in this order. Each checkpoint should compile/test before proceeding so a lesser model can isolate failures.

### Phase 0 — Baseline and protection

1. Record `git status --short` and preserve the existing `.gitignore` and v2.9.2 patch-note edits.
2. Run baseline `flutter analyze` and `flutter test` before product edits.
3. Run the existing Python bridge suite:

   ```powershell
   python -m unittest test/python/test_android_ytdlp_bridge.py
   ```

4. Do not build or update yt-dlp during this phase.

Checkpoint: the pre-feature tree passes the same tests it passed before implementation, or any pre-existing failure is documented before code changes.

### Phase 1 — Pure models, validation, and classification

1. Add `YoutubeAccessStatus`, `YoutubeFailure`, `YoutubeFailureClassifier`, `YoutubeCookieValidator`, and `ResolvedYoutubeStream`.
2. Add pure unit tests with real representative yt-dlp error strings, including the user's screenshot text.
3. Ensure no test fixture contains real cookies.

Checkpoint: pure Dart tests pass without platform channels or filesystem access.

### Phase 2 — Access service and startup wiring

1. Add backend interfaces and `YoutubeAccessService`.
2. Add fake/in-memory backend for tests.
3. Initialize/provide the singleton in `main.dart` and inject it into `PlayerHandler` without changing transport authority.
4. Add revision listening, but do not alter stream resolution yet.

Checkpoint: app starts on Windows and Android with `notConfigured`; all existing tests compile.

### Phase 3 — Centralize Windows yt-dlp

1. Implement the runner and browser detector.
2. Migrate one low-risk call first (`MediaDownloader.lookup`) and test output/error handling.
3. Migrate search while preserving background cancellation and caching.
4. Migrate downloads while preserving line progress, playlist output paths, retry gating, history, and import callbacks.
5. Migrate dialog metadata, PlayerHandler extraction, cover lookup, and external playlist metadata.
6. Run the `rg` audit for direct launches.

Checkpoint: all Windows YouTube operations work anonymously exactly as before when no browser is connected, and synthetic auth stderr becomes a `YoutubeFailure`.

### Phase 4 — Windows setup UI

1. Add default-browser detection and pending selection.
2. Add URL launch, waiting state, test, commit, reconnect, choose, and disconnect flows.
3. Add browser-specific safe guidance.
4. Add service/widget tests with fake detector, launcher, and runner.

Checkpoint: connecting never writes a cookie file and SharedPreferences contains only browser/status metadata.

### Phase 5 — Android store, native bridge, and tutorial

1. Implement native revalidation and atomic no-backup storage.
2. Register the dedicated access channel.
3. Implement Firefox/package launching and app-settings fallback.
4. Add tutorial UI and `file_picker` import.
5. Add ready/replace/clear states.

Checkpoint: valid fake Netscape data is stored only under `noBackupFilesDir`; invalid/oversize/non-YouTube data never replaces an existing valid file.

### Phase 6 — Android yt-dlp integration

1. Add optional cookie parameters in Python without changing the existing fallback clients.
2. Pass a unique native working-copy path from Kotlin to every operation and delete it in `finally`.
3. Add `test_access` and preserve the underlying stream failure.
4. Extend Python fakes/tests for cookie options and concurrency assumptions.

Checkpoint: each Android operation's test observes `cookiefile` when configured and observes no cookie option after clear. Concurrent operations use different working paths, all working copies are cleaned up, and existing fallback-client assertions remain unchanged.

### Phase 7 — Stream headers and cache revision

1. Return structured Android URL/header data.
2. Apply headers to `AudioSource.uri`.
3. Move Windows extraction through the runner without weakening the loopback proxy.
4. Invalidate future cache entries when access revision changes; keep current playback alive.
5. Bound proxy registrations/header lifetime.

Checkpoint: stream, seek, pause/resume, next/previous, and replay work on both platforms before and after credential replacement.

### Phase 8 — App-wide error recovery

1. Add reusable failure dialog.
2. Replace raw auth snackbars in Search/platform dialogs.
3. Add queue failure kind and Fix access action.
4. Update import/transfer/cover/history surfaces.
5. Audit all `error.toString()` rendering in YouTube paths.

Checkpoint: the full screenshot error can no longer appear as the primary snackbar body anywhere in the app.

### Phase 9 — Verification, docs, and release preparation

1. Run formatting only on touched files.
2. Run all automated checks below.
3. Perform the manual matrix on a challenged network/IP, not only a network where guest extraction succeeds.
4. Update `README.md` with a short YouTube Access section and security warning.
5. Update the eventual release patch notes; do not reuse or overwrite v2.9.2 notes.
6. Replace the relevant state in `docs/CODEX_CONTEXT.md` with implemented decisions, unresolved issues, symbols, and the single best next step.

Checkpoint: definition of done is satisfied on both release builds.

## Automated test plan

### Dart unit tests

Add coverage for:

- Both accepted cookie headers, UTF-8 BOM, CRLF/LF, blank lines, and `#HttpOnly_` rows.
- Invalid header, six/eight-field rows, invalid flags/expiry, empty file, oversize file, no YouTube domain, and a correct Current Site-style export.
- Explicit bot/login strings with and without configured access.
- Browser profile missing, locked database, decryption failure, rate limit, deleted/private video, generic 403, timeout, and unknown failures.
- Diagnostic sanitization, ANSI removal, size cap, and Windows user-path redaction.
- Access-state transitions and revision changes.
- Windows argument generation with no auth, configured browser auth, and pending test auth.
- Browser ProgID/executable mapping fixtures.
- Resolved-stream cache keys and invalidation.
- Queue failure kind and explicit retry behavior.

### Widget tests

Use injected fake platform/access backends so tests do not depend on the host OS.

Verify:

- Settings shows the new independent section and each subtitle state.
- Windows connect states: detected browser, unknown-browser picker, testing, success, locked DB, rejected session, disconnect confirmation.
- Android tutorial contains the exact Firefox path and **Current Site → Download** wording.
- The add-on action targets exactly `https://addons.mozilla.org/en-US/firefox/addon/cookies-txt/`.
- The YouTube-open action appears after the redirect-prevention step in reading order.
- Valid import collapses the guide; Show guide expands it again.
- Invalid import leaves the previous valid credential intact.
- At 320/360-pixel width and 2.0 text scale, actions wrap rather than overflow.
- Keyboard focus/activation works for Windows actions.
- Auth failure dialog never renders the full raw yt-dlp message.
- Queue access failure exposes Fix access and Retry.

### Python tests

Extend `test/python/test_android_ytdlp_bridge.py` to verify:

- `cookiefile` is absent when no path is supplied.
- `cookiefile` is present on search, metadata, playlist, thumbnail, stream, download, and test operations when supplied.
- Defaults still run before `android_vr,web_embedded` fallback.
- No new player client is introduced.
- Stream result contains selected URL and headers.
- URL-scoped cookie header is included only when the fake jar returns one.
- The original verification exception survives both format attempts.
- `test_access` does not download.
- Unicode download metadata remains intact.

Update `FakeYoutubeDL` with a fake cookie jar and any close/save behavior needed by the new path without importing real yt-dlp during unit tests.

### Kotlin/native tests

Keep the cookie parser/storage input validator in a pure Kotlin component and add JVM unit coverage for header/domain/size/HttpOnly cases. If Android filesystem context makes the store hard to unit test without adding a large framework, test parser/decision logic on the JVM and validate the actual `AtomicFile` path manually in a debug APK.

Do not add broad native-test dependencies solely for this feature unless they are required to protect storage correctness.

### Static and build checks

Run:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
python -m unittest test/python/test_android_ytdlp_bridge.py
flutter build windows --release
flutter build apk --release
```

If Kotlin JVM tests are added, also run the relevant Gradle unit-test task. Record APK/Windows artifact paths and hashes only during the release task.

## Manual QA matrix

### Windows

Test at least Edge, Chrome, and Firefox:

- Default browser is detected correctly.
- Default browser signed in before setup.
- Browser not signed in; user signs in and returns.
- Multiple profiles; most recently active signed-in profile is used.
- Unsupported/unknown default triggers picker.
- Chromium database locked while browser is open; guidance is correct and retry works after close.
- Connect, app restart, test, choose another browser, and disconnect.
- SharedPreferences contains no cookie data.
- No `cookies.txt` is created anywhere by Resonance.

### Android tutorial and storage

- Firefox absent: Install action works.
- Firefox present: add-on and YouTube links open explicitly in Firefox.
- With normal app links enabled, the tutorial warning appears before YouTube; after setting Never, YouTube stays in Firefox.
- YouTube-app settings fallback opens on devices which have the app.
- Add-on is allowed in private browsing.
- Login → same private tab → robots.txt → Current Site → Download works.
- Choosing ALL creates an oversize/broad export warning if it exceeds limits; the tutorial still explicitly says not to use it.
- Import valid file, restart app, test, replace, clear, and test after clear.
- Import malformed/non-YouTube/empty/oversize data while a valid file exists; valid file remains untouched.
- Delete original export from Downloads; Resonance's private copy continues to work.
- Reinstall/clear app data; private credentials are gone.
- Verify with `run-as` on a debug build that the file is under `noBackupFilesDir` and absent from public/external storage. Never print its contents.

### YouTube operations on both platforms

Run every operation first with no access and then with configured access:

- Search and type-ahead preview.
- Suggested music lookup.
- Play now from Search.
- Add stream to playlist and play it later.
- Seek within a stream and resume after pause.
- Immediate audio download.
- Queued audio download and explicit retry.
- Multi-item YouTube playlist metadata/import.
- Playlist transfer lookup/download path.
- Fill Missing Covers.
- Auth replacement while a stream is currently playing; current playback remains alive and the next resolution uses the new revision.

Use a network/IP which reproduces `Sign in to confirm you're not a bot`. A normal guest-friendly network is not sufficient to sign off this feature.

### Security observation

During manual tests:

- Search logcat/console output for known fake cookie values; none may appear.
- Inspect download history and SharedPreferences; no cookie value/path may appear.
- Confirm diagnostic Details redact profile/private paths.
- Confirm Resonance Sync and PC Companion payloads never include access state details beyond a non-secret ready/not-ready indicator—and preferably include nothing at all.
- Confirm no automatic download restarts after setup.

## Failure and edge-case policy

| Situation | Expected behavior |
| --- | --- |
| No access configured, guest works | Preserve current anonymous behavior; never force setup. |
| No access configured, explicit bot challenge | Show verification dialog and Settings action. |
| Access configured, explicit bot challenge persists | Mark session rejected; ask to reconnect/replace. |
| Android cookie file disappeared | Downgrade to not configured and do not pass a stale path. |
| Android import valid but live test times out | Keep it as configured-unverified; offer Test again, Replace, Clear. |
| Windows browser cannot be detected | Browser picker; no registry writes. |
| Browser DB is locked | Specific close-browser guidance; do not retry three times automatically. |
| Generic 403 during CDN playback | Treat as stream/network failure; do not automatically claim cookies are missing. |
| Video is deleted/private/geo-blocked | Preserve content-specific message; do not route to access unless yt-dlp explicitly requests login. |
| Cookie change during playback | Current stream continues; future resolutions use new revision. |
| One playlist item succeeds before a later failure | Preserve/import successful files according to existing platform semantics; report remaining failure concisely. |
| Firefox/AMO link cannot open | Keep URL visible/copyable and show a short launch failure. |
| User selects Copy instead of Download | v1 guide redirects them to Download; no large clipboard paste field. |
| Account is rate-limited | Explain request limit and suggest waiting; reconnecting cookies is not presented as the guaranteed fix. |

## Rejected approaches and rationale

- **Raw cookie text field:** makes a password-equivalent credential visible, easy to paste partially, and easy to include in logs/screenshots. Validated file import is safer and simpler.
- **Export ALL cookies:** leaks unrelated site sessions. The tutorial and validator are designed around Current Site.
- **Android default browser for YouTube links:** allows the YouTube app to intercept them, recreating the exact UX failure the user reported. Use explicit Firefox intents.
- **Export from an ordinary open YouTube tab:** cookies can rotate while the tab remains open. Follow the private-tab + robots.txt sequence.
- **Windows `--cookies-from-browser` plus `--cookies`:** writes all extracted browser cookies to a file, contrary to the local-minimum storage design.
- **Always convert 403 into “sign in”:** masks expired CDN URLs, missing headers, rate limits, and network problems.
- **Build the Resonance extension first:** duplicates an available Android exporter and creates high-trust distribution/permission work before the app has a complete import path.
- **Silently add PO-token/client workarounds:** changes a separate extractor behavior and could break the newly working nightly build. Keep this feature limited to authentication.

## Definition of done

The feature is complete only when all of the following are true:

- Windows can connect, test, persist only the browser choice, use it across every yt-dlp operation, and disconnect without creating a cookie file.
- Android provides the exact redirect-safe Firefox tutorial, exact add-on link, private-session/robots guidance, and Current Site → Download instruction.
- Android validates and atomically stores credentials only in app-private no-backup storage, and all Python operations receive the path only while configured.
- Search, stream, download, cover lookup, transfer, and playlist import work on the user's challenged network/IP after setup.
- Android streaming passes the selected format's required headers and remains seekable.
- Credential replacement/clear invalidates future cached resolutions without interrupting the current Windows stream.
- No YouTube surface displays the giant raw yt-dlp error as its primary message.
- Queue/history store only compact structured failures and offer explicit access recovery/retry.
- No cookie value is present in logs, preferences, history, public storage, backup, Sync, Companion, or UI.
- Existing Android fallback clients and pinned nightly package are unchanged.
- `flutter analyze`, the full Flutter suite, Python tests, relevant Kotlin tests, Windows release build, and Android release APK build pass.
- Manual QA is completed on both a normal network and a network/IP which reproduces YouTube's verification challenge.

## Best next step for the implementing session

Start with **Phase 0**, then implement the pure status/failure/validator models and tests from **Phase 1**. Do not begin with the Settings screen: central process/error behavior must exist first so the UI is not wired to another one-off yt-dlp path.
