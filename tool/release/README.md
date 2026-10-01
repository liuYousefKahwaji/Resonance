# Release pipeline and update lab

## Test without touching GitHub

For the fixtures already prepared on this PC, start with [TESTING.md](TESTING.md).

The lab runs entirely on this PC. It creates no tags/releases, uploads nothing,
and sends no announcements. Test builds accept a separate signing key and only
the local feed. Production builds accept only signed assets from this repository.

Build the fixtures once from the repository root in PowerShell:

```powershell
./tool/release/build_lab.ps1
```

This builds two versions of **Resonance Update Test**, 3.4.5+12 and 3.4.6+13,
and verifies direct patches. Build versions are supplied as Flutter arguments;
pubspec stays 3.4.5+12. Existing lab folders are never overwritten. Move
`build/update-lab/base`, `target`, and `feed` aside when rebuilding fixtures,
and keep `test-manifest.seed` / `trusted_keys.json` together so their identity
stays consistent. For an x86_64 Android emulator use `-AndroidAbi x86_64`.
Separate phone fixtures can use `-LabDirectory build/update-lab-phone`; point
lab.py's `--root` and `--seed` at that folder's feed and test-manifest.seed.
APKs must match the device ABI: the x86_64 fixtures are for the emulator;
arm64-v8a fixtures are for normal phones.

Start the feed in another terminal:

```powershell
./build/release-tools-venv/Scripts/python.exe tool/release/lab.py
```

### Windows

1. Extract `build/update-lab/base/resonance-v3.4.5-windows.zip` into a new folder,
   for example `build/update-lab/windows-install`.
2. Run its `resonance.exe`. Its title is **Resonance Update Test**; it uses
   `%LOCALAPPDATA%/ResonanceUpdateTest` for preferences, playlists, and caches.
   It has a separate instance mutex and does not replace the normal shortcut.
3. In Settings choose Check for updates, then Update and restart.
4. Confirm version 3.4.6 after restart and that any test preferences/playlists
   survived. The transaction journal/log is under
   `%LOCALAPPDATA%/ResonanceUpdateTest/tmp/resonance-update/<transaction>/`.

For an automated lab run, launch the extracted executable with
`--resonance-update-lab-install`. This switch only works in the compiled test
profile. It records the chosen download size and whether a delta was selected
in `%LOCALAPPDATA%/ResonanceUpdateTest/support/update-lab-result.json`.

The normal app's profile is untouched. Keep the test installation separate from
the normal portable installation. To repeat an upgrade, close the test app and
extract the base ZIP into a fresh test folder.

### Android phone

1. Connect with USB debugging enabled. Run `adb devices`; select your phone with
   `adb -s SERIAL` if more than one device appears.
2. Run `adb reverse tcp:8765 tcp:8765` to forward the phone's localhost feed to
   this PC. Leave the cable and local feed connected during the test.
3. Install `build/update-lab/base/resonance-v3.4.5.apk` with
   `adb install -r build/update-lab/base/resonance-v3.4.5.apk`.
4. Open **Resonance Update Test**, complete/skip its onboarding, and check for
   updates in Settings. Download the update, then put the app in the background.
5. Allow this test app to install unknown apps when prompted. Approve the
   installer or Play Protect prompt if Android asks. The update can prepare in the background; OS
   installation approval is still handled when required.
6. Reopen and confirm 3.4.6. Check that test preferences/playlists survived.

The package is `com.example.resonance.updatertest`, so the normal Resonance app
and its library remain installed. To inspect the test version:

```powershell
adb shell dumpsys package com.example.resonance.updatertest
```

Automated preparation (test APKs only):

```powershell
adb shell appops set com.example.resonance.updatertest REQUEST_INSTALL_PACKAGES allow
adb shell am start -n com.example.resonance.updatertest/com.example.resonance.MainActivity --ez resonance_update_test_install true
```

Inspect test progress with `adb logcat -s ResonanceUpdateLab`. Test APKs keep
release compilation and use the isolated sandbox; their debug log channel is
absent from the production updater.
To force an Android approval prompt for a background-recovery test, add
`--ez resonance_update_test_require_approval true` to the automated start.
Reopen the test app after it prepares in the background; a pending approval is
recovered even if notifications were disabled. Cancelled installation waits
for an explicit retry instead of reopening the installer repeatedly.
Do not uninstall the base between base and target when checking data retention.
For a new test cycle you can uninstall **only the test package**, then reinstall
the base (this clears test data).

### Failure cases

Stop the feed with Ctrl+C and restart using `--mode MODE`:

Add `--chunk-delay 0.03` to slow a transfer for background/interruption checks.

