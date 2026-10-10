[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'perf/append_history_support.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-runner-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$runner = Join-Path $PSScriptRoot 'run_offline_regression.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$utf8 = [Text.UTF8Encoding]::new($false)
function New-RunnerTestGate {
  param([string]$Id,[string]$Script,[string]$Grade='public',[string[]]$Required=@())
  return [ordered]@{id=$Id;script=$Script;grade=$Grade;requiredPaths=@($Required);parameters=@{};
    reason='Synthetic runner isolation test';passPattern='TEST PASS'}
}
function Invoke-RunnerTest {
  param([array]$Gates)
  $manifestPath = Join-Path $root ('manifest-' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject @{schemaVersion=1;gates=$Gates} -Depth 10),$utf8)
  $output = @(& $pwsh -NoProfile -File $runner -ProjectRoot $root -ManifestPath $manifestPath 2>&1)
  $code = $LASTEXITCODE
  if ($output.Count -ne ($Gates.Count + 1)) { throw "Runner did not emit one JSON line per gate plus summary: $output" }
  return [pscustomobject]@{Code=$code;Records=@($output | ForEach-Object {[string]$_ | ConvertFrom-Json})}
}
try {
  [IO.File]::WriteAllText((Join-Path $root 'good.ps1'),"Write-Output 'TEST PASS'",$utf8)
  [IO.File]::WriteAllText((Join-Path $root 'bad.ps1'),"Write-Output 'TEST FAIL'; exit 7",$utf8)
  [IO.File]::WriteAllText((Join-Path $root 'silent.ps1'),"Write-Output 'no success marker'",$utf8)
  [IO.File]::WriteAllText((Join-Path $root 'private.ps1'),"throw 'Private gate must never run'",$utf8)
  $mixed = Invoke-RunnerTest @(
    (New-RunnerTestGate 'failure' 'bad.ps1'),
    (New-RunnerTestGate 'private' 'private.ps1' 'private-bundle' @('withheld.json')),
    (New-RunnerTestGate 'later-success' 'good.ps1')
  )
  if ($mixed.Code -ne 1 -or ($mixed.Records.status -join ',') -cne 'FAIL,SKIP,PASS,FAIL') {
    throw 'A public failure, private skip, or continuing later gate was mishandled.'
  }
  $missing = Invoke-RunnerTest @((New-RunnerTestGate 'missing-public' 'good.ps1' 'public' @('missing.json')))
  if ($missing.Code -ne 1 -or $missing.Records[0].status -cne 'FAIL') { throw 'A missing public dependency was silently skipped.' }
  $silent = Invoke-RunnerTest @((New-RunnerTestGate 'silent' 'silent.ps1'))
  if ($silent.Code -ne 1 -or $silent.Records[0].status -cne 'FAIL') { throw 'Exit code zero without a PASS marker was accepted.' }
  $green = Invoke-RunnerTest @((New-RunnerTestGate 'green' 'good.ps1'))
  if ($green.Code -ne 0 -or ($green.Records.status -join ',') -cne 'PASS,PASS') { throw 'The success-only runner failed.' }
  foreach ($record in $mixed.Records | Where-Object kind -CEQ 'gate') {
    if ($record.elapsedMs -lt 0 -or $record.liveProductBehavior) { throw 'Invalid elapsed time or live behavior claim.' }
  }
  Write-Output 'OfflineRunner PASS (nonzero exit, missing public data, missing PASS marker, private SKIP, continued gates, JSON lines).'
} finally { Remove-MathSecrOwnedBenchmarkRoot $root }
