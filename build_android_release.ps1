$ErrorActionPreference = 'Stop'

# Keep native FFmpeg, Flutter and Chaquopy libraries out of one oversized
# universal APK. Chaquopy requires abiFilters and therefore cannot use
# Flutter's --split-per-abi mode, so target arm64 directly instead.
flutter build apk --release --target-platform android-arm64

$apk = Join-Path $PSScriptRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path -LiteralPath $apk)) {
    throw "Expected release APK was not produced: $apk"
}

$sizeMb = [math]::Round((Get-Item -LiteralPath $apk).Length / 1MB, 1)
Write-Host "Android release ready: $apk ($sizeMb MB)"
