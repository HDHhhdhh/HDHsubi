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
  $names = @('Invoke-MathSecrStateMachine', 'Get-FileHash', 'Read-MathSecrArtifactBytes', 'ConvertFrom-MathSecrContractJson', 'Invoke-MathSecrProductionStep')
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
    $recordHash = if ($name -cin @('Get-FileHash','Read-MathSecrArtifactBytes')) {
      @'
$inputPaths = if ($PSBoundParameters.ContainsKey('LiteralPath')) { @($PSBoundParameters['LiteralPath']) } else { @($PSBoundParameters['Path']) }
foreach ($inputPath in $inputPaths) {
  if ([string]::IsNullOrWhiteSpace([string]$inputPath)) { throw 'A measured hash call has no file path.' }
  $canonicalPath = [IO.Path]::GetFullPath([string]$inputPath)
  if (-not $script:phase1HashCallsByPath.ContainsKey($canonicalPath)) { $script:phase1HashCallsByPath[$canonicalPath] = 0 }
  $script:phase1HashCallsByPath[$canonicalPath]++
}
'@
    } else { '' }
    $body = '[CmdletBinding()] param({0}) process {{ $script:phase0Counters[''{1}'']++; {2}; {3} }}' -f $parameters, $name, $recordHash, $invoke
    Set-Item -Path ("Function:" + $name) -Value ([scriptblock]::Create($body))
  }
  $samples = [Collections.Generic.List[object]]::new()
  try {
    for ($index = 1; $index -le $Repeat; $index++) {
      foreach ($name in $names) { $script:phase0Counters[$name] = 0 }
      $script:phase1HashCallsByPath = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::OrdinalIgnoreCase)
      $timer = [Diagnostics.Stopwatch]::StartNew()
      $result = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $fixture.Session -ProjectRoot $fixture.Root
      $timer.Stop()
      if (-not $result.Valid -or $result.ReportProjection.SuccessCount -ne $ProblemCount) {
        throw 'Instrumented AfterReload did not validate the complete synthetic bundle.'
      }
      $counts = [ordered]@{}
      foreach ($name in $names) { $counts[$name] = $script:phase0Counters[$name] }
      $hashCalls = $counts['Get-FileHash'] + $counts['Read-MathSecrArtifactBytes']
      $byPath = [ordered]@{}
      $boundary = [IO.Path]::GetFullPath($root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
      foreach ($path in @($script:phase1HashCallsByPath.Keys | Sort-Object)) {
        if (-not $path.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)) { throw 'A measured hash left the synthetic fixture directory.' }
        $relative = [IO.Path]::GetRelativePath($root,$path).Replace('\','/')
        $byPath[$relative] = $script:phase1HashCallsByPath[$path]
      }
      $sum = ($byPath.Values | Measure-Object -Sum).Sum
      if ($hashCalls -ne $sum) { throw 'Hash function counts do not match path counts.' }
      $maxPerPath = if ($byPath.Count) { [int]($byPath.Values | Measure-Object -Maximum).Maximum } else { 0 }
      $samples.Add([pscustomobject]@{repeat=$index;elapsedMs=$timer.Elapsed.TotalMilliseconds;calls=$counts;status='PASS';
        hashCalls=$hashCalls;hashCallsByPath=$byPath;maxHashCallsPerPath=$maxPerPath})
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
  $medianHashes = $medianCounts['Get-FileHash'] + $medianCounts['Read-MathSecrArtifactBytes']
  $maxByPath = [ordered]@{}
  foreach ($sample in $samples) {
    foreach ($path in $sample.hashCallsByPath.Keys) {
      if (-not $maxByPath.Contains($path) -or $sample.hashCallsByPath[$path] -gt $maxByPath[$path]) {
        $maxByPath[$path] = $sample.hashCallsByPath[$path]
      }
    }
  }
  $maxHashesPerPath = if ($maxByPath.Count) { [int]($maxByPath.Values | Measure-Object -Maximum).Maximum } else { 0 }
  [ordered]@{
    schemaVersion=1;status='PASS';truthScope='offline-contract';liveProductBehavior=$false
    problemCount=$ProblemCount;historyDepth=$HistoryDepth;repeat=$Repeat
    timingScope='warmed module, function proxies, AfterReload only; fixture generation and cleanup excluded'
    proxyInstrumentationIncludedInElapsedTime=$true
    expectedPhase0StateMachineCalls=($HistoryDepth + 1) * ($HistoryDepth + 1)
    phase0FormulaMatches=($medianCounts['Invoke-MathSecrStateMachine'] -eq (($HistoryDepth + 1) * ($HistoryDepth + 1)))
    expectedPhase1StateMachineCalls=($HistoryDepth + 1)
    phase1FormulaMatches=(@($samples | Where-Object {$_.calls['Invoke-MathSecrStateMachine'] -ne ($HistoryDepth + 1)}).Count -eq 0)
    artifactCount=$fixture.Manifest.artifactCount
    hashCalls=$medianHashes
    hashCallsPerArtifact=[Math]::Round($medianHashes / [double]$fixture.Manifest.artifactCount,6)
    hashCallsByPath=$maxByPath
    maxHashCallsPerPath=$maxHashesPerPath
    hashCallsByPathScope='maximum per path across separate top-level validation calls; fixture-relative paths'
    median=[ordered]@{elapsedMs=$medianMs;calls=$medianCounts}
    samples=$samples.ToArray()
  } | ConvertTo-Json -Depth 12 -Compress
} finally {
  if (Test-Path -LiteralPath $root) { Remove-MathSecrOwnedBenchmarkRoot $root }
}
