@echo off
setlocal EnableExtensions DisableDelayedExpansion

cd /d "%~dp0" || (
  echo ERROR: Could not open the Resonance repository.
  exit /b 1
)

echo.
echo Resonance release
echo =================
set "VERSION="
set /p "VERSION=Version (for example 2.4.1): "

powershell.exe -NoProfile -Command ^
  "if ($env:VERSION -cmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { exit 0 } else { exit 1 }"
if errorlevel 1 (
  echo ERROR: Enter a version as three numbers separated by dots, without a leading "v".
  exit /b 1
)

set "PUBSPEC_VERSION="
for /f "tokens=2" %%V in ('findstr.exe /B /C:"version:" "pubspec.yaml"') do set "PUBSPEC_VERSION=%%V"
for /f "tokens=1 delims=+" %%V in ("%PUBSPEC_VERSION%") do set "PUBSPEC_VERSION=%%V"
if not "%PUBSPEC_VERSION%"=="%VERSION%" (
  echo ERROR: pubspec.yaml is version %PUBSPEC_VERSION%, not %VERSION%.
  echo Update pubspec.yaml before creating this release.
  exit /b 1
)

where.exe git.exe >nul 2>&1
if errorlevel 1 (
  echo ERROR: Git was not found on PATH.
  exit /b 1
)

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
  echo ERROR: This script must be inside the Resonance Git repository.
  exit /b 1
)

set "BRANCH="
for /f "delims=" %%B in ('git branch --show-current') do set "BRANCH=%%B"
if not defined BRANCH (
  echo ERROR: Git is in detached HEAD state. Check out a branch first.
  exit /b 1
)

git remote get-url origin >nul 2>&1
if errorlevel 1 (
  echo ERROR: The Git remote "origin" is not configured.
  exit /b 1
)

echo.
choice.exe /C EB /N /M "Use [E]xisting release builds or [B]uild both now? "
if errorlevel 2 goto build
if errorlevel 1 goto validate_builds
echo ERROR: No build option was selected.
exit /b 1

:build
where.exe flutter.bat >nul 2>&1
if errorlevel 1 (
  where.exe flutter.exe >nul 2>&1
  if errorlevel 1 (
    echo ERROR: Flutter was not found on PATH.
    exit /b 1
  )
)

echo.
echo Building Android APK...
call flutter build apk --release
if errorlevel 1 (
  echo ERROR: Android release build failed.
  exit /b 1
)

echo.
echo Building Windows release...
call flutter build windows --release
if errorlevel 1 (
  echo ERROR: Windows release build failed.
  exit /b 1
)

:validate_builds
set "APK_SOURCE=%CD%\build\app\outputs\flutter-apk\app-release.apk"
set "WINDOWS_SOURCE=%CD%\build\windows\x64\runner\Release"

if not exist "%APK_SOURCE%" (
  echo ERROR: Android release APK not found:
  echo   %APK_SOURCE%
  exit /b 1
)
if not exist "%WINDOWS_SOURCE%\resonance.exe" (
  echo ERROR: Windows release executable not found:
  echo   %WINDOWS_SOURCE%\resonance.exe
  exit /b 1
)
if not exist "%WINDOWS_SOURCE%\data\" (
  echo ERROR: Windows release data directory not found:
  echo   %WINDOWS_SOURCE%\data
  exit /b 1
)
if not exist "%WINDOWS_SOURCE%\flutter_windows.dll" (
  echo ERROR: Windows Flutter runtime not found:
  echo   %WINDOWS_SOURCE%\flutter_windows.dll
  exit /b 1
)

set "RAR_EXE="
for /f "delims=" %%R in ('where.exe rar.exe 2^>nul') do if not defined RAR_EXE set "RAR_EXE=%%R"
if not defined RAR_EXE if exist "%ProgramFiles%\WinRAR\rar.exe" set "RAR_EXE=%ProgramFiles%\WinRAR\rar.exe"
if not defined RAR_EXE if exist "%ProgramFiles(x86)%\WinRAR\rar.exe" set "RAR_EXE=%ProgramFiles(x86)%\WinRAR\rar.exe"
if not defined RAR_EXE (
  echo ERROR: rar.exe was not found. Install WinRAR or add rar.exe to PATH.
  exit /b 1
)

