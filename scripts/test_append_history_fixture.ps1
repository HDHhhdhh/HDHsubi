[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'perf/append_history_support.ps1')
function Assert-HistoryTest {
  param([bool]$Condition,[string]$Message)
  if (-not $Condition) { throw $Message }
}
function Expect-HistoryRejection {
  param([scriptblock]$Action)
  $rejected = $false
  try { $null = & $Action } catch { $rejected = $true }
  Assert-HistoryTest $rejected 'Corrupt history or unsafe output was accepted.'
}
$roots = [Collections.Generic.List[string]]::new()
try {
  foreach ($case in @(@{N=1;H=0},@{N=3;H=1},@{N=4;H=2})) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-fixture-' + [guid]::NewGuid().ToString('N'))
    $roots.Add($root)
    $fixture = New-MathSecrAppendHistoryFixture -ProblemCount $case.N -HistoryDepth $case.H -OutRoot $root
    Assert-HistoryTest ($fixture.Manifest.sessions.Count -eq ($case.H + 1)) 'History session count changed.'
    foreach ($stage in $fixture.Manifest.sessions) {
      $session = Read-MathSecrEditAppendArtifact $stage.artifact $root
      $before = ConvertTo-Json -InputObject $session -Depth 100 -Compress
      $pass = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root
      Assert-HistoryTest ($pass.Valid -and $pass.ReportProjection.SuccessCount -eq $stage.selectedCount) 'Intermediate session failed.'
      Assert-HistoryTest ((ConvertTo-Json -InputObject $session -Depth 100 -Compress) -ceq $before) 'Validation mutated the fixture.'
      Assert-HistoryTest ($session.snapshot.selectionBeforeNextIds.Count -eq ($case.N - $case.H)) 'Historical FirstNext was overwritten.'
      if ($stage.stage -eq 0) { Assert-HistoryTest ($null -eq $session.snapshot.PSObject.Properties['editAppendReceipt']) 'H=0 invented append evidence.' }
      foreach ($target in $session.snapshot.targets | Where-Object initial -CEQ 'not-started') {
        Assert-HistoryTest ($null -eq $target.PSObject.Properties['searchAttemptReceipt']) 'An unstarted row has an invented search.'
      }
    }
    Expect-HistoryRejection {New-MathSecrAppendHistoryFixture -ProblemCount $case.N -HistoryDepth $case.H -OutRoot $root}
    if ($case.H -gt 0) {
      $session = Copy-MathSecrBenchmarkObject $fixture.Session
      $session.snapshot.editAppendReceipt.priorSessionArtifact.sha256 = '0' * 64
      Expect-HistoryRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root}
      $session = Copy-MathSecrBenchmarkObject $fixture.Session
      $session.snapshot.editAppendReceipt.PSObject.Properties.Remove('confirmActionArtifact')
      Expect-HistoryRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root}
      $session = Copy-MathSecrBenchmarkObject $fixture.Session
      $session.persistedCards[0].rawVisibleDbName = 'invented DB'
      Expect-HistoryRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root}
    }
    [IO.File]::AppendAllText((Join-Path $root 'source-1.png'),'tamper')
    Expect-HistoryRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $fixture.Session -ProjectRoot $root}
  }
  Expect-HistoryRejection {Assert-MathSecrBenchmarkTempRoot $ProjectRoot}
  Expect-HistoryRejection {New-MathSecrAppendHistoryFixture -ProblemCount 2 -HistoryDepth 2 -OutRoot $roots[0]}
  $measured = & (Join-Path $PSScriptRoot 'perf/measure_after_reload.ps1') -ProblemCount 3 -HistoryDepth 2 -Repeat 2 | ConvertFrom-Json
  Assert-HistoryTest ($measured.phase0FormulaMatches -and $measured.samples.Count -eq 2) 'Proxy counting failed.'
  foreach ($sample in $measured.samples) {
    Assert-HistoryTest ($sample.calls.'Invoke-MathSecrStateMachine' -eq 9 -and $sample.calls.'Invoke-MathSecrProductionStep' -eq 3 -and
      $sample.calls.'Get-FileHash' -gt 0 -and $sample.calls.'ConvertFrom-MathSecrContractJson' -gt 0) 'Proxy counters did not reset or include recursive calls.'
  }
  Write-Output 'AppendHistoryFixture PASS (H=0/1/2, all intermediate stages, immutable FirstNext, tamper/missing receipt rejection, scoped cleanup, proxy recursion/reset).'
} finally {
  foreach ($root in $roots) { if (Test-Path -LiteralPath $root) { Remove-MathSecrOwnedBenchmarkRoot $root } }
}
