# Google Drive playlist transfer and sync

This is optional cloud playlist transfer, using the same YouTube IDs, source
matching and Stream/Download import flow as QR transfer, plus opt-in automatic
sync for individual playlists. Audio files, account cookies, local paths,
listening history, settings and track adjustments are not uploaded.

## What users see

1. Settings → Google Drive → **Connect Google Drive**.
2. The account's avatar/name and **Logout** appear in Settings.
3. Resonance finds its existing **ResonanceMusic** folder in My Drive, or creates
   it. **Drive playlists** opens the saved playlists with refresh/pull-to-refresh.
4. **Save a playlist to Drive** selects a local playlist. Unknown sources use
   the existing matching/review screen. The confirmation reports skipped tracks.
5. Opening a saved playlist uses the existing import preview: stream the tracks,
   download them, or reuse matching audio already present locally. Track order
   and duplicate entries are preserved. Import creates a local playlist, using
   the existing name collision handling.

6. Turn on **Keep in sync** while saving or importing to link that local playlist.
   Open its row in Drive playlists for sync status, **Sync now**, the per-device
   Stream/Download preference, or to turn sync off. Existing local playlists can
   be linked by saving/replacing their Drive copy with the switch enabled.
7. Each cloud playlist's **⋮** menu offers **Replace from library** and **Delete
   from Drive**. Delete asks first and moves only the cloud file to Google Drive
   Trash. Local playlists and audio stay intact; other linked devices stop
   syncing that cloud copy when they detect its removal.

Linked playlist names, additions, removals and order sync after a two-second
edit debounce, on resume and approximately every 30 seconds while Resonance is
running. Unchanged cloud files need only a metadata/version check. Offline edits
persist locally; stable occurrence IDs, logical clocks and deletion markers merge
concurrent changes without losing independent additions or reviving old tracks.
Concurrent edits to the same name/position resolve deterministically. An apply
journal and conditional local writes protect interruptions and in-flight edits.

Download mode queues missing audio through the existing queue; deleting a synced
entry never deletes the audio file. Unmatched local-only tracks remain local in
their original positions. Deleting a local playlist disconnects its sync binding
and leaves the cloud copy; playlist-1 promotion carries the other binding with its
file. Logout pauses sync on this device. Android sync runs while its process is
alive and catches up on reopening; no closed-app OS wakeup or instant background
delivery is promised. No server, webhook or new OAuth scope is required.

Sync data is an optional checksummed field alongside the original version-1
transfer payload. Older clients can still import nonempty snapshots, but replacing
a synced file with an old-client manual snapshot pauses sync until explicitly
re-linked. Replacement in this version keeps sync identities/deletion history
and rebinds the selected local playlist without creating duplicate additions.
Deletion markers are bounded, not discarded behind an offline device's back.
Device bindings and their local paths stay outside portable backups and Drive.

For unlinked playlists, save changes to Drive explicitly. A matching cloud name
offers **Save a copy** or **Replace stored playlist**. Replacement checks remote
membership and modification time, and uses an ETag precondition to reject a
concurrent change. Logout removes this device's connection, not the Drive folder
or local playlists. Other devices stay connected.

### Drive version checks

Do not require an HTTP ETag header from Drive v3: live responses omit it. For
conditional mutations the service obtains the documented v2 File `etag` JSON
field, validates the same folder membership and sends v2 `PUT`/Trash with
`If-Match`. Its opaque in-memory revision token has a `v2:` prefix. Listing and
new-file creation remain v3. The same `drive.file` scope works for both APIs.

A metadata ETag must not be sent to `alt=media`: the media representation can
return 412 even with the current file tag. Read content without that header and
verify the file revision before/after. True conflicts refetch/merge as before.
Successful writes update the local catalog immediately instead of failing due
to an unrelated post-write refresh. User operations share a serialized queue;
explicit replacement/deletion pauses the matching local sync worker. The live
API probes and client/controller integration tests use disposable files only.

## One-time Google setup (no Resonance server)

### Audio files: Drive music

Settings → Google Drive → **Drive music**, or the cloud button in **Browse library**,
opens a separate audio browser. It discovers music folders from paginated audio
metadata instead of recursively walking every Drive directory. Folder views offer
playback, adding a streaming playlist, and downloading the folder's direct tracks.
Subfolders open separately. MP3, FLAC, WAV, M4A, AAC, OGG, OPUS and WEBM are supported.

