[CmdletBinding()]
param(
  [ValidateRange(1,1000)][int]$ProblemCount = 15,
  [ValidateRange(0,63)][int]$HistoryDepth = 6,
  [ValidateRange(1,100)][int]$Repeat = 3
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'append_history_support.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-bench-' + [guid]::NewGuid().ToString('N'))
try {
  # Generation and its uninstrumented AfterReload validation warm the module.
  # Only subsequent AfterReload calls enter the timed/instrumented region.
  $fixture = New-MathSecrAppendHistoryFixture -ProblemCount $ProblemCount -HistoryDepth $HistoryDepth -OutRoot $root
  $names = @('Invoke-MathSecrStateMachine', 'Get-FileHash', 'ConvertFrom-MathSecrContractJson', 'Invoke-MathSecrProductionStep')
  $script:phase0Counters = @{}
  $script:phase0OriginalFunctions = @{}
  $savedBodies = @{}
  foreach ($name in $names) {
    $command = Get-Command $name -ErrorAction Stop
    $metadata = [Management.Automation.CommandMetadata]::new($command)
    $parameters = [Management.Automation.ProxyCommand]::GetParamBlock($metadata)
    if ($command -is [Management.Automation.FunctionInfo]) {
      $savedBodies[$name] = $command.ScriptBlock
      $script:phase0OriginalFunctions[$name] = $command.ScriptBlock
      $invoke = '& $script:phase0OriginalFunctions[''{0}''] @PSBoundParameters' -f $name
    } else {
      # A module-qualified cmdlet bypasses this harness's Get-FileHash function.
      $invoke = '& Microsoft.PowerShell.Utility\Get-FileHash @PSBoundParameters'
    }
    $body = '[CmdletBinding()] param({0}) process {{ $script:phase0Counters[''{1}'']++; {2} }}' -f $parameters, $name, $invoke
    Set-Item -Path ("Function:" + $name) -Value ([scriptblock]::Create($body))
  }
  $samples = [Collections.Generic.List[object]]::new()
  try {
    for ($index = 1; $index -le $Repeat; $index++) {
      foreach ($name in $names) { $script:phase0Counters[$name] = 0 }
      $timer = [Diagnostics.Stopwatch]::StartNew()
      $result = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $fixture.Session -ProjectRoot $fixture.Root
      $timer.Stop()
      if (-not $result.Valid -or $result.ReportProjection.SuccessCount -ne $ProblemCount) {
        throw 'Instrumented AfterReload did not validate the complete synthetic bundle.'
      }
      $counts = [ordered]@{}
      foreach ($name in $names) { $counts[$name] = $script:phase0Counters[$name] }
      $samples.Add([pscustomobject]@{repeat=$index;elapsedMs=$timer.Elapsed.TotalMilliseconds;calls=$counts;status='PASS'})
    }
  } finally {
    # Restore before any cleanup or a caller's next measurement.
    foreach ($name in $names) {
      if ($savedBodies.ContainsKey($name)) { Set-Item -Path ("Function:" + $name) -Value $savedBodies[$name] }
      else { Remove-Item -Path ("Function:" + $name) }
    }
  }
  $ordered = @($samples.ToArray() | Sort-Object elapsedMs)
  $middle = [int][Math]::Floor($Repeat / 2)
  $medianMs = if ($Repeat % 2) {$ordered[$middle].elapsedMs} else {($ordered[$middle - 1].elapsedMs + $ordered[$middle].elapsedMs) / 2}
  $medianCounts = [ordered]@{}
  foreach ($name in $names) {
    $counts = @($samples.ToArray() | ForEach-Object {$_.calls[$name]} | Sort-Object)
    $medianCounts[$name] = if ($Repeat % 2) {$counts[$middle]} else {($counts[$middle - 1] + $counts[$middle]) / 2}
  }
  [ordered]@{
    schemaVersion=1;status='PASS';truthScope='offline-contract';liveProductBehavior=$false
    problemCount=$ProblemCount;historyDepth=$HistoryDepth;repeat=$Repeat
    timingScope='warmed module, function proxies, AfterReload only; fixture generation and cleanup excluded'
    proxyInstrumentationIncludedInElapsedTime=$true
    expectedPhase0StateMachineCalls=($HistoryDepth + 1) * ($HistoryDepth + 1)
    phase0FormulaMatches=($medianCounts['Invoke-MathSecrStateMachine'] -eq (($HistoryDepth + 1) * ($HistoryDepth + 1)))
    median=[ordered]@{elapsedMs=$medianMs;calls=$medianCounts}
    samples=$samples.ToArray()
  } | ConvertTo-Json -Depth 12 -Compress
} finally {
  if (Test-Path -LiteralPath $root) { Remove-MathSecrOwnedBenchmarkRoot $root }
}
