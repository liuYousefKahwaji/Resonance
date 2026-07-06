# Resonance TODO Implementation Plan

## Goals
- Fix transient Windows waveform error during track switching.
- Remove Android search/URL layout overflow and suppress local-track play/seek flicker.
- Add configurable seek step buttons around the seek bar, with Windows hotkeys.
- Add Windows taskbar thumbnail controls for previous, play/pause, and next.
- Use embedded album art when available, with a graceful fallback.
- Replace the single `playlist.m3u8` model with switchable `r_playlist_X.m3u8` playlists and migrate legacy data once.
- Expose speed and pitch playback settings on Windows where supported by `media_kit`.
- Add a short optional startup intro, enabled by default.

## Execution Checklist
1. Inspect existing player, settings, playlist, storage, metadata, and Windows platform code.
2. Update playlist storage so `r_playlist_1.m3u8` is the default active playlist, with legacy `playlist.m3u8` migration only when no Resonance playlist exists.
3. Add playlist switching UI and provider state for multiple Resonance playlists.
4. Add seek step settings, seek buttons, and Windows hotkey entries for seek backward/forward.
5. Tighten Android layouts for search and URL actions.
6. Refine playback loading state so local Android play/seek does not show the loading treatment; streamed tracks still can.
7. Stabilize Windows track switching waveform/loading state to avoid transient red error UI.
8. Surface playback settings on Windows if the existing `media_kit` pitch/rate calls are available.
9. Add album art loading from metadata/cache into the now-playing card, preserving the animated icon fallback.
10. Add Windows taskbar thumbnail toolbar buttons through the existing native media keys bridge.
11. Add optional three-second max intro controlled by settings.
12. Run formatting and static checks; fix issues caused by the changes.
