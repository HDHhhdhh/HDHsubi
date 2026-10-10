param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$Case = "All"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

. (Join-Path $PSScriptRoot "state_machine.ps1")
. (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/body-comparison/synthetic_selection_test_support.ps1')
$dbInferenceScriptPath = Join-Path $PSScriptRoot "db_inference.ps1"
$dbInferenceModule = New-Module -Name "MathSecrStateMachineDbInferenceContract" -ArgumentList $dbInferenceScriptPath -ScriptBlock {
  param([string]$ScriptPath)
  . $ScriptPath
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -cne $Expected) {
    throw "$Message. Expected '$Expected', got '$Actual'"
  }
}

function Assert-Sequence {
  param([object[]]$Actual, [object[]]$Expected, [string]$Message)
  if ($Actual.Count -ne $Expected.Count) {
    throw "$Message. Expected $($Expected.Count) values, got $($Actual.Count)"
  }
  for ($index = 0; $index -lt $Actual.Count; $index++) {
    Assert-Equal $Actual[$index] $Expected[$index] "$Message at index $index"
  }
}

$fixturePath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\state-machine\cases.json"
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-MathSecrSyntheticTestJson
# Migration is test-only and occurs before any attack mutates the evidence.
# Historical JSON remains a dated fixture, not a source of visual truth.
foreach ($legacyCase in @($fixture.cases)) {
  foreach ($target in @($legacyCase.input.targets)) {
    Set-MathSecrSyntheticSelectionEvidence -Target $target -ProjectRoot $ProjectRoot
  }
}
$cases = @($fixture.cases | Where-Object { $Case -eq "All" -or $_.name -eq $Case })
if ($cases.Count -eq 0) {
  throw "No state-machine fixture matched case: $Case"
}

foreach ($fixtureCase in $cases) {
  $result = Invoke-MathSecrStateMachine $fixtureCase.input
  $stateMessage = if ($fixtureCase.name -ceq "PermutationDrift") { "ordered bundle permutation drift state" } else { "$($fixtureCase.name) state" }
  $statusMessage = if ($fixtureCase.name -ceq "DuplicateTargetIds") { "source occurrence identity collapse status" } else { "$($fixtureCase.name) status" }
  Assert-Equal $result.State $fixtureCase.expect.state $stateMessage
  Assert-Equal $result.Status $fixtureCase.expect.status $statusMessage
  Assert-Equal $result.SelectedCount $fixtureCase.expect.selectedCount "$($fixtureCase.name) selected count"
  Assert-Equal $result.DraftCount $fixtureCase.expect.draftCount "$($fixtureCase.name) draft count"
  Assert-Equal $result.PersistedCount $fixtureCase.expect.persistedCount "$($fixtureCase.name) persisted count"
  if ($null -ne $fixtureCase.expect.PSObject.Properties['selectedOccurrenceKeys']) {
    Assert-Sequence @($result.SelectedOccurrenceKeys) @($fixtureCase.expect.selectedOccurrenceKeys) "$($fixtureCase.name) selected occurrence keys"
  }
  if ($null -ne $fixtureCase.expect.PSObject.Properties['draftOccurrenceKeys']) {
    Assert-Sequence @($result.DraftOccurrenceKeys) @($fixtureCase.expect.draftOccurrenceKeys) "$($fixtureCase.name) draft occurrence keys"
  }
  if ($null -ne $fixtureCase.expect.PSObject.Properties['persistedOccurrenceKeys']) {
    Assert-Sequence @($result.PersistedOccurrenceKeys) @($fixtureCase.expect.persistedOccurrenceKeys) "$($fixtureCase.name) persisted occurrence keys"
  }
  Assert-Sequence @($result.Trace) @($fixtureCase.expect.trace) "$($fixtureCase.name) trace"
  Assert-Sequence @($result.BlockedActions) @($fixtureCase.expect.blockedActions) "$($fixtureCase.name) blocked actions"
  Assert-Equal $result.IssueClicked ([bool]$fixtureCase.input.issueClicked) "$($fixtureCase.name) 출제하기 state"
  if ($result.IssueClicked) {
    Assert-Equal $result.Status "차단" "$($fixtureCase.name) 출제하기 guard"
  }
}

