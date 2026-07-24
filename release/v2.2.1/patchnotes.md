# YouTube playlist imports and metadata fixes

## Cross-Website Playlist Import
- restored public YouTube and YouTube Music playlist support on Windows and Android
- playlist links pasted into YouTube Search now open the playlist importer instead of loading indefinitely
- YouTube imports preserve the exact videos, original order, and duplicate entries without searching for replacements
- YouTube, Spotify, and Audiomack playlists can all be downloaded locally or added as streams through the renamed cross-website importer
- added bounded playlist-metadata timeouts and clearer provider errors

## Playlist Metadata Isolation
- fixed newly imported playlists temporarily inheriting title and artist metadata from the previous playlist by row position
- track rows are now scoped to their owning playlist, and late metadata reads are ignored after a row changes tracks
- invalidates affected local-file metadata cache entries and rebuilds them from the correct embedded tags
- retains existing stream metadata while migrating the cache

## Reliability
- added Windows and Android playlist metadata extraction specifically for public YouTube playlists
- added regression coverage for exact playlist order, duplicates, cross-playlist metadata isolation, cache migration, and the import screen
