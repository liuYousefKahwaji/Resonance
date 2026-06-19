# Run this from the root of your Flutter project

$files = @(
"lib/main.dart",

"lib/app/app.dart",
"lib/app/routes.dart",
"lib/app/theme.dart",
"lib/app/constants.dart",

"lib/core/database/database_service.dart",
"lib/core/database/migrations.dart",

"lib/core/audio/audio_service.dart",
"lib/core/audio/queue_manager.dart",

"lib/core/youtube/ytdlp_service.dart",
"lib/core/youtube/youtube_models.dart",
"lib/core/youtube/download_manager.dart",

"lib/core/storage/file_service.dart",
"lib/core/storage/settings_storage.dart",

"lib/core/metadata/metadata_service.dart",
"lib/core/metadata/album_art_service.dart",

"lib/core/utils/extensions.dart",
"lib/core/utils/helpers.dart",
"lib/core/utils/logger.dart",

"lib/models/song.dart",
"lib/models/playlist.dart",
"lib/models/settings.dart",
"lib/models/queue_item.dart",
"lib/models/youtube_track.dart",

"lib/providers/player_provider.dart",
"lib/providers/library_provider.dart",
"lib/providers/playlist_provider.dart",
"lib/providers/settings_provider.dart",
"lib/providers/youtube_provider.dart",

"lib/screens/home/home_screen.dart",

"lib/screens/library/library_screen.dart",

"lib/screens/playlists/playlist_screen.dart",
"lib/screens/playlists/playlist_details_screen.dart",

"lib/screens/player/player_screen.dart",

"lib/screens/youtube/youtube_screen.dart",

"lib/screens/settings/settings_screen.dart",

"lib/widgets/common/resonance_button.dart",
"lib/widgets/common/resonance_card.dart",
"lib/widgets/common/loading_indicator.dart",
"lib/widgets/common/search_bar.dart",

"lib/widgets/player/player_controls.dart",
"lib/widgets/player/seek_bar.dart",
"lib/widgets/player/album_cover.dart",

"lib/widgets/library/song_tile.dart",

"lib/widgets/playlist/playlist_card.dart",

"lib/widgets/youtube/youtube_result_tile.dart",

"lib/platform/desktop/hotkeys.dart",
"lib/platform/desktop/tray_manager.dart",
"lib/platform/desktop/desktop_shortcuts.dart",

"lib/platform/mobile/notifications.dart",
"lib/platform/mobile/background_audio.dart",
"lib/platform/mobile/media_session.dart"
)

foreach ($file in $files) {
    $directory = Split-Path $file -Parent

    if (!(Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (!(Test-Path $file)) {
        New-Item -ItemType File -Path $file -Force | Out-Null
    }
}

Write-Host "Resonance lib structure created successfully."