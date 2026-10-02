param(
  [Parameter(Mandatory=$true)][string]$Executable,
  [Parameter(Mandatory=$true)][int]$ParentPid,
  [Parameter(Mandatory=$true)][string]$ReadyFile
)
$ErrorActionPreference='Stop'
$log=Join-Path $PSScriptRoot 'restart.log'
function Log([string]$message) { "$(Get-Date -Format o) $message" | Add-Content -LiteralPath $log }
try {
  $exe=[IO.Path]::GetFullPath($Executable)
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Executable is missing' }
  $parent=Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
  Log 'Helper ready; waiting for Resonance to exit.'
  [IO.File]::WriteAllText($ReadyFile, [string]$PID)
  if ($null -ne $parent) { $parent | Wait-Process -Timeout 120 }
  $launched=Start-Process -FilePath $exe -WorkingDirectory ([IO.Path]::GetDirectoryName($exe)) -WindowStyle Hidden -PassThru
  Log "Relaunched process $($launched.Id)."
  Start-Sleep -Seconds 3
  if ($launched.HasExited -and $launched.ExitCode -ne 0) { throw "Replacement exited with code $($launched.ExitCode)" }
} catch {
  Log "Restart failed: $($_.Exception.Message)"
  exit 1
}
