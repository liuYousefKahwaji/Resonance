# Resonance v3.0.0

This update makes YouTube playback more reliable and gives you a simpler way to connect Resonance to your signed-in YouTube account when YouTube asks you to verify that you are not a bot.

## YouTube Access

- Added a new **YouTube Access** section in Settings.
- On Windows, connect the browser where you are already signed in with one button.
- On Android, follow the built-in Firefox guide to export your YouTube session and import it into Resonance.
- The Android guide explains how to prevent links from opening in the YouTube app, install the cookies.txt add-on, sign in privately, and export only the YouTube site.
- Imported sessions are kept privately inside Resonance and can be replaced or cleared at any time.
- YouTube can still be used without connecting an account when verification is not required.

## YouTube playback and downloads

- Improved YouTube search, streaming, and downloading on Windows and Android.
- Added a reliable Android fallback for videos that YouTube serves differently on mobile devices.
- Fixed cases where a video could be found but would not play or download.
- Improved support for playlists, queued downloads, artwork, and playlist transfers when YouTube requests verification.

## Better recovery when something goes wrong

- Replaced the vague “try again” message with clearer guidance for sign-in, expired sessions, unavailable videos, rate limits, and other YouTube problems.
- Added an optional **Details** view for troubleshooting without displaying private cookie information.
- Added easier **Fix access**, **Retry**, **Replace**, and **Clear** actions.
- Existing guest access continues to work when an account session is not configured.

## Privacy and safety

- Browser sessions and exported cookies remain private to the platform that uses them.
- Resonance does not display or save cookie values in the app interface.
- Android stores imported sessions in private app storage and reminds you to delete the original export after importing it.

## General reliability

- Improved playback recovery, download queue handling, metadata updates, and source matching across Windows and Android.
- Existing playlists, downloads, settings, Companion connections, and widget state remain compatible.
