param(
  [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [ValidateSet('All')][string]$Case = 'All'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
. (Join-Path $PSScriptRoot 'state_machine.ps1')
. (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/body-comparison/synthetic_selection_test_support.ps1')

function Assert-BodyEqual {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -cne $Expected) { throw "$Message. Expected '$Expected', got '$Actual'" }
}
function Copy-BodyTestObject {
  param($Value)
  $Value | ConvertTo-Json -Depth 60 | ConvertFrom-MathSecrSyntheticTestJson
}

$fixtures = Get-Content -LiteralPath (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json') -Raw | ConvertFrom-MathSecrSyntheticTestJson
$seeds = @{}
foreach ($route in @('initial', 'candidate', 'whole', 'metadata')) {
  $fixtureName = if ($route -ceq 'metadata') { 'MetadataRescueExact' } else { 'Success' }
  $snapshot = Copy-BodyTestObject @($fixtures.cases | Where-Object { $_.name -ceq $fixtureName })[0].input
  $snapshot.targets = @($snapshot.targets[0])
  $target = $snapshot.targets[0]
  if ($route -ceq 'candidate' -or $route -ceq 'whole') {
    $target.initial = 'no_exact'
    $target | Add-Member candidateRecovery $(if ($route -ceq 'candidate') { 'exact' } else { 'missed' }) -Force
  }
  if ($route -ceq 'whole') {
    $target | Add-Member wholeDb 'exact' -Force
    $snapshot | Add-Member wholeDbScopeVerified $true -Force
  }
  $snapshot.selectionBeforeNextIds = @($target.selectedId)
  $snapshot.edit.draftIds = @($target.selectedId)
  $snapshot.persistence.ids = @($target.selectedId)
  Set-MathSecrSyntheticSelectionEvidence -Target $target -ProjectRoot $ProjectRoot
  $result = Invoke-MathSecrStateMachine -Snapshot $snapshot -ProjectRoot $ProjectRoot
  Assert-BodyEqual $result.State 'REPORT' "$route positive state"
  Assert-BodyEqual $result.Status '완료' "$route positive status"
  Assert-BodyEqual @($result.SelectionEvidence).Count 1 "$route one bound selection evidence"
  Assert-BodyEqual $result.SelectionEvidence[0].SearchObservation.FreshResultVerified $true "$route derived freshness projection"
  Assert-BodyEqual $result.SelectionEvidence[0].SearchObservation.BodyExactVerified $false "$route projection does not claim body oracle"
  Assert-BodyEqual $result.SelectionEvidence[0].SearchObservation.CompleteCoverageVerified $false "$route early exact does not claim exhausted results"
  $seeds[$route] = $snapshot
}

$bodyAttacks = @(
  @{ Name = 'missing body receipt'; Mutate = { param($t) $t.PSObject.Properties.Remove('bodyComparisonReceipt') } },
  @{ Name = 'missing source binding'; Mutate = { param($t) $t.PSObject.Properties.Remove('sourceBodyArtifact') } },
  @{ Name = 'wrong source path'; Mutate = { param($t) $t.bodyComparisonReceipt.sourceRenderArtifact = $t.bodyComparisonReceipt.candidateRenderArtifact } },
  @{ Name = 'wrong source hash'; Mutate = { param($t) $t.bodyComparisonReceipt.sourceRenderSha256 = 'a' * 64 } },
  @{ Name = 'stale candidate bytes hash'; Mutate = { param($t) $t.bodyComparisonReceipt.candidateRenderSha256 = 'b' * 64 } },
  @{ Name = 'wrong source number'; Mutate = { param($t) $t.bodyComparisonReceipt.sourceProblemNumber = 'unrelated-source' } },
  @{ Name = 'wrong occurrence'; Mutate = { param($t) $t.bodyComparisonReceipt.occurrenceKey = 'unrelated-occurrence' } },
  @{ Name = 'wrong candidate'; Mutate = { param($t) $t.bodyComparisonReceipt.candidateId = 'unrelated-candidate' } },
  @{ Name = 'mismatch verdict'; Mutate = { param($t) $t.bodyComparisonReceipt.verdict = 'different' } },
  @{ Name = 'unresolved glyphs'; Mutate = { param($t) $t.bodyComparisonReceipt.unresolvedGlyphs = $true } },
  @{ Name = 'string false'; Mutate = { param($t) $t.bodyComparisonReceipt.unresolvedGlyphs = 'false' } },
  @{ Name = 'fractional render scale'; Mutate = { param($t) $t.bodyComparisonReceipt.sourceRenderScale = 1.5 } },
  @{ Name = 'string render scale'; Mutate = { param($t) $t.bodyComparisonReceipt.candidateRenderScale = '2' } },
  @{ Name = 'zero render scale'; Mutate = { param($t) $t.bodyComparisonReceipt.sourceRenderScale = 0 } },
  @{ Name = 'wrong policy'; Mutate = { param($t) $t.bodyComparisonReceipt.policyVersion = 'choices-exact-v1' } },
  @{ Name = 'missing comparer'; Mutate = { param($t) $t.bodyComparisonReceipt.comparedBy = ' ' } },
  @{ Name = 'invalid time'; Mutate = { param($t) $t.bodyComparisonReceipt.comparedAtUtc = 'yesterday' } },
  @{ Name = 'time type'; Mutate = { param($t) $t.bodyComparisonReceipt.comparedAtUtc = 1 } },
  @{ Name = 'missing comparisons'; Mutate = { param($t) $t.bodyComparisonReceipt.comparison = $null } },
  @{ Name = 'missing component'; Mutate = { param($t) $t.bodyComparisonReceipt.comparison.PSObject.Properties.Remove('figures') } },
  @{ Name = 'body absent'; Mutate = { param($t) $t.bodyComparisonReceipt.comparison.bodyText = 'not-present' } },
  @{ Name = 'required value absent'; Mutate = { param($t) $t.bodyComparisonReceipt.comparison.requiredValue = 'not-present' } },
  @{ Name = 'parent path traversal'; Mutate = { param($t) $t.bodyComparisonReceipt.candidateRenderArtifact = '../outside.png' } },
  @{ Name = 'absolute path'; Mutate = { param($t) $t.bodyComparisonReceipt.candidateRenderArtifact = 'C:\outside.png' } },
  @{ Name = 'missing image'; Mutate = { param($t) $t.bodyComparisonReceipt.candidateRenderArtifact = 'missing-body-image.png' } },
  @{ Name = 'same source candidate file'; Mutate = { param($t) $t.bodyComparisonReceipt.candidateRenderArtifact = $t.bodyComparisonReceipt.sourceRenderArtifact; $t.bodyComparisonReceipt.candidateRenderSha256 = $t.bodyComparisonReceipt.sourceRenderSha256 } }
)
foreach ($component in @('bodyText', 'conditions', 'formulas', 'figures', 'pointLabels', 'requiredValue', 'internalStatements')) {
  $componentName = $component
  $bodyAttacks += @{ Name = "mismatch $component"; Mutate = { param($t) $t.bodyComparisonReceipt.comparison.$componentName = 'mismatch' }.GetNewClosure() }
}
$negativeCount = 0
foreach ($route in @('initial', 'candidate', 'whole', 'metadata')) {
  foreach ($attack in $bodyAttacks) {
    # Clone the completed seed first; never regenerate evidence after corruption.
    $snapshot = Copy-BodyTestObject $seeds[$route]
    & $attack.Mutate $snapshot.targets[0]
    $result = Invoke-MathSecrStateMachine -Snapshot $snapshot -ProjectRoot $ProjectRoot
    Assert-BodyEqual $result.State 'INITIAL_SEARCH' "$route / $($attack.Name) state"
    Assert-BodyEqual $result.Status 'body-comparison-receipt-invalid' "$route / $($attack.Name) rejected"
    Assert-BodyEqual ($result.BlockedActions -ccontains 'next_step') $true "$route / $($attack.Name) cannot advance"
    $negativeCount++
  }
}

$searchAttacks = @(
  @{ Name = 'missing search receipt'; Mutate = { param($t) $t.PSObject.Properties.Remove('searchAttemptReceipt') } },
  @{ Name = 'wrong winning attempt'; Mutate = { param($t) $t.bodyComparisonReceipt.searchAttemptId = 'wrong-attempt' } },
  @{ Name = 'wrong search target'; Mutate = { param($t) $t.searchAttemptReceipt.targetBinding.sourceProblemNumber = 'other' } },
  @{ Name = 'wrong search occurrence'; Mutate = { param($t) $t.searchAttemptReceipt.targetBinding.occurrenceKey = 'other' } },
  @{ Name = 'unobserved exact'; Mutate = { param($t) $t.searchAttemptReceipt.attempts[-1].inspectedIds = @('other') } },
  @{ Name = 'wrong exact ID'; Mutate = { param($t) $t.searchAttemptReceipt.attempts[-1].exactMatchIds = @('other') } },
  @{ Name = 'missing observations'; Mutate = { param($t) $t.searchAttemptReceipt.attempts[-1].PSObject.Properties.Remove('observationReceipt') } },
  @{ Name = 'non-Aside-REPL observation'; Mutate = { param($t) $t.searchAttemptReceipt.attempts[-1].observationReceipt.submission.surface = 'offline-dom-test' } },
  @{ Name = 'historical IAB observation cannot authorize current selection'; Mutate = { param($t) $t.searchAttemptReceipt.attempts[-1].observationReceipt.submission.surface = 'iab' } },
  @{ Name = 'foreign paper URL'; Mutate = { param($t) $o = $t.searchAttemptReceipt.attempts[-1].observationReceipt; $o.submission.url = 'https://offline.invalid/mypaper/fake'; $o.beforeSubmit.raw.url = $o.submission.url; foreach ($read in $o.observations) { $read.raw.url = $o.submission.url } } },
  @{ Name = 'stale observed submit'; Mutate = { param($t) $t.searchAttemptReceipt.attempts[-1].observationReceipt.observations[-1].raw.result.observedSubmitId = 'old-submit' } },
  @{ Name = 'selected ID absent from DOM'; Mutate = { param($t) foreach ($read in $t.searchAttemptReceipt.attempts[-1].observationReceipt.observations) { $read.raw.result.orderedIds = @('other') } } },
  @{ Name = 'selected ID only in transient read'; Mutate = { param($t) $o = $t.searchAttemptReceipt.attempts[-1].observationReceipt; $o.observations[1].raw.result.orderedIds = @('other'); $o.observations[2].raw.result.orderedIds = @('other') } },
  @{ Name = 'formula kind masks literal text'; Mutate = { param($t) $o = $t.searchAttemptReceipt.attempts[-1].observationReceipt; $o.submission.criteria.chips[0].kind = 'formula'; $o.beforeSubmit.raw.criteria.chips[0].kind = 'formula'; foreach ($read in $o.observations) { $read.raw.criteria.chips[0].kind = 'formula' } } },
  @{ Name = 'invalid exact-producing ladder'; Mutate = { param($t) $t.searchAttemptReceipt.attempts[-1].phase = 'refinement'; $t.searchAttemptReceipt.literalOnlyLadderCompleted = $false } }
)
foreach ($route in @('initial', 'candidate', 'whole')) {
  foreach ($attack in $searchAttacks) {
    $snapshot = Copy-BodyTestObject $seeds[$route]
    & $attack.Mutate $snapshot.targets[0]
    $result = Invoke-MathSecrStateMachine -Snapshot $snapshot -ProjectRoot $ProjectRoot
    Assert-BodyEqual $result.State 'INITIAL_SEARCH' "$route / $($attack.Name) state"
    Assert-BodyEqual $result.Status 'selected-search-receipt-invalid' "$route / $($attack.Name) rejected"
    $negativeCount++
  }
}
foreach ($attack in @(
  @{ Name = 'metadata missing observation'; Mutate = { param($t) $t.metadataRescue.buckets[0].PSObject.Properties.Remove('observationReceipt') } },
  @{ Name = 'metadata wrong attempt'; Mutate = { param($t) $t.bodyComparisonReceipt.searchAttemptId = 'other' } },
  @{ Name = 'metadata stale observation'; Mutate = { param($t) $t.metadataRescue.buckets[0].observationReceipt.observations[-1].raw.result.observedSubmitId = 'old-submit' } },
  @{ Name = 'metadata selected ID only in transient read'; Mutate = {
    param($t)
    $o = $t.metadataRescue.buckets[0].observationReceipt
    $last = Copy-BodyTestObject $o.observations[-1]
    $last.raw.captureId += '-fourth'; $last.readEvidenceId += '-fourth'
    $last.raw.capturedAtUtc = '2026-09-05T00:00:04.000Z'; $last.raw.monotonicMs = 4000
    $o.observations = @($o.observations) + @($last)
    for ($i = 1; $i -lt $o.observations.Count; $i++) { $o.observations[$i].raw.result.orderedIds = @('other') }
  } }
)) {
  $snapshot = Copy-BodyTestObject $seeds['metadata']
  & $attack.Mutate $snapshot.targets[0]
  $result = Invoke-MathSecrStateMachine -Snapshot $snapshot -ProjectRoot $ProjectRoot
  Assert-BodyEqual $result.Status 'selected-search-receipt-invalid' "$($attack.Name) rejected"
  $negativeCount++
}
$wholeScopeAttack = Copy-BodyTestObject $seeds['whole']
$o = $wholeScopeAttack.targets[0].searchAttemptReceipt.attempts[-1].observationReceipt
$o.submission.criteria.scopeMode = 'synthetic-scoped'; $o.beforeSubmit.raw.criteria.scopeMode = 'synthetic-scoped'
foreach ($read in $o.observations) { $read.raw.criteria.scopeMode = 'synthetic-scoped' }
$wholeScopeResult = Invoke-MathSecrStateMachine -Snapshot $wholeScopeAttack -ProjectRoot $ProjectRoot
Assert-BodyEqual $wholeScopeResult.Status 'selected-search-receipt-invalid' 'whole DB exact requires observed whole DB mode'
$negativeCount++
# Exercise the public file-based entry point in the running PowerShell host.
# This catches ISO timestamp coercion that in-memory receipt tests cannot see.
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$tempRoot = Join-Path $tempBase ('mathsecr-body-comparison-cli-' + [guid]::NewGuid().ToString('N'))
$tempFiles = @('valid-input.json', 'valid-result.json', 'invalid-input.json', 'invalid-result.json')
try {
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  $validInput = Join-Path $tempRoot $tempFiles[0]
  $validOutput = Join-Path $tempRoot $tempFiles[1]
  [IO.File]::WriteAllText($validInput, ($seeds['initial'] | ConvertTo-Json -Depth 60), [Text.UTF8Encoding]::new($false))
  $hostExecutable = (Get-Process -Id $PID).Path
  $cliPath = Join-Path $PSScriptRoot 'validate_selection_snapshot.ps1'
  $validCliOutput = @(& $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $cliPath -InputPath $validInput -ProjectRoot $ProjectRoot -OutPath $validOutput 2>&1)
  Assert-BodyEqual $LASTEXITCODE 0 ('CLI valid JSON exit: ' + ($validCliOutput -join ' '))
  $validResult = Get-Content -LiteralPath $validOutput -Raw -Encoding UTF8 | ConvertFrom-MathSecrSyntheticTestJson
  Assert-BodyEqual $validResult.State 'REPORT' 'CLI valid JSON report state'
  Assert-BodyEqual $validResult.Status '완료' 'CLI valid JSON report status'
  Assert-BodyEqual @($validResult.SelectionEvidence).Count 1 'CLI selected receipt survives JSON roundtrip'
  Assert-BodyEqual $validResult.SelectionEvidence[0].SearchObservation.AttemptId 'synthetic-exact-1' 'CLI preserves winning attempt projection'
  Assert-BodyEqual $validResult.SelectionEvidence[0].SearchObservation.FreshResultVerified $true 'CLI emits derived freshness'

  $invalidSnapshot = Copy-BodyTestObject $seeds['initial']
  $invalidSnapshot.targets[0].PSObject.Properties.Remove('bodyComparisonReceipt')
  $invalidInput = Join-Path $tempRoot $tempFiles[2]
  $invalidOutput = Join-Path $tempRoot $tempFiles[3]
  [IO.File]::WriteAllText($invalidInput, ($invalidSnapshot | ConvertTo-Json -Depth 60), [Text.UTF8Encoding]::new($false))
  $invalidCliOutput = @(& $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $cliPath -InputPath $invalidInput -ProjectRoot $ProjectRoot -OutPath $invalidOutput 2>&1)
  Assert-BodyEqual $LASTEXITCODE 1 ('CLI missing receipt exit: ' + ($invalidCliOutput -join ' '))
  $invalidResult = Get-Content -LiteralPath $invalidOutput -Raw -Encoding UTF8 | ConvertFrom-MathSecrSyntheticTestJson
  Assert-BodyEqual $invalidResult.Status 'body-comparison-receipt-invalid' 'CLI missing receipt blocks selection'
} finally {
  $resolvedRoot = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\', '/')
  if (-not [string]::Equals((Split-Path -Parent $resolvedRoot), $tempBase, [StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $resolvedRoot) -cnotmatch '^mathsecr-body-comparison-cli-[0-9a-f]{32}$') {
    throw "Refusing CLI test cleanup outside its owned system-temp directory: $resolvedRoot"
  }
  if (Test-Path -LiteralPath $resolvedRoot) {
    if (((Get-Item -LiteralPath $resolvedRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'Refusing CLI test cleanup through a reparse point'
    }
    # Delete only the four named files; unexpected contents are never recursive targets.
    foreach ($name in $tempFiles) {
      $filePath = Join-Path $resolvedRoot $name
      if (Test-Path -LiteralPath $filePath -PathType Leaf) { Remove-Item -LiteralPath $filePath -Force }
    }
    Remove-Item -LiteralPath $resolvedRoot -Force
  }
}
Write-Host "BodyComparisonContract PASS positive_routes=4 negative_cases=$negativeCount cli_roundtrips=2 truth_scope=offline-contract product_behavior=false independent_oracle=false"
