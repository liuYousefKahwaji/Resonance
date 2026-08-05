(lyrics, search, downloads, and player improvements)

## Lyrics:
- added line-synced lyrics with animated word highlighting when word timing is available
- added local LRC/TTML support and multiple online lyric sources
- improved LRCLIB matching with duration checks, rate-limit handling, retries, and manual lyric selection

## Search and Suggestions:
- search results and suggestions now show view and like counts when available
- improved metadata matching and result loading across Windows and Android

## Downloads and Playback:
- restored reliable Windows download progress updates
- improved Windows download, stream, and search responsiveness
- improved retry handling for interrupted Windows streams

## Intro and UI:
- redesigned the Resonance intro while retaining the original intro sound
- added an option to disable the intro from Settings
- refined the standalone player layout, lyrics spacing, artwork presentation, and responsive behavior

## Reliability:
- improved lyric caching and manual lyric overrides
- added regression coverage for lyric parsing, selection, metadata, progress reporting, and responsive layouts
