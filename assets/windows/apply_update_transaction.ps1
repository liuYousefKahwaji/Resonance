param(
  [Parameter(Mandatory=$true)][string]$Zip,
  [Parameter(Mandatory=$true)][string]$Target,
  [Parameter(Mandatory=$true)][int]$ParentPid,
  [Parameter(Mandatory=$true)][string]$Transaction,
  [switch]$ApplyOnly, [switch]$RecoverOnly, [switch]$PreflightOnly,
  [int]$FailAfterCopy=-1, [int]$HealthTimeout=60,
  [string]$ReadyFile=''
)
$ErrorActionPreference='Stop'
$targetRoot=[IO.Path]::GetFullPath($Target).TrimEnd('\')
$stagingRoot=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($Transaction))
$work=Join-Path $stagingRoot 'unpacked'
$backup=Join-Path $stagingRoot 'backup'
$log=Join-Path $stagingRoot 'update.log'
$journalPath=Join-Path $stagingRoot 'journal.json'
$marker=Join-Path $targetRoot '.resonance-update-pending.json'
$recoveryMarker=Join-Path $targetRoot '.resonance-update-pending'
$health=Join-Path $stagingRoot 'healthy.json'
$token=[guid]::NewGuid().ToString('N')
$plan=Get-Content -LiteralPath $Transaction -Raw | ConvertFrom-Json
if ($plan.schemaVersion -ne 1) { throw 'Unsupported transaction' }
if (($ApplyOnly -or $FailAfterCopy -ge 0 -or $HealthTimeout -ne 60) -and -not $plan.testMode) { throw 'Test controls require a test transaction' }
$journal=@{state='preparing';target=$targetRoot;source=$null;replaced=@();added=@();ownerPid=$PID}
$mutated=$false; $launched=$null

