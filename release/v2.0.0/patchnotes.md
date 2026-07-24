# Another major-ish update
(solves #10, #11, #12, #13, #14, #15. As well as some other stuff)

## Spotify and Audiomack playlist importing: (#10)
- a new button to import spotify or audiomack playlist
- for both platforms, the playlist MUST be **PUBLIC**. NOT PRIVATE. **PUBLIC!!**
- entering a valid link and confirming allows resonance to scan the playlist, retrieving only information about the tracks such as title and author
- after scan is complete, it uses the youtube search fetching system to fetch the top result matching the metadata.
- like the qr transfer system, it creates a new playlist with the fetched tracks

## Track Actions Menu:
- 3 dots on the track.
- has the metadata (still allowed through hold)
- has the standalone player (can be done through double click as well)
- added a perma delete button that deletes the file itself as well as any references to it inside resonance

## Improved Theme Styles: (#13)
- added a toggle that changes from full to default theme styles
- default are the old theme styles
- full are the new and improved theme styles, where the themes change more than just the theme accent

## Performance Improvements: (#14, #15)
- lowered overall cpu, gpu, and ram usage
- while the app is in the background (tray) it decreases usage even more
- added more smoothness to some menus
- added a small blur in the scrolling playlists

## Other stuff:
- #11: allows all instances of "fetching" to either stream the fetched playlist or download. (qr transfer and spotify/audiomack import)
- #12: added the ability to use the standalone player on playlist tracks. 
- erasing the top most playlist now "promotes" the next one in line instead of creating a new one
