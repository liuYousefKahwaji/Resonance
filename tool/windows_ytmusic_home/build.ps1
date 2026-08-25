$ErrorActionPreference = 'Stop'

$toolDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = (Resolve-Path (Join-Path $toolDirectory '..\..')).Path
$assetDirectory = (Resolve-Path (Join-Path $repositoryRoot 'assets\bin')).Path
$expectedSuffix = 'Resonance\assets\bin'
if (-not $assetDirectory.EndsWith($expectedSuffix)) {
    throw "Unexpected helper output directory: $assetDirectory"
}

Push-Location $repositoryRoot
try {
    & py -3.13 -m PyInstaller `
        --noconfirm `
        --clean `
        --onefile `
        --collect-data ytmusicapi `
        --name resonance-ytmusic-home `
        --distpath $assetDirectory `
        --workpath 'build/resonance_ytmusic_home' `
        --specpath 'build' `
        'tool/windows_ytmusic_home/resonance_ytmusic_home.py'
    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller exited with code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
