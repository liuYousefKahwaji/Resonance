# Try the updater locally

These fixtures update **Resonance Update Test 3.4.5 → 3.4.6**. They do not
replace your normal app, change its library, create GitHub releases, or upload
anything. The source version remains 3.4.5+12.

## 1. Start the local feed

In PowerShell, from the repository folder:

```powershell
./build/release-tools-venv/Scripts/python.exe tool/release/lab.py --root build/update-lab-phone/feed --seed build/update-lab-phone/test-manifest.seed
```

Leave this terminal running. Stop it with Ctrl+C when finished.

## 2. Windows

1. Extract `build/update-lab-phone/base/resonance-v3.4.5-windows.zip` into a
   **new folder**, away from your normal Resonance installation.
2. Run its `resonance.exe`. The window says **Resonance Update Test**.
3. Change a test setting, then open Settings → Check for updates → Update
   and restart.
4. Confirm version 3.4.6 and that the setting survived. This should use the
   smaller download.

Test data is under `%LOCALAPPDATA%/ResonanceUpdateTest`. To repeat, close the
test app and extract the base ZIP into another fresh folder.

## 3. Android phone

Enable USB debugging and connect your phone. From another PowerShell terminal:

```powershell
$adb = "$env:LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"
& $adb devices
& $adb reverse tcp:8765 tcp:8765
& $adb install -r build/update-lab-phone/base/resonance-v3.4.5.apk
```

If several devices appear, add `-s YOUR_PHONE_SERIAL` after `$adb` in each
command. These APKs are for arm64 phones; the separate `build/update-lab`
APKs are for the x86_64 emulator.

1. Open **Resonance Update Test** alongside your normal Resonance app.
2. Finish its onboarding, change a test setting, and check for updates.
3. Start the update and put the app in the background. Keep USB connected.
4. Allow this test app to install unknown apps and approve Android's installer
   prompt if requested. Background preparation does not bypass OS approval.
   If notifications are disabled, reopen the app to recover the approval prompt.
5. Reopen and confirm 3.4.6 with the setting preserved.

To repeat, uninstall **only Resonance Update Test**, then reinstall the base.
This resets only test data. Do not uninstall between base and target when
checking that settings survive an update.

## Optional failure checks

Stop the feed and add a mode to the same server command:

- `--mode corrupt-patch`: the patch fails and the app uses the verified full
  download.
- `--mode bad-signature`: the app rejects the update without installing it.
- `--mode full`: use a full download directly.
- `--mode interrupted-download`: slow the transfer so you can stop/restart
  the server and retry.

Use a fresh base installation for each cycle. Restart without `--mode` to
restore normal patch updates. See [README.md](README.md) for rebuilding these
fixtures, recovery logs, and GitHub Actions setup.
