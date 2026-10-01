param([ValidateSet('arm64-v8a','x86_64')][string]$AndroidAbi='arm64-v8a', [switch]$SkipTools, [switch]$RebuildWindows, [switch]$RebuildAndroid, [string]$LabDirectory='build/update-lab')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Set-Location $root
if (-not $SkipTools) { & "$PSScriptRoot/build_tools.ps1" }
$python=Join-Path $root 'build/release-tools-venv/Scripts/python.exe'
$lab=[IO.Path]::GetFullPath((Join-Path $root $LabDirectory))
if (-not $lab.StartsWith((Join-Path $root 'build')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Lab output must remain under the repository build directory' }
[void][IO.Directory]::CreateDirectory($lab)
$seed=Join-Path $lab 'test-manifest.seed'; $trust=Join-Path $lab 'trusted_keys.json'
if (-not (Test-Path -LiteralPath $seed)) {
  & $python tool/release/release.py keygen --private $seed --public $trust --key-id resonance-test
  if ($LASTEXITCODE -ne 0) { throw 'Cannot create test identity' }
}
$public=(Get-Content -LiteralPath $trust -Raw | ConvertFrom-Json).keys.'resonance-test'
$originalPubspec=[IO.File]::ReadAllBytes((Join-Path $root 'pubspec.yaml'))
$previousAbi=$env:RESONANCE_TEST_ABI
$env:RESONANCE_TEST_ABI=$AndroidAbi
try {
  foreach ($build in @(@{version='3.4.5';code=12;folder='base'},@{version='3.4.6';code=13;folder='target'})) {
    $out=Join-Path $lab $build.folder
    if ((Test-Path -LiteralPath $out) -and -not ($RebuildWindows -or $RebuildAndroid)) { throw "Lab build folder exists: $out. Move it aside or use the existing fixtures." }
    [void][IO.Directory]::CreateDirectory($out)
    $defines=@('--dart-define=RESONANCE_UPDATE_TEST=true',"--dart-define=RESONANCE_UPDATE_TEST_KEY=$public")
    if (-not $RebuildAndroid -or $RebuildWindows) {
      flutter build windows --release "--build-name=$($build.version)" "--build-number=$($build.code)" @defines
      if ($LASTEXITCODE -ne 0) { throw 'Windows lab build failed' }
      $nativeVersion=(Get-Item build/windows/x64/runner/Release/resonance.exe).VersionInfo.ProductVersion
      if ($nativeVersion -ne "$($build.version)+$($build.code)") { throw 'Windows lab executable version differs from requested build' }
      & $python tool/release/release.py windows --root build/windows/x64/runner/Release --output $out --version "$($build.version)+$($build.code)"
      if ($LASTEXITCODE -ne 0) { throw 'Windows lab packaging failed' }
    }
    if ($RebuildWindows -and -not $RebuildAndroid) { continue }
    $platform=if ($AndroidAbi -eq 'x86_64') { 'android-x64' } else { 'android-arm64' }
    flutter build apk --release "--target-platform=$platform" "--build-name=$($build.version)" "--build-number=$($build.code)" @defines
    if ($LASTEXITCODE -ne 0) { throw 'Android lab build failed' }
    # Read AGP's canonical variant output, not a stale Flutter-copy directory.
    $metadata=Get-Content build/app/outputs/apk/release/output-metadata.json -Raw | ConvertFrom-Json
    if ($metadata.applicationId -ne 'com.example.resonance.updatertest' -or $metadata.elements[0].versionName -ne $build.version -or $metadata.elements[0].versionCode -ne $build.code) { throw 'Lab APK identity/version differs from requested build' }
    Copy-Item -LiteralPath build/app/outputs/apk/release/app-release.apk -Destination (Join-Path $out "resonance-v$($build.version).apk")
  }
  $base=@(@{version='3.4.5';apk=(Join-Path $lab 'base/resonance-v3.4.5.apk');windows=(Join-Path $lab 'base/resonance-v3.4.5-windows.zip')})
  $bases=Join-Path $lab 'bases.json'
  $testNotes=Join-Path $lab 'patchnotes.md'
  [IO.File]::WriteAllText($testNotes,"# Resonance 3.4.6 - Update Test`n`nA local test update. Your normal Resonance installation and GitHub releases are unchanged.`n",(New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($bases,(ConvertTo-Json -InputObject $base -Depth 5),(New-Object Text.UTF8Encoding($false)))
  & $python tool/release/release.py prepare --windows (Join-Path $lab 'target/resonance-v3.4.6-windows.zip') --apk (Join-Path $lab 'target/resonance-v3.4.6.apk') --output (Join-Path $lab 'feed') --xdelta build/update-tools/xdelta-host/Release/xdelta3.exe --decoder build/update-tools/decoder/Release/resonance-patch.exe --notes $testNotes --bases $bases --seed $seed --trust $trust --version 3.4.6+13 --package com.example.resonance.updatertest --key-id resonance-test
  if ($LASTEXITCODE -ne 0) { throw 'Lab manifest/patch verification failed' }
  $originalFeed=Join-Path $lab 'feed/.original-manifest'
  if (Test-Path -LiteralPath $originalFeed) { Remove-Item -LiteralPath $originalFeed -Force }
  Write-Host "Lab fixtures ready at $lab. See tool/release/README.md for Windows and Android steps."
} finally {
  $env:RESONANCE_TEST_ABI=$previousAbi
  $current=[IO.File]::ReadAllBytes((Join-Path $root 'pubspec.yaml'))
  if ([Convert]::ToBase64String($current) -ne [Convert]::ToBase64String($originalPubspec)) { throw 'pubspec changed unexpectedly; inspect it before continuing' }
}