function Log([string]$message) { "$(Get-Date -Format o) $message" | Add-Content -LiteralPath $log }
function HashFile([string]$path) {
  $stream=[IO.File]::OpenRead($path); $digest=[Security.Cryptography.SHA256]::Create()
  try { return -join($digest.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
  finally { $stream.Dispose(); $digest.Dispose() }
}
function WriteJson([string]$path,$value) {
  $value | ConvertTo-Json -Depth 32 -Compress | Set-Content -LiteralPath "$path.part" -Encoding UTF8
  Move-Item -LiteralPath "$path.part" -Destination $path -Force
}
function PathIn([string]$root,[string]$relative) {
  if (-not $relative -or $relative.Contains('\') -or $relative.Contains(':') -or $relative.Contains([char]0) -or
      $relative.StartsWith('/') -or $relative -match '(^|/)(\.|\.\.)(/|$)') { throw 'Unsafe update path' }
  foreach ($part in $relative.Split('/')) {
    if (-not $part -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\..*)?$') { throw 'Invalid Windows path' }
  }
  $base=[IO.Path]::GetFullPath($root).TrimEnd('\')
  $resolved=[IO.Path]::GetFullPath((Join-Path $base $relative.Replace('/','\')))
  if (-not $resolved.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes its root' }
  $cursor=$resolved
  while ($cursor.Length -ge $base.Length) {
    if (Test-Path -LiteralPath $cursor) {
      if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse point in update path' }
    }
    if ($cursor -eq $base) { break }
    $cursor=[IO.Path]::GetDirectoryName($cursor)
  }
  return $resolved
}
function AssertFiles($manifest,[string]$root) {
  $seen=@{}; $lines=New-Object Text.StringBuilder; $previous=''
  if ($manifest.schemaVersion -ne 1) { throw 'Invalid file manifest' }
  foreach ($entry in $manifest.files) {
    $name=[string]$entry.path
    if ($seen.ContainsKey($name.ToLowerInvariant()) -or ($previous -and [string]::CompareOrdinal($previous,$name) -ge 0)) { throw 'Duplicate or unsorted path' }
    $seen[$name.ToLowerInvariant()]=$true; $previous=$name
    if ($entry.sha256 -notmatch '^[a-f0-9]{64}$' -or $entry.size -lt 0) { throw 'Invalid file identity' }
    $path=PathIn $root $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $entry.size -or
        (HashFile $path) -ne $entry.sha256) { throw "Managed file mismatch: $name" }
    [void]$lines.Append($name).Append([char]0).Append([string]$entry.size).Append([char]0).Append([string]$entry.sha256).Append([char]10)
  }
  $hasher=[Security.Cryptography.SHA256]::Create()
  try { $hash=-join($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($lines.ToString())) | ForEach-Object { $_.ToString('x2') }) }
  finally { $hasher.Dispose() }
  if ($hash -ne $manifest.treeSha256) { throw 'Managed tree digest mismatch' }
}
function Unpack([string]$archivePath) {
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath (PathIn $stagingRoot 'unpacked') -Recurse -Force }
  [void][IO.Directory]::CreateDirectory($work)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive=[IO.Compression.ZipFile]::OpenRead($archivePath)
  try {
    $seen=@{}; [long]$total=0
    foreach ($entry in $archive.Entries) {
      if ($entry.FullName.EndsWith('/')) { continue }
      $path=PathIn $work $entry.FullName
      if ($seen.ContainsKey($entry.FullName.ToLowerInvariant()) -or $entry.Length -gt 2GB -or
          (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960) { throw 'Unsafe ZIP entry' }
      $seen[$entry.FullName.ToLowerInvariant()]=$true; $total+=$entry.Length
      if ($total -gt 4GB) { throw 'Oversized archive' }
      [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path,$false)
    }
  } finally { $archive.Dispose() }
}
function Rollback {
  Log 'Restoring previous managed files.'
  if ($null -ne $launched -and -not $launched.HasExited) { $launched | Stop-Process -Force; $launched | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue }
  foreach ($name in $journal.added) {
    $path=PathIn $targetRoot $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
  }
  foreach ($name in $journal.replaced) {
    $saved=PathIn $backup $name; $dest=PathIn $targetRoot $name
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
    Copy-Item -LiteralPath $saved -Destination $dest -Force
    if ((HashFile $saved) -ne (HashFile $dest)) { throw 'Backup restore digest mismatch' }
  }
  if ($null -ne $journal.source) { AssertFiles $journal.source $targetRoot }
  $journal.state='rolled_back'; WriteJson $journalPath $journal
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
  if (Test-Path -LiteralPath $recoveryMarker) { Remove-Item -LiteralPath $recoveryMarker -Force }
}
function GetFull {
  $full=$plan.full; $uri=[Uri]$full.url
  if ($full.sha256 -notmatch '^[a-f0-9]{64}$' -or $full.size -le 0 -or $uri.UserInfo -or
      ((-not $plan.testMode) -and ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or -not $uri.AbsolutePath.StartsWith('/liuYousefKahwaji/Resonance/releases/download/'))) -or
      ($plan.testMode -and ($uri.Scheme -ne 'http' -or $uri.Host -notin @('127.0.0.1','localhost','10.0.2.2')))) { throw 'Untrusted fallback URL' }
  $fullPath=Join-Path $stagingRoot 'full-fallback.zip'
  Log 'Delta preflight failed; downloading signed full package.'
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $client=New-Object Net.WebClient
  try { $client.DownloadFile($uri,"$fullPath.part") } finally { $client.Dispose() }
  if ((Get-Item -LiteralPath "$fullPath.part").Length -ne $full.size -or
      (HashFile "$fullPath.part") -ne $full.sha256) { throw 'Fallback verification failed' }
  Move-Item -LiteralPath "$fullPath.part" -Destination $fullPath -Force
  return $fullPath
}
try {
  Log 'Updater started.'
  $parent=$null
  if ($ParentPid -gt 0 -and -not $PreflightOnly) { $parent=Get-Process -Id $ParentPid -ErrorAction SilentlyContinue }
  if ($ReadyFile -and -not $PreflightOnly) { [IO.File]::WriteAllText($ReadyFile, [string]$PID) }
  if ($null -ne $parent) { $parent | Wait-Process -Timeout 120 }
  if ($RecoverOnly) {
    $journal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    # TEMP on hosted Windows can contain an 8.3 alias (e.g. RUNNER~1).
    # GetFullPath expands it; normalize the journal path as well before comparing.
    $savedTarget=[string]$journal.target
    if (-not $savedTarget -or -not [IO.Path]::IsPathRooted($savedTarget) -or
        -not [string]::Equals([IO.Path]::GetFullPath($savedTarget).TrimEnd('\'), $targetRoot,
            [StringComparison]::OrdinalIgnoreCase)) { throw 'Recovery target mismatch' }
    if ($journal.ownerPid -gt 0 -and $journal.ownerPid -ne $PID) {
      $owner=Get-Process -Id $journal.ownerPid -ErrorAction SilentlyContinue
      if ($null -ne $owner) { $owner | Wait-Process -Timeout 120; $journal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json }
    }
    if ($journal.state -ne 'committed' -and $journal.state -ne 'rolled_back') { Rollback }
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
    if (Test-Path -LiteralPath $recoveryMarker) { Remove-Item -LiteralPath $recoveryMarker -Force }
    if (-not $ApplyOnly) { Start-Process -FilePath (Join-Path $targetRoot 'resonance.exe') -WorkingDirectory $targetRoot -WindowStyle Hidden }
    exit 0
  }
  if (Test-Path -LiteralPath $marker) { throw 'Previous transaction needs recovery first' }
  if (Test-Path -LiteralPath $backup) { throw 'Refusing to overwrite a transaction backup' }
  if ((HashFile $Zip) -ne $plan.payloadSha256) { throw 'Payload digest mismatch' }
  $sourceFile=Join-Path $targetRoot 'resonance-install.json'
  if (Test-Path -LiteralPath $sourceFile) {
    $journal.source=Get-Content -LiteralPath $sourceFile -Raw | ConvertFrom-Json
    try { AssertFiles $journal.source $targetRoot } catch { $journal.source=$null }
  }
  $mode=$plan.mode
  try {
    Unpack $Zip
    if ($mode -eq 'delta') {
      $delta=Get-Content -LiteralPath (Join-Path $work 'delta.json') -Raw | ConvertFrom-Json
      if ($delta.schemaVersion -ne 1 -or $delta.source.treeSha256 -ne $plan.sourceTreeSha256 -or $delta.target.treeSha256 -ne $plan.target.treeSha256) { throw 'Delta identity mismatch' }
      AssertFiles $delta.source $targetRoot
      $changed=@($delta.changed); $deleted=@($delta.deleted); $payload=Join-Path $work 'payload'
      foreach ($file in $changed) {
        if (@($plan.target.files | Where-Object { $_.path -ceq $file.path -and $_.sha256 -eq $file.sha256 -and $_.size -eq $file.size }).Count -ne 1) { throw 'Untrusted delta payload' }
        $path=PathIn $payload $file.path
        if ((Get-Item -LiteralPath $path).Length -ne $file.size -or (HashFile $path) -ne $file.sha256) { throw 'Delta payload mismatch' }
      }
      foreach ($name in $deleted) {
        if (@($delta.source.files | Where-Object { $_.path -ceq $name }).Count -ne 1 -or @($plan.target.files | Where-Object { $_.path -ceq $name }).Count -ne 0) { throw 'Invalid deletion' }
      }
      $journal.source=$delta.source
    } elseif ($mode -eq 'full') {
      AssertFiles $plan.target $work
      $changed=@($plan.target.files); $payload=$work; $deleted=@()
      if ($null -ne $journal.source) {
        $deleted=@($journal.source.files | Where-Object { $name=$_.path; @($plan.target.files | Where-Object { $_.path -ceq $name }).Count -eq 0 } | ForEach-Object { $_.path })
      }
    } else { throw 'Unknown mode' }
  } catch {
    if ($mode -ne 'delta') { throw }
    Log "Delta preflight failed: $($_.Exception.Message)"
    if ($PreflightOnly) { exit 10 }
    $mode='full'; $full=GetFull; Unpack $full; AssertFiles $plan.target $work
    $changed=@($plan.target.files); $deleted=@(); $payload=$work
    if ($null -ne $journal.source) {
      $deleted=@($journal.source.files | Where-Object { $name=$_.path; @($plan.target.files | Where-Object { $_.path -ceq $name }).Count -eq 0 } | ForEach-Object { $_.path })
    }
  }
  $drive=Get-PSDrive -Name ([IO.Path]::GetPathRoot($targetRoot).Substring(0,1)) -ErrorAction SilentlyContinue
  [long]$required=16MB
  foreach ($file in $changed) { $required+=$file.size; $dest=PathIn $targetRoot $file.path; if (Test-Path -LiteralPath $dest -PathType Leaf) { $required+=(Get-Item -LiteralPath $dest).Length } }
  if ($null -ne $drive.Free -and $drive.Free -lt $required) { throw 'Not enough space to replace and back up managed files' }
  if ($PreflightOnly) { Log 'Preflight verified while Resonance remains open.'; exit 0 }
  [void][IO.Directory]::CreateDirectory($backup)
  $paths=@($changed | ForEach-Object { $_.path })+@($deleted)+@('resonance-install.json')
  $seen=@{}
  foreach ($name in $paths) {
    if ($seen.ContainsKey($name.ToLowerInvariant())) { throw 'Duplicate affected path' }
    $seen[$name.ToLowerInvariant()]=$true
    $dest=PathIn $targetRoot $name
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
      $saved=PathIn $backup $name; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved))
      Copy-Item -LiteralPath $dest -Destination $saved -Force
      $journal.replaced+=$name
    } else { $journal.added+=$name }
  }
  $journal.state='applying'; WriteJson $journalPath $journal
  WriteJson $marker @{transaction=$Transaction;zip=$Zip;script=$PSCommandPath}
  [IO.File]::WriteAllText($recoveryMarker,$stagingRoot,(New-Object Text.UTF8Encoding($false)))
  $mutated=$true; $count=0
  foreach ($file in $changed) {
    $dest=PathIn $targetRoot $file.path; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
    Copy-Item -LiteralPath (PathIn $payload $file.path) -Destination $dest -Force
    $count++
    if ($FailAfterCopy -ge 0 -and $count -ge $FailAfterCopy) { throw 'Injected copy failure' }
  }
  foreach ($name in $deleted) { Remove-Item -LiteralPath (PathIn $targetRoot $name) -Force }
  WriteJson (Join-Path $targetRoot 'resonance-install.json') $plan.target
  AssertFiles $plan.target $targetRoot
  $journal.state='awaiting_health'; WriteJson $journalPath $journal
  if (-not $ApplyOnly) {
    $arguments=@(('"--resonance-update-health='+$health+'"'),('--resonance-update-token='+$token))
    $launched=Start-Process -FilePath (Join-Path $targetRoot 'resonance.exe') -WorkingDirectory $targetRoot -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Log "Launched updated Resonance, PID $($launched.Id); waiting for its first frame."
    $deadline=[DateTime]::UtcNow.AddSeconds($HealthTimeout); $healthy=$false
    while ([DateTime]::UtcNow -lt $deadline) {
      if (Test-Path -LiteralPath $health) {
        try { $ack=Get-Content -LiteralPath $health -Raw | ConvertFrom-Json; $healthy=$ack.token -eq $token -and $ack.pid -eq $launched.Id } catch { }
        if ($healthy) { break }
      }
      if ($launched.HasExited) { Log "Updated process exited early, code $($launched.ExitCode)."; break }
      Start-Sleep -Milliseconds 250
    }
    if (-not $healthy) { throw 'Startup health check failed' }
  }
  $journal.state='committed'; WriteJson $journalPath $journal
  Remove-Item -LiteralPath $marker -Force
  Remove-Item -LiteralPath $recoveryMarker -Force
  Log 'Update committed after verified startup.'
  Remove-Item -LiteralPath (PathIn $stagingRoot 'backup') -Recurse -Force
  Remove-Item -LiteralPath (PathIn $stagingRoot 'unpacked') -Recurse -Force
  if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
} catch {
  Log "Update failed: $($_.Exception.Message)"
  if ($mutated) { try { Rollback } catch { Log "Rollback failed; recovery journal retained: $($_.Exception.Message)"; exit 2 } }
  if (-not $ApplyOnly -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath (Join-Path $targetRoot 'resonance.exe'))) {
    Start-Process -FilePath (Join-Path $targetRoot 'resonance.exe') -WorkingDirectory $targetRoot -WindowStyle Hidden
  }
  exit 1
}

