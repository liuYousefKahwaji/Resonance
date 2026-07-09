# Resonance v1.7.0

Resonance v1.7.0 focuses on playlist polish, metadata artwork, Android service behavior, and smoother library feedback.

## Highlights

- Added long-press playlist actions for renaming and deleting playlists while keeping the existing current-playlist menu actions.
- Limited playlist names to 25 characters.
- Added album-cover editing to the track metadata editor.
- Added a settings action to fill missing embedded cover art from the first YouTube search result for each local track in the current playlist.
- Made the Android notification stop button fully exit Resonance and end the background service.

## Interface improvements

- Added cover previews directly in the track list.
- Added a lightweight fade/slide transition when switching playlists.
- Added a subtle shuffle-state cue in the track list drag handle.
- Kept cover preview loading cached and lazy so scrolling stays smooth.

## Playback and platform fixes

- Improved Android background-service shutdown from notification controls.
- Preserved existing metadata fields when updating title, artist, or cover artwork.
- Kept existing tracks with embedded cover art untouched during automatic cover lookup.

## Packages

- `Resonance-Android-v1.7.0.apk` - Android arm64 release build.
- `Resonance-Windows-v1.7.0.rar` - Complete Windows x64 release package.
