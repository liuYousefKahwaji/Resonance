# Recognition, queues, and smarter playback
(solves #25, #26, #27, #28, #29, #30, #31, #32, #33, #34, #35, #36, #37, #38, #39, and #40)

## Android recognition and sharing: (#25, #26, #27, #28)
- clarified that **Listen with microphone** can hear music playing through the phone's own speakers and made it the recommended default
- explained when direct device-audio capture is useful and why Android shows its recording/casting permission prompt
- kept the source chooser compact on phone screens and made scan ownership release immediately after success, failure, or cancellation so another scan can start without restarting Resonance
- added immediate high-priority completion notifications for successful matches, no match, no audio, cancellation, and capture/network failures
- tapping a result notification returns directly to the completed match, while pending results survive activity recreation and notification dismissal is handled cleanly
- added an Android Quick Settings music-recognition tile with live listening/matching states, duplicate-scan prevention, a configurable source default, and a long-press source picker
- tile-triggered microphone capture now runs in a foreground listening service before Resonance returns invisibly to the background
- added Resonance to Android's share sheet for YouTube, YouTube Music, Spotify, Audiomack, playlist links, and ordinary search text, including when the app is already backgrounded

## Playback queue and transitions: (#29, #30)
- added a read-only visual queue which follows the real playlist or already-generated shuffle order
- swipe up in the Android standalone player to open the compact queue sheet, alongside its existing track and exit gestures
- Windows now has a persistent right-side queue drawer, and selecting an upcoming entry starts it immediately
- added optional 0–8 second crossfade using overlapping audio players instead of a simple volume dip
- crossfade applies only to automatic track changes, respects loop-off at the end of a playlist, and falls back to normal playback if preparation fails
- Android loop-all now completes crossfaded transitions correctly, while manual seeks remain unrestricted and safely cancel only an in-progress transition

## Playback memory and sound: (#31, #32, #33)
- optionally remembers positions for tracks at least 10 minutes long, saves every 15 seconds and at lifecycle changes, resumes later, and clears completed progress
- added **Global** and **Per track** playback-settings scope for speed, pitch, and bass
- added a real bass control to the existing Playback Settings panel
- Android uses its native bass-boost effect with a device equalizer fallback; Windows uses a native libmpv bass filter with peak limiting and preserved pitch correction; unsupported devices fall back safely

## Downloads and player personalization: (#34, #35, #36)
- added searchable download history with success/failure state, source, local path, date, playback, Windows folder reveal, entry removal, and clear-all
- added optional artwork-based colors for Currently Playing, the standalone player, and visualizer glow while keeping the selected Resonance theme as the base
- artwork palettes are contrast-limited, cached, animated, and preserve Void's OLED-black surfaces
- fixed Android and Windows search downloads failing on Unicode titles and artists such as `øneheart`, `São Paulo`, non-Latin scripts, smart punctuation, and emoji
- Android download events now use explicit UTF-8 JSON payloads, while Windows forces UTF-8 yt-dlp output and safely handles legacy code-page bytes; both platforms sanitize only characters which are actually invalid for the target filesystem

## Windows reliability: (#37)
- the window now hides synchronously as soon as **X** is pressed
- added timestamped shutdown tracing around the native close event, Dart close callback, cleanup, window destruction, and final exit
- essential state saving and cleanup use strict timeouts, backed by an independent native watchdog which forces exit inside one second
- close-to-tray remains resident while exit tray modes close deterministically

## PC Companion: (#38)
- added a local Windows companion server with one-time QR pairing, remembered approved Android devices, automatic reconnect, and bidirectional state updates
- Android can browse the PC queue, jump to a queued track, and control play/pause, previous/next, loop, shuffle, speed, pitch, and bass without transferring audio or music files
- added a 0–200% volume slider and dedicated seek-back/seek-forward buttons to the Android remote
- companion seek buttons always use the seek interval configured on Windows, even when Android has a different local setting

## Android playback and scrolling reliability: (#39, #40)
- fixed playback notification controls becoming unresponsive, followed by a crash on reopen, after Resonance was swiped away from Android's recent-apps screen
- reduced track-list prebuilding and background metadata work on Android to avoid bursts of I/O while scrolling
- added an optional motion-blur scroll effect, disabled by default for lower-end devices
- fixed the track list jumping back to the top when a blurred scroll ended
