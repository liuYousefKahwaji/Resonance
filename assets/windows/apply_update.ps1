param(
  [Parameter(Mandatory = $true)][string]$Zip,
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][int]$ParentPid
)

$ErrorActionPreference = 'Stop'
$stagingRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($Zip))
$work = Join-Path $stagingRoot 'unpacked'
$backup = Join-Path $stagingRoot 'backup'
$log = Join-Path $stagingRoot 'update.log'

try {
  $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
  if ($null -ne $parent) { $parent | Wait-Process -Timeout 120 }
  Start-Sleep -Milliseconds 600
  foreach ($directory in @($work, $backup)) {
    $resolved = [System.IO.Path]::GetFullPath($directory)
    if (-not $resolved.StartsWith($stagingRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
      throw 'Updater staging path is invalid.'
    }
  }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
  [System.IO.Directory]::CreateDirectory($work) | Out-Null
  [System.IO.Directory]::CreateDirectory($backup) | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $work)
  foreach ($required in @('resonance.exe', 'flutter_windows.dll', 'data\app.so')) {
    if (-not (Test-Path -LiteralPath (Join-Path $work $required))) {
      throw "Update archive is missing $required"
    }
  }
  $files = @(Get-ChildItem -LiteralPath $work -Recurse -File)
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($work.Length).TrimStart('\')
    $existing = Join-Path $Target $relative
    if (Test-Path -LiteralPath $existing) {
      $saved = Join-Path $backup $relative
      [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($saved)) | Out-Null
      Copy-Item -LiteralPath $existing -Destination $saved -Force
    }
  }
  try {
    foreach ($file in $files) {
      $relative = $file.FullName.Substring($work.Length).TrimStart('\')
      $destination = Join-Path $Target $relative
      [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination)) | Out-Null
      Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
  } catch {
    foreach ($saved in Get-ChildItem -LiteralPath $backup -Recurse -File) {
      $relative = $saved.FullName.Substring($backup.Length).TrimStart('\')
      Copy-Item -LiteralPath $saved.FullName -Destination (Join-Path $Target $relative) -Force
    }
    throw
  }
  Start-Process -FilePath (Join-Path $Target 'resonance.exe') -WorkingDirectory $Target -WindowStyle Normal
  'Update installed successfully.' | Set-Content -LiteralPath $log
} catch {
  $_.ToString() | Set-Content -LiteralPath $log
}
