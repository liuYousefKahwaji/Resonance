# Android playback widgets, vinyl player polish, and companion reliability

(solves #47, #48, and #49)

## Android playback widget: (#47)

- added compact, standard, and expanded home-screen playback widgets with theme-aware artwork and controls
- widget controls now dispatch playback, previous/next, loop, and shuffle actions
- widget snapshots refresh immediately on playback and theme changes with a three-second safety sync
- corrected widget loading on Android launchers and placed repeat before shuffle in the expanded layout

## Player presentation: (#48)

- moved playback settings into the updated player and settings flow
- clicking the standalone player album cover flips it into a larger spinning-vinyl easter egg
- preserved artwork colors, motion, and existing player controls

## Discord companion hotkeys: (#49)

- companion mute and deafen shortcuts now target Discord's real client window when Discord is in the background
- background delivery keeps the user's active app focused and reports failure when Discord cannot accept the shortcut
- shortcut recording, testing, saved custom bindings, and default restoration remain available

## Compatibility and reliability:

- existing companion pairings, playlists, widget state, and saved shortcuts continue to work
- Android release includes the corrected RemoteViews widget layouts
