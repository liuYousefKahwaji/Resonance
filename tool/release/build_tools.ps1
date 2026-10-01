$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Set-Location $root
if (-not (Test-Path 'build/release-tools-venv/Scripts/python.exe')) {
  python -m venv build/release-tools-venv
  if ($LASTEXITCODE -ne 0) { throw 'Cannot create release tooling environment' }
}
& build/release-tools-venv/Scripts/python.exe -m pip install -r tool/release/requirements.txt
if ($LASTEXITCODE -ne 0) { throw 'Cannot install release tooling dependencies' }
$revision='2c36417e6d09bf700d3d1cca44ed3e42101016c3'
$cmake=(Get-Command cmake -ErrorAction SilentlyContinue).Source
if (-not $cmake) { $cmake=Join-Path $env:ProgramFiles 'CMake/bin/cmake.exe' }
if (-not (Test-Path -LiteralPath $cmake)) { throw 'CMake is required for the release tools' }
if (-not (Test-Path 'build/update-tools/xdelta/.git')) {
  git clone --filter=blob:none https://github.com/jmacd/xdelta.git build/update-tools/xdelta
  if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch xdelta source' }
}
git -C build/update-tools/xdelta checkout --detach $revision
if ($LASTEXITCODE -ne 0) { throw 'Cannot select pinned xdelta revision' }
& $cmake -S build/update-tools/xdelta/xdelta3 -B build/update-tools/xdelta-host -DXD3_BUILD_TESTS=OFF -DXD3_ARMOR=OFF -DXD3_LZMA_MODE=off
if ($LASTEXITCODE -ne 0) { throw 'Cannot configure xdelta' }
& $cmake --build build/update-tools/xdelta-host --config Release
if ($LASTEXITCODE -ne 0) { throw 'Cannot build xdelta' }
& $cmake -S native/update_patch -B build/update-tools/decoder
if ($LASTEXITCODE -ne 0) { throw 'Cannot configure shipped decoder' }
& $cmake --build build/update-tools/decoder --config Release
if ($LASTEXITCODE -ne 0) { throw 'Cannot build shipped decoder' }
