# Resonance v1.8.0

Resonance v1.8.0 adds fully local playlist transfer between Windows and Android, while improving playlist navigation, export matching, and narrow-screen controls.

## Highlights

- Added local playlist transfer through one or more QR codes without accounts, servers, cloud storage, or background synchronization.
- Added persistent YouTube source tracking for downloaded, matched, manually selected, and imported tracks.
- Preserved playlist ordering and repeated entries during QR export and import.
- Added automatic YouTube top-result selection during export with a final review and replacement step.
- Improved Currently Playing navigation so the highlighted track is brought into view reliably.
- Added responsive playlist controls for narrow windows and Android screens.

## Playlist transfer

- Windows can save one or more QR codes as PNG files and import QR images in any order.
- Android can scan Resonance QR codes continuously with the camera or save generated QR images to Pictures/Resonance.
- QR payloads are versioned, compressed, checksummed, size-limited, and validated completely offline.
- Duplicate QR chunks are ignored, missing chunks are reported, and mixed or corrupted transfers are rejected.
- Existing local tracks are reused by YouTube source ID instead of being downloaded again.
- Missing tracks are downloaded only after the user confirms the import.
- Failed downloads can be retried or skipped without cancelling the remaining import.
- Imported playlists keep Resonance’s existing r_playlist_X.m3u8 naming system and separate display-name storage.

## Playlist and interface improvements

- Fixed Currently Playing scroll positioning for tracks deeper in a playlist.
- Normalized local-path matching for current-track lookup across Windows path casing and separators.
- Kept playlist names visible with ellipsis when space is limited.
- Moved refresh, transfer, scan, local import, and YouTube download actions into a labeled overflow menu on narrow layouts.
- Kept direct toolbar actions available on wider layouts.

## Downloads and source matching

- Saved canonical YouTube URLs and video IDs alongside local track mappings.
- Automatic export matching continues through individual search failures and lets the user replace or skip proposed matches.
- Source mappings are committed after the user finishes reviewing export matches and are reused on later transfers.
- Windows and Android QR imports use the existing platform download implementations and configured download destinations.

## Packages

- `Resonance-Android-v1.8.0.apk` — Android arm64 release build.
- `Resonance-Windows-v1.8.0.rar` — Complete Windows x64 release package.
