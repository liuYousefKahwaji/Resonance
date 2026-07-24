# Shazam and better player controls
(solves #19, #20, #21, #22, and #23. As well as some other player fixes)

## Touch Scrolling: (#19)
- touch scrolling on android no longer accidentally plays every track touched while scrolling
- tracks only activate after a completed tap
- tapping the active track still restarts it immediately

## Standalone Player Swipes: (#20)
- swiping from right to left goes to the next track
- swiping from left to right goes to the previous track without applying the 3 second restart rule
- swiping down returns to the playlist
- works with touch on android and mouse drags on windows

## About: (#21)
- added an about section to settings
- the displayed version is read directly from the packaged app instead of being hardcoded

## Currently Playing Rework: (#22)
- removed the double click/tap delay when selecting tracks
- tapping the currently playing card reveals the track in its playlist
- tapping the cover/playing visualizer opens the standalone player without pausing or restarting the song
- audio played directly from search returns to the standalone player instead of looking for a playlist
- standalone navigation remembers the correct playlist even after switching playlists

## Shazam / Identify Song: (#23)
- added an identify song button on windows and android
- choose between listening through the microphone or directly to device audio
- android device audio minimizes resonance, shows a listening notification, and waits up to 20 seconds for audio
- after identifying a song, resonance automatically searches for it on youtube
- the matched youtube results can be played, streamed into a playlist, or downloaded
- android device audio requires android 10 or newer and some apps may block their audio from being captured

## Other stuff:
- fixed slow loading tracks incorrectly returning to the standalone player after leaving it
- fixed restored search playback returning to the wrong screen
- improved playlist-aware next and previous navigation inside the standalone player