echo.
echo Checking origin/%BRANCH%...
git fetch origin "%BRANCH%"
if errorlevel 1 (
  echo ERROR: Could not fetch origin/%BRANCH%. No commit was created.
  exit /b 1
)

set "BEHIND_COUNT="
for /f "delims=" %%C in ('git rev-list --count "HEAD..origin/%BRANCH%"') do set "BEHIND_COUNT=%%C"
if not defined BEHIND_COUNT (
  echo ERROR: Could not compare the local branch with origin/%BRANCH%.
  exit /b 1
)
if not "%BEHIND_COUNT%"=="0" (
  echo ERROR: %BRANCH% is behind origin/%BRANCH% by %BEHIND_COUNT% commit^(s^).
  echo Pull or rebase those changes, then run this script again.
  exit /b 1
)

set "RELEASE_DIR=%CD%\release\%VERSION%"
set "APK_DEST=%RELEASE_DIR%\Resonance-Android-v%VERSION%.apk"
set "RAR_DEST=%RELEASE_DIR%\Resonance-Windows-v%VERSION%.rar"
set "RAR_TEMP=%TEMP%\Resonance-Windows-v%VERSION%-%RANDOM%-%RANDOM%.rar"

if exist "%RAR_TEMP%" del /Q "%RAR_TEMP%" >nul 2>&1

echo.
echo Packing the Windows release...
"%RAR_EXE%" a -r -ep1 -idq -m5 "%RAR_TEMP%" "%WINDOWS_SOURCE%\*"
if errorlevel 1 (
  if exist "%RAR_TEMP%" del /Q "%RAR_TEMP%" >nul 2>&1
  echo ERROR: Could not create the Windows RAR archive.
  exit /b 1
)

"%RAR_EXE%" t -idq "%RAR_TEMP%"
if errorlevel 1 (
  del /Q "%RAR_TEMP%" >nul 2>&1
  echo ERROR: The Windows RAR archive failed verification.
  exit /b 1
)

if not exist "%RELEASE_DIR%\" mkdir "%RELEASE_DIR%"
if errorlevel 1 (
  del /Q "%RAR_TEMP%" >nul 2>&1
  echo ERROR: Could not create:
  echo   %RELEASE_DIR%
  exit /b 1
)

echo Copying release artifacts...
copy /Y "%APK_SOURCE%" "%APK_DEST%" >nul
if errorlevel 1 (
  del /Q "%RAR_TEMP%" >nul 2>&1
  echo ERROR: Could not copy the Android APK.
  exit /b 1
)

move /Y "%RAR_TEMP%" "%RAR_DEST%" >nul
if errorlevel 1 (
  echo ERROR: Could not move the Windows RAR into the release directory.
  exit /b 1
)

echo.
echo Committing tracked changes...
git add -A
if errorlevel 1 (
  echo ERROR: Git could not stage the changes. The release artifacts are already packaged.
  exit /b 1
)

git diff --cached --quiet
if errorlevel 2 (
  echo ERROR: Git could not inspect the staged changes.
  exit /b 1
)
if errorlevel 1 (
  git commit -m "v%VERSION%"
  if errorlevel 1 (
    echo ERROR: Git commit failed. The release artifacts are already packaged.
    exit /b 1
  )
) else (
  echo No tracked changes to commit.
)

echo.
echo Syncing %BRANCH% to origin...
git push origin "%BRANCH%"
if errorlevel 1 (
  echo ERROR: Git push failed. The commit and release artifacts remain local.
  exit /b 1
)

echo.
echo Release v%VERSION% is ready and synced.
echo   %APK_DEST%
echo   %RAR_DEST%
exit /b 0