Existing playlist sync still uses only `drive.file`. The explicit **Browse existing
music** action additionally requests `https://www.googleapis.com/auth/drive.readonly`.
Add this scope under Google Auth Platform → Data Access in the same Cloud project
and keep test accounts in Audience while testing. Google classifies this broad
read scope as restricted; public distribution requires the applicable Google OAuth
verification. Refusing it leaves playlist sync and app-owned uploads usable.
Resonance does not request full-Drive write permission.

Uploads go to an app-created **ResonanceMusic/Audio** folder. Users can choose local
files or upload a playlist's local tracks; streaming entries are skipped. Resumable
one-MiB chunks recover acknowledgements after interrupted responses, and MD5/size
verify the result. Identical name/content is reused, different content never
overwrites a user's existing file. Downloads stream to a partial file, resume with
validated byte ranges, verify size/MD5, then import or replace the surviving stream
entry. Existing downloaded files are reused. Original local files are untouched.

Playback stores stable account/file references, resolves fresh authorization only
in memory, and uses Drive's authenticated media endpoint with range support. The
player stops a Drive stream when its owning account disconnects. Shared files with
download restrictions cannot be streamed/downloaded through this feature. Credentials
never enter playlist URLs, Drive playlist documents, metadata or portable backups.
Transfers survive route changes while Resonance's process remains alive. Partial
downloads can resume on retry; upload-session state is not persisted across process
death. This feature does not promise closed-app uploads or folder-edit synchronization.

### OAuth project and clients

Use one Google Cloud project for **all** Resonance platform OAuth clients.
The Firebase project supplied for initial setup is `insighter-7d882`. Reusing it
is possible; a dedicated Resonance project can keep consent branding and API
administration separate from Insighter. Choose before public deployment: switching
projects later can make the old app-created Drive files inaccessible under
`drive.file`, requiring migration/re-authorization.