| Mode | Expected result |
| --- | --- |
| `normal` | Uses a matching small direct patch. |
| `full` | Signed metadata disables patches; downloads the full package. |
| `corrupt-patch` | A signed but invalid patch fails reconstruction/preflight and falls back to the verified full package. |
| `wrong-source` | The installed hash differs; chooses full before downloading a patch. |
| `bad-signature` | Rejects the update; no full fallback. |
| `interrupted-download` | Slow delivery lets you stop the server/cancel mid-download. Restart the feed, retry, and verify Windows range resume / Android system download recovery. |

Windows automated installer tests also inject a failure during file replacement
and verify rollback, managed deletions, and preservation of unknown/user files.
After an interrupted Windows update, ordinary launch recovers its journal before
Flutter initialization. If damaged DLLs prevent even the native runner from
starting, use **Recover Resonance.cmd** in the installation folder.

## CI setup (once, when ready)

No CI configuration, secrets, tags, or releases have been changed remotely by
this implementation. Back up these two local signing identities securely:

- Existing Android keystore: `%USERPROFILE%/.android/debug.keystore`.
- Manifest signing seed: `%USERPROFILE%/.resonance-release-secrets/update-manifest.seed`.

The Android certificate must stay
`d504a82e662a5a2596607084b2b64d84170519c3193fc7d7cc915bdfdc794fba`.
A newly generated debug keystore with the same password/alias is a different
identity and cannot update existing installations. The manifest public key is
in `assets/update/trusted_keys.json`; private seeds are never repository assets.

Repository Actions secrets:

| Name | Value |
| --- | --- |
| `ANDROID_KEYSTORE_B64` | Base64 bytes of the exact existing keystore. |
| `ANDROID_KEYSTORE_PASSWORD` | `android` for the existing debug keystore. |
| `ANDROID_KEY_ALIAS` | `androiddebugkey`. |
| `ANDROID_KEY_PASSWORD` | `android`. |
| `UPDATE_MANIFEST_SIGNING_KEY_B64` | Base64 bytes of the existing 32-byte manifest seed. |
| `DISCORD_WEBHOOK_URL` | Existing optional announcement webhook. |

Create environments `release-signing` and `release-publishing`, restrict them to
main, and optionally require approval. Add `DISCORD_RESONANCE_ROLE_ID` if using
role mentions. The helper `configure_secrets.py --configure-github` validates
both local identities and uploads only the five signing secrets through stdin.
It never creates a release or enables publishing. Read/review it before running.

1. Commit/push the implementation after review, with the signing secrets ready.
2. Use Actions → **Build and release Resonance** → Run workflow. Manual runs
   are always dry runs. Download **verified-release-3.4.5** from its artifacts;
   nothing is added to Releases and the app's latest release is unchanged.
3. Once satisfied, set repository variable `RESONANCE_AUTO_RELEASE_ENABLED=true`.
   The next push on main with a version above the latest stable release creates
   a draft, uploads/verifies every asset, then publishes it. A new semantic
   version and a strictly higher Android build number are required.
4. Update `pubspec.yaml` and write `release/vVERSION/patchnotes.md` for each
   release. Pushes with no version increase do not publish another release.

CI uses the tested Flutter 3.44.2 revision, Java 17/Python 3.10 for Android,
Windows 2022/VS2022 for Windows, and pinned action revisions. Android releases
fail if the exact keystore is missing. The prepare job independently verifies
APK signing/package/version, reconstructs every retained patch with the same
decoder shipped in the app, and verifies Windows target trees before signing.
The signing seed is exposed only to the signing job; the publisher needs only
the GitHub token and verifies signed metadata again. Full packages are uploaded
first so older updaters can install the bootstrap release.

The bootstrap is 3.4.5. Users on 3.4.4 or earlier download full ZIP/APK once.
Later builds retain direct old → newest patches for up to five stable bases
published in the previous 90 days. Patches at least 70% of full size are omitted.
Older/modified/split installs use the signed full package. Invalid signatures
or missing signed metadata are rejected rather than bypassed.

Publication refuses an existing version/tag instead of overwriting it. If an
upload fails the release stays a draft and latest is unchanged. Inspect/delete
that unpublished draft/tag explicitly before retrying, or bump the version.
Announcement is invoked directly after publication because release events
created by `GITHUB_TOKEN` do not trigger the existing release workflow. Do not
retry publication just to resend a failed announcement.

Local `release/vVERSION/` binaries remain ignored. Only patchnotes.md is source.
No app playlists, cookies, logs, private keystores, or seeds are release assets.

## Verification commands

```powershell
flutter analyze
flutter test
./build/release-tools-venv/Scripts/python.exe -m unittest discover -s tool/release/tests -v
```

Native decoder tests and actual APK benchmarks are documented in BENCHMARKS.md.
For a production build after using the lab, run the normal Flutter release build
without test defines; build directories themselves hold the last variant built.
