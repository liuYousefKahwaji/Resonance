<div align="center">

<img src="assets/icon/icon.png" width="112" alt="Resonance app icon">

# Resonance

**A local-first music player for Windows and Android, with YouTube built in.**

[![Latest release](https://img.shields.io/github/v/release/liuYousefKahwaji/Resonance?display_name=release&style=flat-square&color=7C3AED)](https://github.com/liuYousefKahwaji/Resonance/releases/latest)
![Windows](https://img.shields.io/badge/Windows-x64-2563EB?style=flat-square&logo=windows11&logoColor=white)
![Android](https://img.shields.io/badge/Android-7.0%2B-1DB954?style=flat-square&logo=android&logoColor=white)

[Download](#download) · [Features](#features) · [YouTube access](#youtube-access) · [Build](#build-from-source)

</div>

Resonance keeps your music library on your device. Import local audio, build playlists, tune playback, and listen without an account. YouTube support adds search, streaming, downloads, personalized YouTube Music shelves, playlist imports, and listening history when you choose to connect it.

## Current release

Version **3.4.0** is the current packaged release. It brings Discover into the main player, speeds up YouTube search and streaming, loads more search results as you scroll, improves stream switching, and adds a collapsible Discover player and pull-to-refresh on Android.

The working tree may contain features intended for the next release. See the release page for the exact behavior of a published build.

## Features

### Local library

- Import MP3, WAV, M4A, OGG, Opus, WebM, AAC, and FLAC files.
- Create, rename, reorder, switch, and delete playlists stored as local M3U8 files.
- Search the active playlist by title or artist, with title matches ranked first.
- Drag files into the Windows app or use the cross-platform file picker.
- Edit title, artist, and embedded artwork without leaving the library.
- Remove an entry from one playlist or delete its file and references everywhere.
- Keep metadata and artwork cached for fast scrolling without moving source files.

### Playback

- Play, pause, seek, shuffle, repeat, and navigate the real upcoming queue.
- Use a full-screen player with lyrics, artwork-derived colors, an audio visualizer, gestures, and Pocket Vinyl.
- Adjust speed and pitch from 0.5× to 2×, volume up to 200%, and a five-band equalizer with presets.
- Apply playback settings globally or per track.
- Normalize local tracks toward -14 LUFS using cached, peak-safe analysis.
- Crossfade automatic track changes and resume long tracks from their saved position.
- Select a Windows audio output device; Android continues to use system audio routing.
- Control playback from Android notifications, widgets, Quick Settings, Windows media keys, taskbar controls, tray controls, hotkeys, and Discord Companion shortcuts.

### YouTube and YouTube Music

- Search YouTube by title, artist, album, or URL with quick previews and engagement counts.
- Play a result in a temporary queue, add it as a stream, or download it into a playlist.
- Convert an existing streamed playlist entry into a local download from its three-dot menu while preserving its position.
- Display streamed artwork immediately at thumbnail quality, then crossfade to a higher-resolution version when it is ready.
- Browse authenticated YouTube Music Home shelves such as Quick Picks, Suggestions, and Speed Dial.
- Open YouTube Music albums and playlists as session queues or import them for streaming or download.
- Recover stalled Windows streams by resolving a fresh media URL once.
- Optionally report genuine Resonance YouTube plays to YouTube Music after three seconds. This is off by default.
- Browse a two-tab listening History page: recent YouTube Music plays and up to 100 recent local Resonance plays. YouTube rows appear before view and like counts finish loading.

### Discovery and lyrics

- Generate Suggested Music from the active playlist and filter tracks already present.
- Identify nearby audio with the built-in Shazam-compatible recognizer.
- Fetch synchronized lyrics from Better Lyrics, AMLL, and LRCLIB, with local sidecar support and manual selection.
- Follow the active lyric line at 30 or 120 FPS, or scroll manually and resume following when ready.

### Import, transfer, and Sync

- Import public playlists from YouTube/YouTube Music and supported external music sites.
- Move playlists between Windows and Android using compressed, checksummed QR payloads.
- Review automatic source matches before transfer and reuse local downloads when possible.
- Use Resonance Sync on Android to host or join a local-network listening session.
- Pair the Android Companion with Windows for authenticated LAN playback control.

### Appearance

- Choose Obsidian, Quartz, Aurum, and other theme styles independently from light/dark mode.
- Use artwork-derived player colors, reduced motion, optional tracklist motion blur, and Windows native controls.
- Responsive layouts adapt the library, player, queue, YouTube shelves, and settings to desktop and mobile widths.

## Listening history

The History button lives in the main header beside Settings.

- **YouTube Music** reads recent plays from the connected account. Rows load first; views and likes display `—` until background lookups finish. Tracks can be played, streamed into the active playlist, or downloaded.
- **Resonance** records a local file after three seconds of genuine forward playback. Replaying it moves it to the top. Streams are excluded, the list is capped at 100 distinct tracks, and clearing history never deletes audio.

Local history begins when a build containing the feature is installed; earlier plays cannot be reconstructed.

## YouTube access

Most public operations work without an account. When YouTube requires verification, open **Settings → YouTube Access**.

### Windows

Connect a supported signed-in browser profile or select a Netscape `cookies.txt` file. Resonance reads the chosen source locally for each operation. Cookie values never enter Flutter preferences, UI, logs, or diagnostics.

### Android

Use the in-app Firefox guide to export the current YouTube site as `cookies.txt`, then import it with the system file picker. Resonance validates the file and stores a private copy under Android's no-backup storage. Each operation receives a unique temporary copy which is deleted afterward.

Treat exported cookies like a password. Export only the current YouTube site, delete the original file after import, and reconnect when the session expires.

## Download

Download packaged builds from [GitHub Releases](https://github.com/liuYousefKahwaji/Resonance/releases/latest).

- **Windows:** extract the complete ZIP and run `resonance.exe`. Keep `data/`, DLLs, and `bin/` beside the executable.
- **Android:** install the APK. Android may ask permission because the package is installed outside Google Play.

The app stores playlists and preferences in platform application data. Downloaded audio remains in the location selected by the platform downloader.

## Quick start

1. Import local tracks or drag files into the Windows library.
2. Create or rename playlists from the playlist menu.
3. Open Search to play, stream, or download YouTube results.
4. Connect YouTube Access only if verification or authenticated YouTube Music features require it.
5. Open the full player for lyrics, queue controls, playback tuning, and gestures.

## Build from source

### Requirements

- Flutter with Dart compatible with `pubspec.yaml` (currently Dart `^3.9.2`).
- Windows: Visual Studio with **Desktop development with C++** and the Windows SDK.
- Android: Android SDK, a compatible JDK, and the NDK/Gradle versions resolved by the project.
- The licensed runtime tools expected under `assets/bin/` for Windows packaging.

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter build windows --release
```

Android packages pinned Python/yt-dlp dependencies through Chaquopy and includes its required QuickJS runtime. Windows release builds copy yt-dlp, FFmpeg, Deno, and the packaged YouTube Music helper into `bin/`. Do not distribute only `resonance.exe`.

## Project structure

```text
lib/main.dart                         App composition and library UI
lib/core/audio/                       Playback, queues, effects, and recovery
lib/core/storage/                     Playlist persistence and mutations
lib/screens/                          Full-page player, history, settings, import, and Sync UI
lib/services/                         YouTube, history, metadata, transfer, lyrics, and LAN services
lib/widgets/                          Library, player, YouTube, and common UI components
android/app/src/main/kotlin/          Android channels, widgets, services, and cookie boundary
android/app/src/main/python/          Android yt-dlp/YouTube Music bridge
windows/runner/                       Windows runner and native media integrations
tool/windows_ytmusic_home/            Source and build script for the packaged Windows helper
test/                                 Flutter and host-side regression tests
```

Architecture and session notes live under `docs/` in development checkouts.

## Recent releases

| Release | Highlights |
| --- | --- |
| v3.4.0 | Main-window Discover and listening focus, faster YouTube search and streaming, up to 120 search results loaded as you scroll, more reliable stream switching, Android Discover controls and refresh, and right-to-left lyrics. |
| v3.3.0 | YouTube Music and local Resonance listening history, background view/like hydration, progressive high-resolution stream artwork, and refreshed documentation. |
| [v3.2.0](https://github.com/liuYousefKahwaji/Resonance/releases/tag/v3.2.0) | Playlist search, stream-to-download conversion, Windows output routing, opt-in YouTube Music history reporting, media-key reliability, and authenticated playback improvements. |
| [v3.1.0](https://github.com/liuYousefKahwaji/Resonance/releases/tag/v3.1.0) | Personalized YouTube Music Home, persistent authenticated sessions, complete session queues, and stream recovery. |
| [v3.0.0](https://github.com/liuYousefKahwaji/Resonance/releases/tag/v3.0.0) | Cross-platform YouTube Access with Windows browser sessions, Android private cookie import, validation, and sanitized diagnostics. |
| [v2.9.2](https://github.com/liuYousefKahwaji/Resonance/releases/tag/v2.9.2) | Android extraction and packaging reliability fixes. |
| [v2.9.1](https://github.com/liuYousefKahwaji/Resonance/releases/tag/v2.9.1) | Playlist transfer and playback fixes. |

Older releases remain available in the [GitHub release archive](https://github.com/liuYousefKahwaji/Resonance/releases).

---

Resonance is built for personal music libraries. Respect artists, copyright, and the terms of the services you use.