1. [Enable Google Drive API](https://console.cloud.google.com/apis/library/drive.googleapis.com?project=insighter-7d882).
2. Open [Google Auth Platform](https://console.cloud.google.com/auth/branding?project=insighter-7d882).
   Configure the app name **Resonance**, support/developer email and the required
   consent information. Do not rename an existing Insighter consent screen unless
   that is intended for its other applications too. Choose External audience if
   personal Google accounts must connect. While Testing, add each tester's Google
   account. Google limits testing grants; in particular, desktop refresh tokens
   for an External app in Testing with Drive access normally expire after seven
   days. Publish the consent configuration when ready for general use and meet
   any verification/branding requirements Google presents. No Play Store listing
   or Firebase Authentication backend is needed.
3. Configure these data-access scopes: `openid`, `profile`, `email`, and
   `https://www.googleapis.com/auth/drive.file`. Do not request full `drive` scope.
4. Under [Clients](https://console.cloud.google.com/auth/clients?project=insighter-7d882),
   create a **Desktop app** client for Windows. Download its JSON. Use its
   `installed.client_id` and `installed.client_secret` for the Windows build
   defines below. This is an installed/public OAuth client; its packaged client
   value is not a confidential web-server secret. Never use a service-account
   private key or an OAuth Web client secret here.
5. Create an **Android** OAuth client for `com.example.resonance`, with the
   SHA-1 of the exact certificate signing the APK. The existing debug/release
   certificate on the original development PC has:

   ```text
   SHA-1   46:02:8A:6C:A6:84:6B:A4:30:7F:69:58:07:C8:39:FF:9B:B2:10:7A
   SHA-256 D5:04:A8:2E:66:2A:5A:25:96:60:70:84:B2:B6:4D:84:17:05:19:C3:19:3F:C7:D7:CC:91:5B:DF:DC:79:4F:BA
   ```

   CI already restores this exact signing keystore. A different local debug key
   needs its own registered Android certificate. The isolated updater/emulator
   test package `com.example.resonance.updatertest` also needs its own Android
   client registration if testing sign-in there.
6. In the **same project**, create or reuse a **Web application** OAuth client.
   Its **client ID only** is `GOOGLE_DRIVE_ANDROID_SERVER_CLIENT_ID`. The Google
   Sign-In Android SDK requires this ID even though Resonance has no server. Do
   not put its Web client secret in the app. The Android client ID from step 5
   does not go in this field. No redirect URI/backend is needed for this SDK use.
   Registration is passed directly to the SDK, so no `google-services.json`,
   Firebase SDK or Google Services Gradle plugin is required.

### Local builds

Copy `tool/google_drive/oauth.example.json` to the ignored root file
`google-drive.local.json`. Fill in the three fields using the registered clients:

```json
{
  "GOOGLE_DRIVE_WINDOWS_CLIENT_ID": "DESKTOP_CLIENT.apps.googleusercontent.com",
  "GOOGLE_DRIVE_WINDOWS_CLIENT_SECRET": "DESKTOP_INSTALLED_CLIENT_VALUE",
  "GOOGLE_DRIVE_ANDROID_SERVER_CLIENT_ID": "WEB_CLIENT.apps.googleusercontent.com"
}
```

Build the platforms sequentially:

```powershell
flutter build windows --release --dart-define-from-file=google-drive.local.json
flutter build apk --release --target-platform android-arm64 --dart-define-from-file=google-drive.local.json
```

Without configuration the rest of Resonance still works; Connect reports that
Drive has not been configured in this build. Client definitions are compiled
into the app; changing the JSON requires a new build. Do not upload end-user
access tokens, refresh tokens, private signing keys or service-account keys.

### GitHub Actions

Set repository Actions variables:

- `GOOGLE_DRIVE_WINDOWS_CLIENT_ID`: Desktop client ID.
- `GOOGLE_DRIVE_ANDROID_SERVER_CLIENT_ID`: Web client ID used by Android.

Set repository Actions secret:

- `GOOGLE_DRIVE_WINDOWS_CLIENT_SECRET`: Desktop installed client value.

The workflow writes a temporary defines file without printing values. Missing
configuration leaves Drive unavailable rather than failing unrelated builds;
partially configured Windows fields fail clearly. Changing only Actions
configuration does not change the source tree used by artifact reuse: use a
manual dry run with **force_rebuild**, and publish a fresh app version for users.
Do not republish unchanged-version assets just to add OAuth definitions.

## Scope and privacy

`drive.file` grants access to files/folders created by this Google application
or explicitly opened for it. The folder is **visible**, not Drive's hidden
`appDataFolder`. With platform clients in the same project, the app-created
folder/files can be reused across devices on the same account. A manually created
folder with the same name, a folder owned by a different app project, or files
added independently in the Drive UI are not automatically granted to Resonance.
This version has no Google Picker folder adoption; it does not broaden permissions
to scan the whole Drive. If simultaneous first connections create duplicate
app-accessible ResonanceMusic folders, all are read and the oldest becomes the
write target. No folder is deleted or merged destructively.

Windows uses system-browser authorization with state, PKCE and a three-minute
timeout on an ephemeral IPv4 loopback port. Google access/refresh credentials and
the small profile are encrypted through the Windows secure-storage plugin.
Android uses native Google Sign-In/authorization and Google-managed sessions;
SDK tokens are not copied into preferences. Portable backups exclude sessions.
The data files contain playlist names, ordered YouTube IDs and available cached
track titles/artists in a versioned, size-bounded JSON envelope with integrity
checksums. Cached names let imports display tracks without extracting each one
from YouTube first. The version-1 identity payload/checksum stays unchanged;
optional names have their own checksum, so older files and clients remain
compatible. This is not end-to-end encryption: the user's storage provider can
read the playlist metadata.

## Testing without changing public releases

- Use an External/Testing OAuth configuration and your own test accounts. These
  files live in those accounts, not the Resonance GitHub repository.
- Build/run locally with the defines file; no tag/release/push is required.
- Connect Windows and Android to the same account. Save a playlist containing
  duplicate entries, then check order and both Stream/Download import modes.
- Save a changed version explicitly; test replacing versus saving a copy.
- Try offline access, denied consent, browser cancellation, logout/reconnect,
  moved/deleted cloud files and expired permissions. Logout must not delete local
  tracks or the cloud folder. Connecting another account must not show stale
  playlists from the previous account.
- Automated tests use an in-memory credential store, mocked Google HTTP and an
  actual local OAuth callback listener. They do not authorize a real Google account
  or establish live cross-platform cloud access; test that after configuration.

References: [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth),
[folder API](https://developers.google.com/workspace/drive/api/guides/folder),
[desktop authorization](https://developers.google.com/identity/protocols/oauth2/native-app),
[Android plugin registration](https://pub.dev/packages/google_sign_in_android).
