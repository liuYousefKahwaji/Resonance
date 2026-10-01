$ErrorActionPreference='Stop'
$target=[IO.Path]::GetFullPath((Get-Location).Path)
$marker=Join-Path $target '.resonance-update-pending.json'
if (-not (Test-Path -LiteralPath $marker)) { Write-Host 'No interrupted update found.'; exit 0 }
$pending=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
$stage=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($pending.transaction))
$production=Join-Path ([IO.Path]::GetTempPath()) 'resonance-update'
$testing=Join-Path $env:LOCALAPPDATA 'ResonanceUpdateTest\tmp\resonance-update'
if (-not $stage.StartsWith($production+'\',[StringComparison]::OrdinalIgnoreCase) -and
    -not $stage.StartsWith($testing+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid recovery staging location' }
$script=Join-Path $stage 'apply-update.ps1'
$transaction=Join-Path $stage 'transaction.json'
& $script -Zip (Join-Path $stage 'payload.zip') -Transaction $transaction -Target $target -ParentPid 0 -RecoverOnly
exit $LASTEXITCODE
