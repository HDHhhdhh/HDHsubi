[CmdletBinding()]
param(
  [ValidateRange(1,1000)][int]$ProblemCount=47,
  [ValidateRange(1,100)][int]$Repeat=3,
  [string]$OutPath=(Join-Path $PSScriptRoot '../../docs/evidence/perf-phase2.json')
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'assembly_support.ps1')
$codeRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$out=[IO.Path]::GetFullPath($OutPath)
if (Test-Path -LiteralPath $out) {throw 'A measurement already exists. Use a new OutPath to preserve previous evidence.'}
$pwsh=(Get-Command pwsh).Source
function Get-SelectMedian {
  param($Values)
  $sorted=@($Values | Sort-Object)
  $middle=[int][Math]::Floor($sorted.Count/2)
  if ($sorted.Count%2) {return $sorted[$middle]}
  return ($sorted[$middle-1]+$sorted[$middle])/2
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-select-'+[guid]::NewGuid().ToString('N'))
$worker=$null
try {
  $fixture=New-MathSecrAppendHistoryFixture -ProblemCount $ProblemCount -HistoryDepth 0 -OutRoot $root
  $session=New-MathSecrAssemblySession $fixture
  $artifact=Write-MathSecrBenchmarkArtifact $session $root 'select-session.json'
  $keys=@($session.snapshot.targets.occurrenceKey)
  if ($keys.Count -ne $ProblemCount) {throw 'Selection benchmark did not generate the expected fixed roster.'}
  $samples=[Collections.Generic.List[object]]::new()
  foreach ($iteration in 1..$Repeat) {
    # Reverse execution order on alternate repeats to limit order bias.
    $modes=if ($iteration%2) {@('cli','resident')} else {@('resident','cli')}
    foreach ($mode in $modes) {
      Write-Host "Measuring Select mode=$mode N=$ProblemCount repeat=$iteration."
      $durations=[Collections.Generic.List[double]]::new()
      $passed=0
      $total=[Diagnostics.Stopwatch]::StartNew()
      try {
        if ($mode -ceq 'resident') {$worker=Start-MathSecrResidentValidation $codeRoot $root}
        foreach ($key in $keys) {
          $commandTimer=[Diagnostics.Stopwatch]::StartNew()
          if ($mode -ceq 'cli') {
            $text=@(& $pwsh -NoProfile -File (Join-Path $codeRoot 'mathsecr-paper-builder-kit/scripts/validate_production_step.ps1') -ProjectRoot $root -Step Select -InputPath $artifact.path -TargetOccurrenceKey $key 2>&1 | ForEach-Object {[string]$_})
            if ($LASTEXITCODE -ne 0) {throw "CLI Select failed: $($text -join ' ')"}
            $result=ConvertFrom-MathSecrContractJson ($text -join [Environment]::NewLine)
          } else {
            $result=Invoke-MathSecrResidentCommand $worker @{step='Select';inputPath=$artifact.path;targetOccurrenceKey=$key}
          }
          $commandTimer.Stop()
          if (-not $result.Valid -or $result.Step -cne 'Select') {throw "Select benchmark rejected $mode command."}
          $durations.Add($commandTimer.Elapsed.TotalMilliseconds);$passed++
        }
      } finally {
        if ($null -ne $worker) {Stop-MathSecrResidentValidation $worker;$worker=$null}
        $total.Stop()
      }
      if ($passed -ne $ProblemCount) {throw 'The mode did not validate every occurrence.'}
      $samples.Add([pscustomobject]@{
        repeat=$iteration;mode=$mode;totalMs=$total.Elapsed.TotalMilliseconds
        perCommandMedianMs=(Get-SelectMedian $durations.ToArray());commandElapsedMs=$durations.ToArray()
        passed=$passed;processStarts=$(if($mode -ceq 'cli'){$ProblemCount}else{1});status='PASS'
      })
    }
  }
  $summary=@(foreach ($mode in @('cli','resident')) {
    $modeSamples=@($samples | Where-Object mode -CEQ $mode)
    [pscustomobject]@{
      mode=$mode;totalMedianMs=(Get-SelectMedian @($modeSamples.totalMs))
      perCommandMedianMs=(Get-SelectMedian @($modeSamples | ForEach-Object {$_.commandElapsedMs}))
      passedPerRepeat=$ProblemCount;processStartsPerRepeat=$(if($mode -ceq 'cli'){$ProblemCount}else{1})
    }
  })
  $hashes=[ordered]@{}
  foreach ($relative in @('mathsecr-paper-builder-kit/scripts/validate_production_step.ps1',
      'mathsecr-paper-builder-kit/scripts/validate_production_session.ps1','mathsecr-paper-builder-kit/scripts/production_validation.ps1',
      'mathsecr-paper-builder-kit/scripts/state_machine.ps1','scripts/perf/assembly_support.ps1','scripts/perf/measure_select_modes.ps1')) {
    $hashes[$relative]=(Get-FileHash -LiteralPath (Join-Path $codeRoot $relative)).Hash.ToLowerInvariant()
  }
  $document=[ordered]@{
    schemaVersion=1;createdAtUtc=[DateTimeOffset]::UtcNow.ToString('o');truthScope='offline-contract';liveProductBehavior=$false
    problemCount=$ProblemCount;repeat=$Repeat;fixtureProvenance='new public synthetic H=0 selection session; every source occurrence validated once per mode'
    timingScope='total includes child process start, module load, all validation commands, serialization, response parse and shutdown; fixture preparation/cleanup excluded'
    commandTimingScope='CLI command includes process/module startup; resident first command includes module load; summary is median of all commands across repeats'
    environment=[ordered]@{os=[Environment]::OSVersion.VersionString;powerShell=$PSVersionTable.PSVersion.ToString();cpu=@(Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Name)}
    codeSha256=$hashes;samples=$samples.ToArray();summary=$summary
    residentFaster=($summary[1].totalMedianMs -lt $summary[0].totalMedianMs)
  }
  $json=(ConvertTo-Json -InputObject $document -Depth 12).Replace([Environment]::NewLine,[string][char]10)+[char]10
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $out) -Force
  [IO.File]::WriteAllText($out,$json,[Text.UTF8Encoding]::new($false))
  $summary | ConvertTo-Json -Depth 5
  Write-Host 'SelectModes PASS (every occurrence accepted; mode process counts recorded; previous evidence preserved).'
} finally {
  if ($null -ne $worker) {Stop-MathSecrResidentValidation $worker}
  Remove-MathSecrOwnedBenchmarkRoot $root
}
