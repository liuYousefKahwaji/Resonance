# A player-focused update
(solves #16, #17, and #18. As well as some other player improvements)

## Faster Track Switching: (#16)
- removed the loading state for local tracks
- selecting and switching tracks now starts immediately on both windows and android
- moved album art, saving, and visualizer work away from the playback path
- streamed tracks still show their actual loading and buffering state

## Standalone Player Rework: (#17)
- the standalone player and its controls are now one unified page
- added a spotify-like gradient that follows the selected light/dark mode and theme style
- resized and repositioned the cover, title, artist, and controls to make better use of the screen
- enlarged the standalone playback controls
- long titles and artists now animate instead of overflowing
- restored the smooth cover transition when opening and closing the standalone player

## Actual Audio Visualizer: (#18)
- replaced the old dots and lines with a smooth expanding pulse
- the pulse reacts to the actual audio instead of playing a decorative animation
- works consistently on both windows and android
- added the pulse to the currently playing card and the standalone cover

## Other stuff:
- double clicking/tapping a track opens the standalone player on both platforms
- double clicking/tapping keeps the current playback position instead of restarting the song
- single clicking/tapping the active track still restarts it
- moved the windows title and artist further to the left