if ($Case -eq "All") {
  $strictBooleanAttacks = @(
    @{ Name = "issueClicked string"; Source = "Success"; State = "PREPARE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.issueClicked = "false" } },
    @{ Name = "sourcePresent string"; Source = "Success"; State = "PREPARE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.sourcePresent = "false" } },
    @{ Name = "asideRepl.available string"; Source = "Success"; State = "ASIDE_REPL_READY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.asideRepl.available = "false" } },
    @{ Name = "asideRepl.paperVerified string"; Source = "Success"; State = "ASIDE_REPL_READY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.asideRepl.paperVerified = "false" } },
    @{ Name = "asideRepl.nonAsideReplLiveManipulation string"; Source = "Success"; State = "ASIDE_REPL_READY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.asideRepl.nonAsideReplLiveManipulation = "false" } },
    @{ Name = "cleanStateVerified string"; Source = "Success"; State = "CLEAN_STATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.cleanStateVerified = "false" } },
    @{ Name = "scope.verified string"; Source = "Success"; State = "SCOPE_LOCK"; Mutate = { param($candidateSnapshot) $candidateSnapshot.scope.verified = "false" } },
    @{ Name = "scope.unexpectedBroadResult string"; Source = "Success"; State = "SCOPE_LOCK"; Mutate = { param($candidateSnapshot) $candidateSnapshot.scope.unexpectedBroadResult = "false" } },
    @{ Name = "dbInference.ScopeLockReady string"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.ScopeLockReady = "true" } },
    @{ Name = "dbInference.FreshSearchReceiptReady string"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.FreshSearchReceiptReady = "true" } },
    @{ Name = "scope lock selector string"; Source = "InferredScopeSuccess"; State = "SCOPE_LOCK"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.SelectorSearchCleared = "true" } },
    @{ Name = "scope lock receipt string"; Source = "InferredScopeSuccess"; State = "SCOPE_LOCK"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.ScopeReceiptVerified = "true" } },
    @{ Name = "scope identity string"; Source = "InferredScopeSuccess"; State = "SCOPE_LOCK"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.ScopeIdentityMatches = "true" } },
    @{ Name = "row scope ready string"; Source = "InferredScopeSuccess"; State = "SCOPE_LOCK"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLockReady = "true" } },
    @{ Name = "scoped submit string"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.Submitted = "true" } },
    @{ Name = "scoped fresh string"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.FreshResultVerified = "true" } },
    @{ Name = "scoped identity string"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.ScopeIdentityMatches = "true" } },
    @{ Name = "row fresh ready string"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.FreshSearchReceiptReady = "true" } },
    @{ Name = "wholeDbScopeVerified string"; Source = "Partial"; State = "WHOLE_DB_RETRY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.wholeDbScopeVerified = "false" } },
    @{ Name = "nextClicked string"; Source = "Success"; State = "PRE_NEXT_GATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.nextClicked = "false" } },
    @{ Name = "freshReloadVerified string"; Source = "Success"; State = "PERSIST_VERIFY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.freshReloadVerified = "false" } }
  )

  foreach ($attack in $strictBooleanAttacks) {
    $sourceCase = @($fixture.cases | Where-Object { $_.name -eq $attack.Source })
    if ($sourceCase.Count -ne 1) { throw "Strict boolean source fixture missing: $($attack.Source)" }
    $attackInput = $sourceCase[0].input | ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
    & $attack.Mutate $attackInput
    $attackResult = Invoke-MathSecrStateMachine $attackInput
    Assert-Equal $attackResult.State $attack.State "$($attack.Name) state"
    Assert-Equal $attackResult.Status "차단" "$($attack.Name) strict type rejection"
  }

  $strictShapeAttacks = @(
    @{ Name = "scalar targets"; Source = "Success"; State = "INITIAL_SEARCH"; Mutate = {
      param($candidateSnapshot)
      $candidateSnapshot.targets = $candidateSnapshot.targets[0]
      $candidateSnapshot.selectionBeforeNextIds = @("7231357")
      $candidateSnapshot.edit.draftIds = @("7231357")
      $candidateSnapshot.persistence.ids = @("7231357")
    } },
    @{ Name = "duplicate target numbers"; Source = "Success"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[1].number = $candidateSnapshot.targets[0].number } },
    @{ Name = "numeric selectedId"; Source = "Success"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].selectedId = 7231357 } },
    @{ Name = "scalar selected bundle"; Source = "Success"; State = "PRE_NEXT_GATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.selectionBeforeNextIds = "7231357" } },
    @{ Name = "nonempty zero-selection bundle"; Source = "ZeroSelection"; State = "PRE_NEXT_GATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.selectionBeforeNextIds = @("ghost") } },
    @{ Name = "zero-selection ghost draft"; Source = "ZeroSelection"; State = "PRE_NEXT_GATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.draftIds = @("ghost") } },
    @{ Name = "zero-selection ghost old ID"; Source = "ZeroSelection"; State = "PRE_NEXT_GATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.oldIds = @("ghost") } },
    @{ Name = "zero-selection edit recovery"; Source = "ZeroSelection"; State = "PRE_NEXT_GATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.recovery = "recovered" } },
    @{ Name = "zero-selection ghost persisted"; Source = "ZeroSelection"; State = "PRE_NEXT_GATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.ids = @("ghost") } },
    @{ Name = "zero-selection reload claim"; Source = "ZeroSelection"; State = "PRE_NEXT_GATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.freshReloadVerified = $true } },
    @{ Name = "zero-selection string reload"; Source = "ZeroSelection"; State = "PRE_NEXT_GATE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.freshReloadVerified = "false" } },
    @{ Name = "candidate pending after next"; Source = "SearchRegression"; State = "CANDIDATE_RECOVERY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.nextClicked = $true } },
    @{ Name = "candidate pending string next"; Source = "SearchRegression"; State = "CANDIDATE_RECOVERY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.nextClicked = "false" } },
    @{ Name = "whole-DB pending after next"; Source = "WholeDbPendingWithoutScope"; State = "WHOLE_DB_RETRY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.nextClicked = $true } },
    @{ Name = "null dbInference"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference = $null } },
    @{ Name = "legacy required envelope"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference | Add-Member -NotePropertyName required -NotePropertyValue $true } },
    @{ Name = "legacy separate search receipt"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot | Add-Member -NotePropertyName searchReceipt -NotePropertyValue ([pscustomobject]@{}) } },
    @{ Name = "unknown dbInference Status"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Status = "guessed" } },
    @{ Name = "noncanonical dbInference Status"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Status = "INFERRED" } },
    @{ Name = "empty inference Results"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results = @() } },
    @{ Name = "both inferred candidates"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].InferredCollection = "교육청, 평가원" } },
    @{ Name = "missing inferred candidate"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].InferredScope = $null } },
    @{ Name = "mixed unresolved result row"; Source = "InferredScopeSuccess"; State = "DB_INFERENCE"; Mutate = {
      param($candidateSnapshot)
      $secondRow = $candidateSnapshot.dbInference.Results[0] | ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
      $secondRow.ClusterId = "mixed-unresolved"
      $secondRow.Status = "unresolved"
      $candidateSnapshot.dbInference.Results = @( $candidateSnapshot.dbInference.Results[0], $secondRow )
      $candidateSnapshot.dbInference.InferredScope = $null
      $candidateSnapshot.dbInference.Receipts = $null
    } },
    @{ Name = "scalar scoped chips"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.Chips = "삼차방정식" } },
    @{ Name = "single scoped chip"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.Chips = @( "삼차방정식" ) } },
    @{ Name = "duplicate normalized scoped chips"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.Chips = @( "삼차방정식", "  삼차방정식  " ) } },
    @{ Name = "blank scoped chip"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.Chips = @( "삼차방정식", " " ) } },
    @{ Name = "blank scoped signature"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.ResultSignature = " " } },
    @{ Name = "numeric scoped selected scope"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.SelectedScope = 2026 } },
    @{ Name = "scalar draft bundle"; Source = "Success"; State = "EDIT_VERIFY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.draftIds = "7231357" } },
    @{ Name = "scalar old bundle"; Source = "Success"; State = "EDIT_VERIFY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.oldIds = "" } },
    @{ Name = "unknown edit recovery"; Source = "Success"; State = "EDIT_VERIFY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.recovery = "unknown" } },
    @{ Name = "scalar persisted bundle"; Source = "Success"; State = "PERSIST_VERIFY"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.ids = "7231357" } },
    @{ Name = "unique selected occurrence ghost"; Source = "Success"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot | Add-Member -NotePropertyName selectionBeforeNextOccurrenceKeys -NotePropertyValue @("ghost") } },
    @{ Name = "unique draft occurrence ghost"; Source = "Success"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit | Add-Member -NotePropertyName draftOccurrenceKeys -NotePropertyValue @("ghost") } },
    @{ Name = "unique persisted occurrence ghost"; Source = "Success"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence | Add-Member -NotePropertyName occurrenceKeys -NotePropertyValue @("ghost") } },
    @{ Name = "unique all occurrence ghosts"; Source = "Success"; State = "INITIAL_SEARCH"; Mutate = {
      param($candidateSnapshot)
      $candidateSnapshot | Add-Member -NotePropertyName selectionBeforeNextOccurrenceKeys -NotePropertyValue @("ghost")
      $candidateSnapshot.edit | Add-Member -NotePropertyName draftOccurrenceKeys -NotePropertyValue @("ghost")
      $candidateSnapshot.persistence | Add-Member -NotePropertyName occurrenceKeys -NotePropertyValue @("ghost")
    } },
    @{ Name = "unique occurrence bundle only one present"; Source = "Success"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot | Add-Member -NotePropertyName selectionBeforeNextOccurrenceKeys -NotePropertyValue @("source-page-1") } },
    @{ Name = "unique occurrence bundles reordered"; Source = "Success"; State = "INITIAL_SEARCH"; Mutate = {
      param($candidateSnapshot)
      $reordered = @("8", "2", "3", "4", "5", "6", "7", "1")
      $candidateSnapshot | Add-Member -NotePropertyName selectionBeforeNextOccurrenceKeys -NotePropertyValue $reordered
      $candidateSnapshot.edit | Add-Member -NotePropertyName draftOccurrenceKeys -NotePropertyValue $reordered
      $candidateSnapshot.persistence | Add-Member -NotePropertyName occurrenceKeys -NotePropertyValue $reordered
    } },
    @{ Name = "duplicate occurrence missing key"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[1].occurrenceKey = $null } },
    @{ Name = "target occurrence key leading whitespace"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[1].occurrenceKey = " source-page-2" } },
    @{ Name = "target occurrence key trailing whitespace"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[1].occurrenceKey = "source-page-2 " } },
    @{ Name = "selected occurrence key leading whitespace"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.selectionBeforeNextOccurrenceKeys[1] = " source-page-2" } },
    @{ Name = "selected occurrence key trailing whitespace"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.selectionBeforeNextOccurrenceKeys[1] = "source-page-2 " } },
    @{ Name = "draft occurrence key leading whitespace"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.draftOccurrenceKeys[1] = " source-page-2" } },
    @{ Name = "draft occurrence key trailing whitespace"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.draftOccurrenceKeys[1] = "source-page-2 " } },
    @{ Name = "persisted occurrence key leading whitespace"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.occurrenceKeys[1] = " source-page-2" } },
    @{ Name = "persisted occurrence key trailing whitespace"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.occurrenceKeys[1] = "source-page-2 " } },
    @{ Name = "target occurrence key comma"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[1].occurrenceKey = "source,page-2" } },
    @{ Name = "selected occurrence key comma"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.selectionBeforeNextOccurrenceKeys[1] = "source,page-2" } },
    @{ Name = "draft occurrence key comma"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.draftOccurrenceKeys[1] = "source,page-2" } },
    @{ Name = "persisted occurrence key comma"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.occurrenceKeys[1] = "source,page-2" } },
    @{ Name = "target occurrence key reserved sentinel"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[1].occurrenceKey = "없음" } },
    @{ Name = "selected occurrence key reserved sentinel"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.selectionBeforeNextOccurrenceKeys[1] = "없음" } },
    @{ Name = "draft occurrence key reserved sentinel"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.draftOccurrenceKeys[1] = "없음" } },
    @{ Name = "persisted occurrence key reserved sentinel"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.occurrenceKeys[1] = "없음" } },
    @{ Name = "target occurrence key newline"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[1].occurrenceKey = "source`r`npage-2" } },
    @{ Name = "selected occurrence key newline"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.selectionBeforeNextOccurrenceKeys[1] = "source`r`npage-2" } },
    @{ Name = "draft occurrence key newline"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.draftOccurrenceKeys[1] = "source`r`npage-2" } },
    @{ Name = "persisted occurrence key newline"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence.occurrenceKeys[1] = "source`r`npage-2" } },
    @{ Name = "duplicate occurrence numeric bundle key"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.selectionBeforeNextOccurrenceKeys[1] = 2 } },
    @{ Name = "duplicate occurrence control not verified"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.occurrenceProof.DuplicateAddControlVerified = $false } },
    @{ Name = "duplicate occurrence bundle mismatch"; Source = "DuplicateOccurrencesWithEvidence"; State = "INITIAL_SEARCH"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit.draftOccurrenceKeys = @( "source-page-2", "source-page-1" ) } }
  )

  foreach ($attack in $strictShapeAttacks) {
    $sourceCase = @($fixture.cases | Where-Object { $_.name -eq $attack.Source })
    if ($sourceCase.Count -ne 1) { throw "Strict shape source fixture missing: $($attack.Source)" }
    $attackInput = $sourceCase[0].input | ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
    & $attack.Mutate $attackInput
    $attackResult = Invoke-MathSecrStateMachine $attackInput
    Assert-Equal $attackResult.State $attack.State "$($attack.Name) state"
    Assert-Equal $attackResult.Status "차단" "$($attack.Name) strict shape rejection"
  }

  $metadataRescueAttacks = @(
    @{ Name = "second text chip reintroduced"; Source = "MetadataRescueMissed"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.textChips = @( "다항함수", "적분" ) } },
    @{ Name = "formula chip retained"; Source = "MetadataRescueMissed"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.formulaChips = @( "\\int" ) } },
    @{ Name = "forged stable no-growth count"; Source = "MetadataRescueMissed"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.buckets[0].stableNoGrowthReads = 3 } },
    @{ Name = "forged end-of-results flag"; Source = "MetadataRescueMissed"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.buckets[0].endOfResultsVerified = $false } },
    @{ Name = "end-read snapshot diverges from inspected IDs"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.buckets[0].endReadSnapshots[2] = @() } },
    @{ Name = "partition key not bound to printed month"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.buckets[1].partitionKey = "month=1;grade=고3" } },
    @{ Name = "partial partition key omits printed grade"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.buckets[1].partitionKey = "month=7" } },
    @{ Name = "source anomaly receipt is a string"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt = "offline-contract" } },
    @{ Name = "source anomaly receipt field missing"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.PSObject.Properties.Remove("candidateRenderScale") } },
    @{ Name = "source anomaly truth scope overclaims"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.truthScope = "external-ground-truth" } },
    @{ Name = "source anomaly artifact does not exist"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.sourceRenderArtifact = "mathsecr-paper-builder-kit/test-fixtures/pdf-pages/goguk2-print2/does-not-exist.png" } },
    @{ Name = "source anomaly artifact traverses project root"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.sourceRenderArtifact = "../outside.png" } },
    @{ Name = "source anomaly actual source hash mismatch"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.sourceRenderSha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" } },
    @{ Name = "source anomaly artifact reused"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.candidateRenderArtifact = $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.sourceRenderArtifact } },
    @{ Name = "source anomaly candidate was not inspected"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.candidateId = "uninspected-candidate" } },
    @{ Name = "source anomaly target number mismatch"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.sourceProblemNumber = "2" } },
    @{ Name = "source anomaly occurrence mismatch"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.occurrenceKey = "forged-occurrence" } },
    @{ Name = "source anomaly source hash malformed"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.sourceRenderSha256 = "not-a-sha256" } },
    @{ Name = "source anomaly scale is a string"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.sourceRenderScale = "3" } },
    @{ Name = "source anomaly render hashes reused"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.candidateRenderSha256 = $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.sourceRenderSha256 } },
    @{ Name = "source anomaly source render scale too low"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.sourceRenderScale = 1 } },
    @{ Name = "source anomaly candidate render scale too low"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.candidateRenderScale = 1 } },
    @{ Name = "source anomaly conflict class unknown"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.conflictClass = "exact-mismatch" } },
    @{ Name = "source anomaly comparison resolved"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.comparisonState = "mismatch" } },
    @{ Name = "source anomaly metadata override used"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.metadataOverrideUsed = $true } },
    @{ Name = "source anomaly metadata override string"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt.metadataOverrideUsed = "false" } },
    @{ Name = "source anomaly copied aggregate added"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0].metadataRescue.sourceAnomalyReceipt | Add-Member -NotePropertyName verified -NotePropertyValue $true } },
    @{ Name = "source anomaly carries selectedId"; Source = "MetadataRescueSourceAnomaly"; Mutate = { param($candidateSnapshot) $candidateSnapshot.targets[0] | Add-Member -NotePropertyName selectedId -NotePropertyValue "anomaly-2024" } }
  )
  foreach ($attack in $metadataRescueAttacks) {
    $sourceCase = @($fixture.cases | Where-Object { $_.name -eq $attack.Source })
    if ($sourceCase.Count -ne 1) { throw "Metadata-rescue source fixture missing: $($attack.Source)" }
    $attackInput = $sourceCase[0].input | ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
    & $attack.Mutate $attackInput
    $attackResult = Invoke-MathSecrStateMachine $attackInput
    Assert-Equal $attackResult.State "METADATA_RESCUE" "$($attack.Name) state"
    Assert-Equal $attackResult.Status "metadata-rescue-receipt-invalid" "$($attack.Name) receipt rejection"
  }

  $sourceAnomalyReceiptMissing = @($fixture.cases | Where-Object { $_.name -ceq "MetadataRescueSourceAnomaly" })[0].input |
    ConvertTo-Json -Depth 30 | ConvertFrom-MathSecrSyntheticTestJson
  $sourceAnomalyReceiptMissing.targets[0].metadataRescue.PSObject.Properties.Remove("sourceAnomalyReceipt")
  $sourceAnomalyReceiptMissingResult = Invoke-MathSecrStateMachine $sourceAnomalyReceiptMissing
  Assert-Equal $sourceAnomalyReceiptMissingResult.State "METADATA_RESCUE" "source anomaly raw receipt required state"
  Assert-Equal $sourceAnomalyReceiptMissingResult.Status "metadata-rescue-receipt-invalid" "source anomaly raw receipt required status"

  $sourceAnomalyAfterNext = @($fixture.cases | Where-Object { $_.name -ceq "MetadataRescueSourceAnomaly" })[0].input |
    ConvertTo-Json -Depth 30 | ConvertFrom-MathSecrSyntheticTestJson
  $sourceAnomalyAfterNext.nextClicked = $true
  $sourceAnomalyAfterNextResult = Invoke-MathSecrStateMachine $sourceAnomalyAfterNext
  Assert-Equal $sourceAnomalyAfterNextResult.State "METADATA_RESCUE" "source anomaly cannot advance state"
  Assert-Equal $sourceAnomalyAfterNextResult.Status "source-anomaly-pending" "source anomaly remains pending after next claim"
  Assert-Sequence @($sourceAnomalyAfterNextResult.BlockedActions) @( "select_cards", "select_all", "next_step" ) "source anomaly blocked actions"

  $partialSourceAnomaly = @($fixture.cases | Where-Object { $_.name -ceq "MetadataRescueSourceAnomaly" })[0].input |
    ConvertTo-Json -Depth 30 | ConvertFrom-MathSecrSyntheticTestJson
  $selectedExactTarget = [pscustomobject]@{
    number = 2
    initial = "exact"
    selectedId = "selected-exact"
  }
  Set-MathSecrSyntheticSelectionEvidence -Target $selectedExactTarget -ProjectRoot $ProjectRoot
  $partialSourceAnomaly.targets = @( $selectedExactTarget, $partialSourceAnomaly.targets[0] )
  $partialSourceAnomaly.selectionBeforeNextIds = @( "selected-exact" )
  $partialSourceAnomaly.nextClicked = $true
  $partialSourceAnomaly.edit.draftIds = @( "selected-exact" )
  $partialSourceAnomaly.persistence.ids = @( "selected-exact" )
  $partialSourceAnomaly.persistence.freshReloadVerified = $true
  $partialSourceAnomalyResult = Invoke-MathSecrStateMachine $partialSourceAnomaly
  Assert-Equal $partialSourceAnomalyResult.State "METADATA_RESCUE" "partial selection with source anomaly cannot advance state"
  Assert-Equal $partialSourceAnomalyResult.Status "source-anomaly-pending" "partial selection with source anomaly remains pending"
  Assert-Equal $partialSourceAnomalyResult.SelectedCount 1 "partial source anomaly preserves selected count without reporting"
  Assert-Sequence @($partialSourceAnomalyResult.BlockedActions) @( "select_cards", "select_all", "next_step" ) "partial source anomaly blocked actions"

  $searchAttemptFixturePath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\search-attempts\goguk2-mid-q2.json"
  $searchAttemptFixture = Get-Content -LiteralPath $searchAttemptFixturePath -Raw | ConvertFrom-MathSecrSyntheticTestJson
  $partialSourceCase = @($fixture.cases | Where-Object { $_.name -ceq "Partial" })
  if ($partialSourceCase.Count -ne 1) { throw "Search-attempt integration source fixture missing: Partial" }

  $missingSearchReceipt = $partialSourceCase[0].input | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $missingSearchReceipt.targets[2].PSObject.Properties.Remove("searchAttemptReceipt")
  $missingSearchResult = Invoke-MathSecrStateMachine $missingSearchReceipt
  Assert-Equal $missingSearchResult.State "CANDIDATE_RECOVERY" "final miss without search-attempt receipt state"
  Assert-Equal $missingSearchResult.Status "candidate-recovery-pending" "final miss without search-attempt receipt status"

  $toxicSearchCase = @($searchAttemptFixture.cases | Where-Object { $_.name -ceq "bad-common-semantic-and" })
  if ($toxicSearchCase.Count -ne 1) { throw "Search-attempt fixture missing: bad-common-semantic-and" }
  $toxicSearchInput = $partialSourceCase[0].input | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $toxicSearchPacket = $toxicSearchCase[0].packet | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $toxicSearchPacket.targetBinding.sourceProblemNumber = "3"
  $toxicSearchPacket.targetBinding.occurrenceKey = "3"
  $toxicSearchInput.targets[2].searchAttemptReceipt = $toxicSearchPacket
  $toxicSearchResult = Invoke-MathSecrStateMachine $toxicSearchInput
  Assert-Equal $toxicSearchResult.State "CANDIDATE_RECOVERY" "common semantic AND chip state"
  Assert-Equal $toxicSearchResult.Status "candidate-recovery-pending" "common semantic AND chip status"

  $goodSearchCase = @($searchAttemptFixture.cases | Where-Object { $_.name -ceq "synthetic-absence-control" })
  if ($goodSearchCase.Count -ne 1) { throw "Search-attempt fixture missing: synthetic-absence-control" }
  $goodSearchInput = $partialSourceCase[0].input | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $goodSearchPacket = $goodSearchCase[0].packet | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $goodSearchPacket.targetBinding.sourceProblemNumber = "3"
  $goodSearchPacket.targetBinding.occurrenceKey = "3"
  $goodSearchInput.targets[2].searchAttemptReceipt = $goodSearchPacket
  $goodSearchResult = Invoke-MathSecrStateMachine $goodSearchInput
  Assert-Equal $goodSearchResult.State "REPORT" "literal ladder/backoff/recovery state"
  Assert-Equal $goodSearchResult.Status "부분 완료" "literal ladder/backoff/recovery status"

  $missingWholeDbInput = $goodSearchInput | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $missingWholeDbInput.targets[2].searchAttemptReceipt.attempts = @(
    $missingWholeDbInput.targets[2].searchAttemptReceipt.attempts |
      Where-Object { $_.scope -cne "whole-db" }
  )
  $missingWholeDbResult = Invoke-MathSecrStateMachine $missingWholeDbInput
  Assert-Equal $missingWholeDbResult.State "CANDIDATE_RECOVERY" "final miss without whole-DB ladder state"
  Assert-Equal $missingWholeDbResult.Status "candidate-recovery-pending" "final miss without whole-DB ladder status"

  $wrongTargetNumberInput = $goodSearchInput | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $wrongTargetNumberInput.targets[2].searchAttemptReceipt.targetBinding.sourceProblemNumber = "2"
  $wrongTargetNumberResult = Invoke-MathSecrStateMachine $wrongTargetNumberInput
  Assert-Equal $wrongTargetNumberResult.State "CANDIDATE_RECOVERY" "wrong receipt target number state"
  Assert-Equal $wrongTargetNumberResult.Status "차단" "wrong receipt target number binding"

  $wrongOccurrenceInput = $goodSearchInput | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $wrongOccurrenceInput.targets[2].searchAttemptReceipt.targetBinding.occurrenceKey = "forged-occurrence"
  $wrongOccurrenceResult = Invoke-MathSecrStateMachine $wrongOccurrenceInput
  Assert-Equal $wrongOccurrenceResult.State "CANDIDATE_RECOVERY" "forged occurrence binding state"
  Assert-Equal $wrongOccurrenceResult.Status "차단" "forged occurrence binding aggregate"

  $knownExactCase = @($searchAttemptFixture.cases | Where-Object { $_.name -ceq "goguk2-q2-exact-found" })
  if ($knownExactCase.Count -ne 1) { throw "Search-attempt fixture missing: goguk2-q2-exact-found" }
  $knownExactInput = $partialSourceCase[0].input | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $knownExactPacket = $knownExactCase[0].packet | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $knownExactPacket.targetBinding.sourceProblemNumber = "3"
  $knownExactPacket.targetBinding.occurrenceKey = "3"
  $knownExactInput.targets[2].searchAttemptReceipt = $knownExactPacket
  $knownExactResult = Invoke-MathSecrStateMachine $knownExactInput
  Assert-Equal $knownExactResult.State "CANDIDATE_RECOVERY" "known exact coverage cannot close missed target state"
  Assert-Equal $knownExactResult.Status "exact-found" "known exact coverage cannot close missed target status"

  $zeroSourceCase = @($fixture.cases | Where-Object { $_.name -ceq "ZeroSelection" })
  if ($zeroSourceCase.Count -ne 1) { throw "Search-attempt integration source fixture missing: ZeroSelection" }
  $reusedQ2Input = $zeroSourceCase[0].input | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  foreach ($target in @($reusedQ2Input.targets)) {
    $target.searchAttemptReceipt = $knownExactCase[0].packet | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  }
  $reusedQ2Result = Invoke-MathSecrStateMachine $reusedQ2Input
  Assert-Equal $reusedQ2Result.State "CANDIDATE_RECOVERY" "same Q2 receipt reused across zero targets state"
  Assert-Equal $reusedQ2Result.Status "차단" "same Q2 receipt reused across zero targets binding"

  $forgedSearchInput = $goodSearchInput | ConvertTo-Json -Depth 40 | ConvertFrom-MathSecrSyntheticTestJson
  $forgedSearchInput.targets[2].searchAttemptReceipt.candidateRecoveryEvidence.coverage[0].inspectedIds = @("metadata-1")
  $forgedSearchResult = Invoke-MathSecrStateMachine $forgedSearchInput
  Assert-Equal $forgedSearchResult.State "CANDIDATE_RECOVERY" "forged complete-coverage aggregate state"
  Assert-Equal $forgedSearchResult.Status "candidate-recovery-pending" "forged complete-coverage aggregate status"

  foreach ($yearCase in @(
    @{ Printed = 2022; Start = 2021; End = 2023 },
    @{ Printed = 2020; Start = 2019; End = 2021 }
  )) {
    $yearInput = @($fixture.cases | Where-Object { $_.name -eq "MetadataRescueExact" })[0].input |
      ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
    $yearInput.targets[0].printedYear = $yearCase.Printed
    $yearInput.targets[0].metadataRescue.yearStart = $yearCase.Start
    $yearInput.targets[0].metadataRescue.yearEnd = $yearCase.End
    $yearInput.targets[0].metadataRescue.buckets[0].yearStart = $yearCase.Start
    $yearInput.targets[0].metadataRescue.buckets[0].yearEnd = $yearCase.End
    $yearResult = Invoke-MathSecrStateMachine $yearInput
    Assert-Equal $yearResult.State "REPORT" "metadata rescue $($yearCase.Printed) year-window state"
    Assert-Equal $yearResult.Status "완료" "metadata rescue $($yearCase.Printed) year-window status"
  }

  $idBoundaryVariants = [System.Collections.Generic.List[string]]::new()
  $idBoundaryVariants.Add(" id")
  $idBoundaryVariants.Add("id ")
  $idBoundaryVariants.Add(([string][char]9) + "id")
  $idBoundaryVariants.Add(("id" + [string][char]9))
  $idBoundaryVariants.Add(([string][char]0x00A0) + "id")
  $idBoundaryVariants.Add(("id" + [string][char]0x00A0))
  $idBoundaryVariants.Add("id,id")
  $idBoundaryVariants.Add("id`r`nfoo")
  $idBoundaryVariants.Add("없음")
  foreach ($badId in $idBoundaryVariants) {
    $targetIdInput = @($fixture.cases | Where-Object { $_.name -eq "Success" })[0].input |
      ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
    $targetIdInput.targets[0].selectedId = $badId
    $targetIdResult = Invoke-MathSecrStateMachine $targetIdInput
    Assert-Equal $targetIdResult.State "INITIAL_SEARCH" "target selectedId unsafe token '$badId' state"
    Assert-Equal $targetIdResult.Status "차단" "target selectedId unsafe token '$badId' status"

    foreach ($idBundle in @(
      @{ Name = "selection"; State = "PRE_NEXT_GATE" },
      @{ Name = "draft"; State = "EDIT_VERIFY" },
      @{ Name = "persisted"; State = "PERSIST_VERIFY" },
      @{ Name = "old"; State = "EDIT_VERIFY" }
    )) {
      $bundleInput = @($fixture.cases | Where-Object { $_.name -eq "Success" })[0].input |
        ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
      switch ($idBundle.Name) {
        "selection" { $bundleInput.selectionBeforeNextIds[0] = $badId }
        "draft" { $bundleInput.edit.draftIds[0] = $badId }
        "persisted" { $bundleInput.persistence.ids[0] = $badId }
        "old" { $bundleInput.edit.oldIds = @($badId) }
      }
      $bundleResult = Invoke-MathSecrStateMachine $bundleInput
      Assert-Equal $bundleResult.State $idBundle.State "$($idBundle.Name) unsafe ID token '$badId' state"
      Assert-Equal $bundleResult.Status "차단" "$($idBundle.Name) unsafe ID token '$badId' status"
    }
  }

  $internalIdInput = @($fixture.cases | Where-Object { $_.name -eq "Success" })[0].input |
    ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
  $internalId = "ID`t" + [string][char]0x00A0 + "Case"
  $internalIdInput.targets[0].selectedId = $internalId
  # Positive identity-compatibility case: deliberately issue new bound evidence.
  Set-MathSecrSyntheticSelectionEvidence -Target $internalIdInput.targets[0] -ProjectRoot $ProjectRoot
  $internalIdInput.selectionBeforeNextIds[0] = $internalId
  $internalIdInput.edit.draftIds[0] = $internalId
  $internalIdInput.persistence.ids[0] = $internalId
  $internalIdResult = Invoke-MathSecrStateMachine $internalIdInput
  Assert-Equal $internalIdResult.State "REPORT" "internal TAB/NBSP/case IDs state"
  Assert-Equal $internalIdResult.Status "완료" "internal TAB/NBSP/case IDs status"

  $uniqueOccurrenceBundleInput = @($fixture.cases | Where-Object { $_.name -eq "Success" })[0].input |
    ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
  $uniqueOccurrenceKeys = @($uniqueOccurrenceBundleInput.targets | ForEach-Object { [string]$_.number })
  $uniqueOccurrenceBundleInput | Add-Member -NotePropertyName selectionBeforeNextOccurrenceKeys -NotePropertyValue $uniqueOccurrenceKeys
  $uniqueOccurrenceBundleInput.edit | Add-Member -NotePropertyName draftOccurrenceKeys -NotePropertyValue $uniqueOccurrenceKeys
  $uniqueOccurrenceBundleInput.persistence | Add-Member -NotePropertyName occurrenceKeys -NotePropertyValue $uniqueOccurrenceKeys
  $uniqueOccurrenceBundleResult = Invoke-MathSecrStateMachine $uniqueOccurrenceBundleInput
  Assert-Equal $uniqueOccurrenceBundleResult.State "REPORT" "unique canonical occurrence bundles state"
  Assert-Equal $uniqueOccurrenceBundleResult.Status "완료" "unique canonical occurrence bundles status"
  Assert-Sequence @($uniqueOccurrenceBundleResult.SelectedOccurrenceKeys) $uniqueOccurrenceKeys "unique canonical selected occurrence keys"
  Assert-Sequence @($uniqueOccurrenceBundleResult.DraftOccurrenceKeys) $uniqueOccurrenceKeys "unique canonical draft occurrence keys"
  Assert-Sequence @($uniqueOccurrenceBundleResult.PersistedOccurrenceKeys) $uniqueOccurrenceKeys "unique canonical persisted occurrence keys"

  $uniqueEmptyOccurrenceBundleInput = @($fixture.cases | Where-Object { $_.name -eq "Success" })[0].input |
    ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
  $uniqueEmptyOccurrenceBundleInput | Add-Member -NotePropertyName selectionBeforeNextOccurrenceKeys -NotePropertyValue @()
  $uniqueEmptyOccurrenceBundleInput.edit | Add-Member -NotePropertyName draftOccurrenceKeys -NotePropertyValue @()
  $uniqueEmptyOccurrenceBundleInput.persistence | Add-Member -NotePropertyName occurrenceKeys -NotePropertyValue @()
  $uniqueEmptyOccurrenceBundleResult = Invoke-MathSecrStateMachine $uniqueEmptyOccurrenceBundleInput
  Assert-Equal $uniqueEmptyOccurrenceBundleResult.State "REPORT" "unique empty occurrence bundles state"
  Assert-Equal $uniqueEmptyOccurrenceBundleResult.Status "완료" "unique empty occurrence bundles status"

  $zeroOccurrenceGhostProperties = @(
    @{ Name = "selection"; Mutate = { param($candidateSnapshot) $candidateSnapshot | Add-Member -NotePropertyName selectionBeforeNextOccurrenceKeys -NotePropertyValue @("ghost") } },
    @{ Name = "draft"; Mutate = { param($candidateSnapshot) $candidateSnapshot.edit | Add-Member -NotePropertyName draftOccurrenceKeys -NotePropertyValue @("ghost") } },
    @{ Name = "persisted"; Mutate = { param($candidateSnapshot) $candidateSnapshot.persistence | Add-Member -NotePropertyName occurrenceKeys -NotePropertyValue @("ghost") } }
  )
  foreach ($ghostProperty in $zeroOccurrenceGhostProperties) {
    $zeroGhostInput = @($fixture.cases | Where-Object { $_.name -eq "ZeroSelection" })[0].input |
      ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
    & $ghostProperty.Mutate $zeroGhostInput
    $zeroGhostResult = Invoke-MathSecrStateMachine $zeroGhostInput
    Assert-Equal $zeroGhostResult.State "PRE_NEXT_GATE" "zero-selection $($ghostProperty.Name) occurrence ghost state"
    Assert-Equal $zeroGhostResult.Status "차단" "zero-selection $($ghostProperty.Name) occurrence ghost status"
    Assert-Equal @($zeroGhostResult.SelectedOccurrenceKeys).Count 0 "zero-selection $($ghostProperty.Name) selected ghost projection"
    Assert-Equal @($zeroGhostResult.DraftOccurrenceKeys).Count 0 "zero-selection $($ghostProperty.Name) draft ghost projection"
    Assert-Equal @($zeroGhostResult.PersistedOccurrenceKeys).Count 0 "zero-selection $($ghostProperty.Name) persisted ghost projection"
  }

  $canonicalOccurrenceInput = @($fixture.cases | Where-Object { $_.name -eq "DuplicateOccurrencesWithEvidence" })[0].input |
    ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
  $canonicalOccurrenceKeys = @("source page-1", "Source page-1")
  for ($index = 0; $index -lt $canonicalOccurrenceKeys.Count; $index++) {
    $canonicalOccurrenceInput.targets[$index].occurrenceKey = $canonicalOccurrenceKeys[$index]
    Set-MathSecrSyntheticSelectionEvidence -Target $canonicalOccurrenceInput.targets[$index] -ProjectRoot $ProjectRoot
  }
  $canonicalOccurrenceInput.selectionBeforeNextOccurrenceKeys = $canonicalOccurrenceKeys
  $canonicalOccurrenceInput.edit.draftOccurrenceKeys = $canonicalOccurrenceKeys
  $canonicalOccurrenceInput.persistence.occurrenceKeys = $canonicalOccurrenceKeys
  $canonicalOccurrenceResult = Invoke-MathSecrStateMachine $canonicalOccurrenceInput
  Assert-Equal $canonicalOccurrenceResult.State "REPORT" "internal whitespace/case occurrence keys state"
  Assert-Equal $canonicalOccurrenceResult.Status "완료" "internal whitespace/case occurrence keys status"
  Assert-Sequence @($canonicalOccurrenceResult.SelectedOccurrenceKeys) $canonicalOccurrenceKeys "internal whitespace/case selected occurrence keys"
  Assert-Sequence @($canonicalOccurrenceResult.DraftOccurrenceKeys) $canonicalOccurrenceKeys "internal whitespace/case draft occurrence keys"
  Assert-Sequence @($canonicalOccurrenceResult.PersistedOccurrenceKeys) $canonicalOccurrenceKeys "internal whitespace/case persisted occurrence keys"

  $ordinalIdInput = @($fixture.cases | Where-Object { $_.name -eq "DuplicateOccurrencesWithEvidence" })[0].input |
    ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
  $ordinalIdInput.targets = @($ordinalIdInput.targets) + @([pscustomobject]@{
    number = 3
    initial = "exact"
    selectedId = "DUP"
  })
  Set-MathSecrSyntheticSelectionEvidence -Target $ordinalIdInput.targets[-1] -ProjectRoot $ProjectRoot
  $ordinalIdInput.scope.resultCount = 3
  $ordinalIds = @("duplicate-target", "duplicate-target", "DUP")
  $ordinalOccurrenceKeys = @("source-page-1", "source-page-2", "3")
  $ordinalIdInput.selectionBeforeNextIds = $ordinalIds
  $ordinalIdInput.edit.draftIds = $ordinalIds
  $ordinalIdInput.persistence.ids = $ordinalIds
  $ordinalIdInput.selectionBeforeNextOccurrenceKeys = $ordinalOccurrenceKeys
  $ordinalIdInput.edit.draftOccurrenceKeys = $ordinalOccurrenceKeys
  $ordinalIdInput.persistence.occurrenceKeys = $ordinalOccurrenceKeys
  $ordinalIdResult = Invoke-MathSecrStateMachine $ordinalIdInput
  Assert-Equal $ordinalIdResult.State "REPORT" "Ordinal duplicate-ID counting state"
  Assert-Equal $ordinalIdResult.Status "완료" "Ordinal duplicate-ID counting status"
  Assert-Sequence @($ordinalIdResult.SelectedIds) $ordinalIds "Ordinal duplicate-ID selected IDs"
  Assert-Sequence @($ordinalIdResult.DraftIds) $ordinalIds "Ordinal duplicate-ID draft IDs"
  Assert-Sequence @($ordinalIdResult.PersistedIds) $ordinalIds "Ordinal duplicate-ID persisted IDs"
  Assert-Sequence @($ordinalIdResult.SelectedOccurrenceKeys) $ordinalOccurrenceKeys "Ordinal duplicate-ID selected occurrence keys"
  Assert-Sequence @($ordinalIdResult.DraftOccurrenceKeys) $ordinalOccurrenceKeys "Ordinal duplicate-ID draft occurrence keys"
  Assert-Sequence @($ordinalIdResult.PersistedOccurrenceKeys) $ordinalOccurrenceKeys "Ordinal duplicate-ID persisted occurrence keys"

  $inferenceGateAttacks = @(
    @{ Name = "selector search not cleared"; Source = "InferredScopeSuccess"; State = "SCOPE_LOCK"; Status = "inferred-scope-verification-required"; Mutate = {
      param($candidateSnapshot)
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.SelectorSearchCleared = $false
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLockReady = $false
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.ScopeIdentityMatches = $false
      $candidateSnapshot.dbInference.Results[0].Receipts.FreshSearchReceiptReady = $false
      $candidateSnapshot.dbInference.ScopeLockReady = $false
      $candidateSnapshot.dbInference.FreshSearchReceiptReady = $false
    } },
    @{ Name = "scope receipt pending after selector clear"; Source = "InferredScopeVerificationRequired"; State = "SCOPE_LOCK"; Status = "inferred-scope-verification-required"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.SelectorSearchCleared = $true } },
    @{ Name = "fresh scoped result pending"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Status = "search-receipt-required"; Mutate = {
      param($candidateSnapshot)
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.FreshResultVerified = $false
      $candidateSnapshot.dbInference.Results[0].Receipts.FreshSearchReceiptReady = $false
      $candidateSnapshot.dbInference.FreshSearchReceiptReady = $false
    } },
    @{ Name = "terminal leaf cannot satisfy breadcrumb scope lock"; Source = "InferredScopeSuccess"; State = "SCOPE_LOCK"; Status = "inferred-scope-identity-mismatch"; Mutate = {
      param($candidateSnapshot)
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.SelectedScope = "DB A"
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.ScopeIdentityMatches = $false
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLockReady = $false
      $candidateSnapshot.dbInference.Results[0].Receipts.FreshSearchReceiptReady = $false
      $candidateSnapshot.dbInference.ScopeLockReady = $false
      $candidateSnapshot.dbInference.FreshSearchReceiptReady = $false
    } },
    @{ Name = "terminal leaf cannot satisfy breadcrumb scoped search"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Status = "search-scope-identity-mismatch"; Mutate = {
      param($candidateSnapshot)
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.SelectedScope = "DB A"
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.ScopeIdentityMatches = $false
      $candidateSnapshot.dbInference.Results[0].Receipts.FreshSearchReceiptReady = $false
      $candidateSnapshot.dbInference.FreshSearchReceiptReady = $false
    } },
    @{ Name = "forged aggregate scope ready"; Source = "InferredScopeVerificationRequired"; State = "SCOPE_LOCK"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.ScopeLockReady = $true } },
    @{ Name = "forged row scope ready"; Source = "InferredScopeVerificationRequired"; State = "SCOPE_LOCK"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLockReady = $true } },
    @{ Name = "forged aggregate fresh ready"; Source = "InferenceSearchReceiptPending"; State = "INITIAL_SEARCH"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.FreshSearchReceiptReady = $true } },
    @{ Name = "forged row fresh ready"; Source = "InferenceSearchReceiptPending"; State = "INITIAL_SEARCH"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.FreshSearchReceiptReady = $true } },
    @{ Name = "forged scope identity flag"; Source = "InferredScopeSuccess"; State = "SCOPE_LOCK"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.SelectedScope = "DB A" } },
    @{ Name = "forged scoped identity flag"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.SelectedScope = "DB A" } },
    @{ Name = "false scope receipt with stale identity"; Source = "InferredScopeVerificationRequired"; State = "SCOPE_LOCK"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.SelectedScope = "교육청, 평가원" } },
    @{ Name = "partially populated idle search"; Source = "InferenceSearchReceiptPending"; State = "INITIAL_SEARCH"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.Chips = @( "조건" ) } },
    @{ Name = "idle search with stale selected scope"; Source = "InferenceSearchReceiptPending"; State = "INITIAL_SEARCH"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.SelectedScope = "교육청, 평가원" } },
    @{ Name = "fresh without submit"; Source = "InferenceSearchReceiptPending"; State = "INITIAL_SEARCH"; Status = "차단"; Mutate = { param($candidateSnapshot) $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.FreshResultVerified = $true } },
    @{ Name = "reused scoped receipt across candidates"; Source = "InferredScopeSuccess"; State = "INITIAL_SEARCH"; Status = "차단"; Mutate = {
      param($candidateSnapshot)
      $firstRow = $candidateSnapshot.dbInference.Results[0]
      $secondRow = $firstRow | ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
      $secondRow.ClusterId = "native-second"
      $secondRow.InferredScope = "교재 > 확통 > DB B"
      $secondRow.Receipts.ScopeLock.SelectedScope = "교재 > 확통 > DB B"
      $candidateSnapshot.dbInference.Results = @( $firstRow, $secondRow )
      $candidateSnapshot.dbInference.InferredScope = $null
      $candidateSnapshot.dbInference.InferredCollection = $null
      $candidateSnapshot.dbInference.Confidence = "mixed"
      $candidateSnapshot.dbInference.Reason = "per-cluster-results"
      $candidateSnapshot.dbInference.Receipts = $null
    } }
  )

  foreach ($attack in $inferenceGateAttacks) {
    $inferredSourceCase = @($fixture.cases | Where-Object { $_.name -eq $attack.Source })
    if ($inferredSourceCase.Count -ne 1) { throw "Inference gate source fixture missing: $($attack.Source)" }
    $attackInput = $inferredSourceCase[0].input | ConvertTo-Json -Depth 20 | ConvertFrom-MathSecrSyntheticTestJson
    & $attack.Mutate $attackInput
    $attackResult = Invoke-MathSecrStateMachine $attackInput
    Assert-Equal $attackResult.State $attack.State "$($attack.Name) state"
    Assert-Equal $attackResult.Status $attack.Status "$($attack.Name) gate status"
    Assert-Sequence @($attackResult.BlockedActions) @( "select_cards", "select_all", "next_step" ) "$($attack.Name) blocked actions"
  }

  $dbInferenceFixturePath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\db-inference\cases.json"
  $dbInferenceFixture = Get-Content -LiteralPath $dbInferenceFixturePath -Raw | ConvertFrom-MathSecrSyntheticTestJson
  $stateSuccessCase = @($fixture.cases | Where-Object { $_.name -ceq "Success" })
  if ($stateSuccessCase.Count -ne 1) { throw "Cross-contract state source fixture missing: Success" }
  $crossContractCases = @(
    @{ Name = "DaejinProbeConfirmedEbs"; State = "REPORT"; Status = "완료"; BlockedActions = @() },
    @{ Name = "MetadataFreeOfficialCollectionProbe"; State = "REPORT"; Status = "완료"; BlockedActions = @() },
    @{ Name = "JuyeopRepeatedOfficialMetadata"; State = "INITIAL_SEARCH"; Status = "search-receipt-required"; BlockedActions = @( "select_cards", "select_all", "next_step" ) },
    @{ Name = "MixedPacketPerClusterResults"; State = "INITIAL_SEARCH"; Status = "search-receipt-required"; BlockedActions = @( "select_cards", "select_all", "next_step" ) },
    @{ Name = "ScopedSearchReady"; State = "REPORT"; Status = "완료"; BlockedActions = @() },
    @{ Name = "EvidenceCollectionPending"; State = "DB_INFERENCE"; Status = "db-inference-required"; BlockedActions = @( "select_cards", "select_all", "next_step" ) },
    @{ Name = "MissingEvidence"; State = "DB_INFERENCE"; Status = "db-inference-unresolved"; BlockedActions = @( "select_cards", "select_all", "next_step" ) },
    @{ Name = "ScopeIdentityMismatch"; State = "SCOPE_LOCK"; Status = "inferred-scope-identity-mismatch"; BlockedActions = @( "select_cards", "select_all", "next_step" ) },
    @{ Name = "CanonicalBreadcrumbRejectsTerminalLeafReceipt"; State = "SCOPE_LOCK"; Status = "inferred-scope-identity-mismatch"; BlockedActions = @( "select_cards", "select_all", "next_step" ) }
  )
  foreach ($crossCase in $crossContractCases) {
    $resolverFixtureCase = @($dbInferenceFixture.cases | Where-Object { $_.name -ceq $crossCase.Name })
    if ($resolverFixtureCase.Count -ne 1) { throw "Cross-contract resolver fixture missing: $($crossCase.Name)" }
    $resolverOutput = & $dbInferenceModule { param($InputObject) Invoke-MathSecrDbInference $InputObject } $resolverFixtureCase[0].input
    $crossSnapshot = $stateSuccessCase[0].input | ConvertTo-Json -Depth 30 | ConvertFrom-MathSecrSyntheticTestJson
    $crossSnapshot | Add-Member -NotePropertyName dbInference -NotePropertyValue $resolverOutput
    $crossResult = Invoke-MathSecrStateMachine $crossSnapshot
    Assert-Equal $crossResult.State $crossCase.State "$($crossCase.Name) cross-contract state"
    Assert-Equal $crossResult.Status $crossCase.Status "$($crossCase.Name) cross-contract status"
    Assert-Sequence @($crossResult.BlockedActions) @($crossCase.BlockedActions) "$($crossCase.Name) cross-contract blocked actions"
  }

  $officialProbeCase = @($dbInferenceFixture.cases | Where-Object { $_.name -ceq "MetadataFreeOfficialCollectionProbe" })
  if ($officialProbeCase.Count -ne 1) { throw "Official collection resolver fixture missing: MetadataFreeOfficialCollectionProbe" }
  $officialProbeOutput = & $dbInferenceModule { param($InputObject) Invoke-MathSecrDbInference $InputObject } $officialProbeCase[0].input
  $officialProbeAttacks = @(
    @{ Name = "unsupported official collection candidate"; Mutate = {
      param($candidateSnapshot)
      $unsupported = "교육청"
      $candidateSnapshot.dbInference.InferredScope = $null
      $candidateSnapshot.dbInference.InferredCollection = $unsupported
      $candidateSnapshot.dbInference.Results[0].InferredScope = $null
      $candidateSnapshot.dbInference.Results[0].InferredCollection = $unsupported
      $candidateSnapshot.dbInference.Results[0].ScopeType = "collection"
      $candidateSnapshot.dbInference.Receipts.ScopeLock.SelectedScope = $unsupported
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.SelectedScope = $unsupported
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopeLock.ScopeIdentityMatches = $true
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.SelectedScope = $unsupported
      $candidateSnapshot.dbInference.Results[0].Receipts.ScopedSearch.ScopeIdentityMatches = $true
    } },
    @{ Name = "official collection label used as leaf candidate"; Mutate = {
      param($candidateSnapshot)
      $official = "교육청, 평가원"
      $candidateSnapshot.dbInference.InferredScope = $official
      $candidateSnapshot.dbInference.InferredCollection = $null
      $candidateSnapshot.dbInference.Results[0].InferredScope = $official
      $candidateSnapshot.dbInference.Results[0].InferredCollection = $null
      $candidateSnapshot.dbInference.Results[0].ScopeType = "leaf"
    } },
    @{ Name = "invalid official blank probe read-only"; Mutate = {
      param($candidateSnapshot)
      $candidateSnapshot.dbInference.Results[0].Receipts.BlankProbe.ReadOnly = $false
    } },
    @{ Name = "invalid official blank probe chips"; Mutate = {
      param($candidateSnapshot)
      $candidateSnapshot.dbInference.Results[0].Receipts.BlankProbe.Chips = @( "정수" )
    } },
    @{ Name = "missing official blank probe"; Mutate = {
      param($candidateSnapshot)
      $candidateSnapshot.dbInference.Results[0].Receipts.BlankProbe = $null
    } }
  )
  foreach ($attack in $officialProbeAttacks) {
    $attackInput = $stateSuccessCase[0].input | ConvertTo-Json -Depth 30 | ConvertFrom-MathSecrSyntheticTestJson
    $attackInput | Add-Member -NotePropertyName dbInference -NotePropertyValue ($officialProbeOutput | ConvertTo-Json -Depth 30 | ConvertFrom-MathSecrSyntheticTestJson)
    & $attack.Mutate $attackInput
    $attackResult = Invoke-MathSecrStateMachine $attackInput
    Assert-Equal $attackResult.State "DB_INFERENCE" "$($attack.Name) state"
    Assert-Equal $attackResult.Status "차단" "$($attack.Name) status"
    Assert-Sequence @($attackResult.BlockedActions) @( "select_cards", "select_all", "next_step" ) "$($attack.Name) blocked actions"
  }
}

Write-Host "StateMachine PASS truth_scope=offline-contract product_behavior=false"
