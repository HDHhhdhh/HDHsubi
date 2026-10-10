param(
  [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
. (Join-Path $PSScriptRoot 'state_machine.ps1')
. (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/body-comparison/synthetic_selection_test_support.ps1')

# These tests validate snapshot transitions only. The packaged renders and
# synthetic receipts are not a visual equality oracle or a live UI result.
function Copy-TestSnapshot {
  param($Value)
  return $Value | ConvertTo-Json -Depth 80 | ConvertFrom-MathSecrSyntheticTestJson
}
function Assert-Value {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -cne $Expected) { throw "$Message. Expected '$Expected', got '$Actual'" }
}
function Assert-Values {
  param($Actual, $Expected, [string]$Message)
  $actualValues = @($Actual)
  $expectedValues = @($Expected)
  Assert-Value $actualValues.Count $expectedValues.Count "$Message count"
  for ($index = 0; $index -lt $actualValues.Count; $index++) {
    Assert-Value $actualValues[$index] $expectedValues[$index] "$Message at $index"
  }
}
function Invoke-TestPhase {
  param($Snapshot, [string]$Phase = 'AfterReload')
  return Invoke-MathSecrStateMachine -Snapshot $Snapshot -ProjectRoot $ProjectRoot -Phase $Phase
}
function Set-TestBeforeNext {
  param($Snapshot)
  $Snapshot.nextClicked = $false
  $Snapshot.PSObject.Properties.Remove('edit')
  $Snapshot.PSObject.Properties.Remove('persistence')
}

$fixture = Get-Content -LiteralPath (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json') -Raw |
  ConvertFrom-MathSecrSyntheticTestJson
foreach ($fixtureCase in @($fixture.cases | Where-Object {
  $_.name -cin @('Success', 'Partial', 'MetadataRescueSourceAnomaly', 'MetadataRescueExact', 'PartialDuplicateOccurrencesWithEvidence', 'ZeroSelection')
})) {
  foreach ($target in @($fixtureCase.input.targets)) {
    Set-MathSecrSyntheticSelectionEvidence -Target $target -ProjectRoot $ProjectRoot
  }
}
$success = @($fixture.cases | Where-Object { $_.name -ceq 'Success' })[0].input
$partial = @($fixture.cases | Where-Object { $_.name -ceq 'Partial' })[0].input
$anomaly = @($fixture.cases | Where-Object { $_.name -ceq 'MetadataRescueSourceAnomaly' })[0].input.targets[0]

$beforeNext = Copy-TestSnapshot $success
Set-TestBeforeNext $beforeNext
$result = Invoke-TestPhase $beforeNext 'BeforeNext'
Assert-Value $result.State 'PRE_NEXT_GATE' 'complete selected batch phase'
Assert-Value $result.Status 'ready-for-next' 'complete selected batch ready'
Assert-Value $result.CanNextStep $true 'complete selected batch next permission'
Assert-Value $result.Phase 'BeforeNext' 'phase projection'
Assert-Values $result.SelectedSourceNumbers @('1', '2', '3') 'verified selected source numbers'
Assert-Values $result.UnresolvedSourceNumbers @() 'complete batch unresolved'
Assert-Value $result.DraftCount 0 'no invented draft count'
Assert-Value $result.PersistedCount 0 'no invented persisted count'
Assert-Value ($null -eq $beforeNext.PSObject.Properties['edit']) $true 'input edit remains absent'
Assert-Value ($null -eq $beforeNext.PSObject.Properties['persistence']) $true 'input persistence remains absent'

$mixed = Copy-TestSnapshot $success
$mixed | Add-Member -NotePropertyName requestedAction -NotePropertyValue 'partial-save'
$selected = Copy-TestSnapshot $mixed.targets[0]
$pending = [pscustomobject]@{ number = 2; initial = 'no_exact'; candidateRecovery = 'pending' }
$pendingPacket = Copy-TestSnapshot $partial.targets[2].searchAttemptReceipt
$pendingPacket.targetBinding.sourceProblemNumber = '2'
$pendingPacket.targetBinding.occurrenceKey = '2'
$pendingPacket.outcome = 'pending'
$pending | Add-Member -NotePropertyName searchAttemptReceipt -NotePropertyValue $pendingPacket
$notStarted = [pscustomobject]@{ number = 3; initial = 'not-started' }
$sourceAnomaly = Copy-TestSnapshot $anomaly
$sourceAnomaly.number = 4
$sourceAnomaly.metadataRescue.sourceAnomalyReceipt.sourceProblemNumber = '4'
$insufficient = Copy-TestSnapshot $partial.targets[2]
$insufficient.number = 5
$insufficient.searchAttemptReceipt.targetBinding.sourceProblemNumber = '5'
$insufficient.searchAttemptReceipt.targetBinding.occurrenceKey = '5'
$insufficient.searchAttemptReceipt.attempts = @($insufficient.searchAttemptReceipt.attempts | Where-Object { $_.scope -cne 'whole-db' })
$closedMiss = Copy-TestSnapshot $partial.targets[2]
$closedMiss.number = 6
$closedMiss.searchAttemptReceipt.targetBinding.sourceProblemNumber = '6'
$closedMiss.searchAttemptReceipt.targetBinding.occurrenceKey = '6'
$mixed.targets = @($selected, $pending, $notStarted, $sourceAnomaly, $insufficient, $closedMiss)
$mixed | Add-Member -NotePropertyName wholeDbScopeVerified -NotePropertyValue $true
$mixed.selectionBeforeNextIds = @($selected.selectedId)
Set-TestBeforeNext $mixed
$pendingBytesBefore = $mixed.targets[1].searchAttemptReceipt | ConvertTo-Json -Depth 80 -Compress
$result = Invoke-TestPhase $mixed 'BeforeNext'
Assert-Value $result.Status 'ready-for-next' 'explicit partial save before next'
Assert-Value $result.CanNextStep $true 'explicit partial save next permission'
Assert-Values $result.SelectedSourceNumbers @('1') 'partial selected projection'
Assert-Values $result.ClosedMissedSourceNumbers @('6') 'closure projection'
Assert-Values $result.UnresolvedSourceNumbers @('2', '3', '4', '5') 'unresolved source order'
Assert-Values @($result.UnresolvedReasons | ForEach-Object { $_.Reason }) @('candidate-recovery-pending', 'not-started', 'source-anomaly-pending', 'candidate-recovery-pending') 'unresolved reasons'
Assert-Value ($mixed.targets[1].searchAttemptReceipt | ConvertTo-Json -Depth 80 -Compress) $pendingBytesBefore 'pending raw packet preservation'
Assert-Value ($null -eq $mixed.targets[2].PSObject.Properties['searchAttemptReceipt']) $true 'not started remains without search receipt'

$afterReload = Copy-TestSnapshot $mixed
$afterReload.nextClicked = $true
$afterReload | Add-Member -NotePropertyName edit -NotePropertyValue ([pscustomobject]@{ draftIds = @($selected.selectedId); oldIds = @(); recovery = 'not_needed' })
$afterReload | Add-Member -NotePropertyName persistence -NotePropertyValue ([pscustomobject]@{ ids = @($selected.selectedId); freshReloadVerified = $true })
$result = Invoke-TestPhase $afterReload
Assert-Value $result.Status '부분 완료' 'explicit partial save after reload'
Assert-Value $result.State 'REPORT' 'partial reload report gate'
Assert-Value $result.CanNextStep $false 'reload is not a pre next permission'
Assert-Value $result.PersistedCount 1 'partial persisted selected subset'
Assert-Values $result.UnresolvedSourceNumbers @('2', '3', '4', '5') 'reload preserves unresolved rows'

$defaultBehavior = Copy-TestSnapshot $mixed
$defaultBehavior.PSObject.Properties.Remove('requestedAction')
$result = Invoke-TestPhase $defaultBehavior 'BeforeNext'
Assert-Value $result.Status 'candidate-recovery-required' 'default behavior keeps unresolved gate'
Assert-Value $result.CanNextStep $false 'default unresolved cannot advance'
$defaultBehavior.targets[0].bodyComparisonReceipt.candidateId = 'wrong'
$result = Invoke-TestPhase $defaultBehavior 'BeforeNext'
Assert-Value $result.Status 'body-comparison-receipt-invalid' 'default selected evidence is checked before pending return'

$pendingDisguisedAsMiss = Copy-TestSnapshot $mixed
$pendingDisguisedAsMiss.targets[1].candidateRecovery = 'missed'
$pendingDisguisedAsMiss.targets[1] | Add-Member -NotePropertyName wholeDb -NotePropertyValue 'missed'
$result = Invoke-TestPhase $pendingDisguisedAsMiss 'BeforeNext'
Assert-Value $result.Status 'ready-for-next' 'partial save still preserves pending miss claim'
Assert-Values $result.ClosedMissedSourceNumbers @('6') 'pending outcome cannot become closed miss'
Assert-Values $result.UnresolvedSourceNumbers @('2', '3', '4', '5') 'pending miss claim remains unresolved'

$badMetadataSelection = Copy-TestSnapshot (@($fixture.cases | Where-Object { $_.name -ceq 'MetadataRescueExact' })[0].input)
$badMetadataSelection.targets[0].selectedId = 'not-inspected'
$badMetadataSelection.targets += [pscustomobject]@{ number = 2; initial = 'no_exact'; candidateRecovery = 'pending' }
$badMetadataSelection | Add-Member -NotePropertyName requestedAction -NotePropertyValue 'partial-save'
Set-TestBeforeNext $badMetadataSelection
$result = Invoke-TestPhase $badMetadataSelection 'BeforeNext'
Assert-Value $result.Status 'metadata-rescue-receipt-invalid' 'invalid selected metadata cannot hide behind pending return'
Assert-Value $result.CanNextStep $false 'invalid selected metadata permission'

foreach ($emptySelectedId in @($null, '')) {
  $noClaim = Copy-TestSnapshot $mixed
  $noClaim.targets[1] | Add-Member -NotePropertyName selectedId -NotePropertyValue $emptySelectedId
  $noClaim.targets[2] | Add-Member -NotePropertyName selectedId -NotePropertyValue $emptySelectedId
  $noClaim.targets[3] | Add-Member -NotePropertyName selectedId -NotePropertyValue $emptySelectedId
  $noClaim.targets[5] | Add-Member -NotePropertyName selectedId -NotePropertyValue $emptySelectedId
  $result = Invoke-TestPhase $noClaim 'BeforeNext'
  Assert-Value $result.Status 'ready-for-next' 'null or empty unselected ID has no selection claim'
  Assert-Values $result.SelectedSourceNumbers @('1') 'null or empty unselected ID cannot become selected'
}
$hintControl = Copy-TestSnapshot $mixed
$hintControl.targets[1] | Add-Member -NotePropertyName candidateHintIds -NotePropertyValue @('hint-unresolved')
$result = Invoke-TestPhase $hintControl 'BeforeNext'
Assert-Value $result.Status 'ready-for-next' 'ordinary candidate hints do not claim a selection'

foreach ($invalidClaim in @('ghost-unresolved', ' ', '없음', 123, @('ghost-unresolved'))) {
  $candidate = Copy-TestSnapshot $mixed
  $candidate.targets[1] | Add-Member -NotePropertyName selectedId -NotePropertyValue $invalidClaim
  $result = Invoke-TestPhase $candidate 'BeforeNext'
  Assert-Value $result.Status '차단' 'unselected row cannot carry a selected ID claim'
  Assert-Value $result.CanNextStep $false 'unselected selected ID claim next permission'
  Assert-Values $result.EvidenceErrors @('unselected-row-carries-selected-id') 'unselected selected ID claim diagnosis'
}

foreach ($stateField in @('initial', 'candidateRecovery', 'wholeDb')) {
  foreach ($badState in @(123, @('exact'), [pscustomobject]@{ state = 'exact' }, $null, 'EXACT', ' exact', 'unsupported')) {
    $candidate = Copy-TestSnapshot $mixed
    $candidate.targets[1] | Add-Member -NotePropertyName $stateField -NotePropertyValue $badState -Force
    $result = Invoke-TestPhase $candidate 'BeforeNext'
    Assert-Value $result.Status '차단' "$stateField strict state schema"
    Assert-Value $result.CanNextStep $false "$stateField invalid state next permission"
    Assert-Values $result.EvidenceErrors @("target-row-state:$stateField") "$stateField invalid state diagnosis"
  }
}
foreach ($legalRow in @(
  @{ Target = [pscustomobject]@{ number = 1 }; Resolution = 'not_started' },
  @{ Target = [pscustomobject]@{ number = 1; initial = 'pending' }; Resolution = 'candidate_pending' },
  @{ Target = [pscustomobject]@{ number = 1; initial = 'no_exact'; candidateRecovery = 'exact'; selectedId = 'legal-candidate' }; Resolution = 'candidate_selected' },
  @{ Target = [pscustomobject]@{ number = 1; initial = 'missed'; candidateRecovery = 'missed'; wholeDb = 'exact'; selectedId = 'legal-whole' }; Resolution = 'whole_selected' }
)) {
  $rowState = Test-MathSecrTargetRowState -Target $legalRow.Target
  Assert-Value $rowState.Valid $true 'legal route state helper control'
  Assert-Value $rowState.Resolution $legalRow.Resolution 'legal derived resolution helper control'
}

$attacks = @(
  @{ Name = 'bad selected receipt before pending'; State = 'INITIAL_SEARCH'; Status = 'body-comparison-receipt-invalid'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.targets[0].bodyComparisonReceipt.candidateId = 'wrong' } },
  @{ Name = 'selected body mismatch before pending'; State = 'INITIAL_SEARCH'; Status = 'body-comparison-receipt-invalid'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.targets[0].bodyComparisonReceipt.comparison.formulas = 'mismatch' } },
  @{ Name = 'bad selected search'; State = 'INITIAL_SEARCH'; Status = 'selected-search-receipt-invalid'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.targets[0].searchAttemptReceipt.targetBinding.occurrenceKey = 'wrong' } },
  @{ Name = 'pending binding mismatch'; State = 'CANDIDATE_RECOVERY'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.targets[1].searchAttemptReceipt.targetBinding.sourceProblemNumber = '1' } },
  @{ Name = 'not started fabricated search'; State = 'INITIAL_SEARCH'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.targets[2] | Add-Member -NotePropertyName searchAttemptReceipt -NotePropertyValue ([pscustomobject]@{}) } },
  @{ Name = 'ghost unresolved selection'; State = 'PRE_NEXT_GATE'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.selectionBeforeNextIds += 'anomaly-2024' } },
  @{ Name = 'source anomaly invalid bytes'; State = 'METADATA_RESCUE'; Status = 'metadata-rescue-receipt-invalid'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.targets[3].metadataRescue.sourceAnomalyReceipt.sourceRenderSha256 = ('A' * 64) } },
  @{ Name = 'scope failure'; State = 'SCOPE_LOCK'; Status = 'scope-recovery-required'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.scope.verified = $false } },
  @{ Name = 'broad scope failure'; State = 'SCOPE_LOCK'; Status = 'scope-recovery-required'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.scope.unexpectedBroadResult = $true } },
  @{ Name = 'paper unverified'; State = 'ASIDE_REPL_READY'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.asideRepl.paperVerified = $false } },
  @{ Name = 'stale state'; State = 'CLEAN_STATE'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.cleanStateVerified = $false } },
  @{ Name = 'future next click'; State = 'PRE_NEXT_GATE'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.nextClicked = $true } },
  @{ Name = 'future edit claim'; State = 'PRE_NEXT_GATE'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate | Add-Member -NotePropertyName edit -NotePropertyValue ([pscustomobject]@{ draftIds = @('7231357'); oldIds = @(); recovery = 'not_needed' }) } },
  @{ Name = 'future persisted claim'; State = 'PRE_NEXT_GATE'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate | Add-Member -NotePropertyName persistence -NotePropertyValue ([pscustomobject]@{ ids = @('7231357'); freshReloadVerified = $true }) } },
  @{ Name = 'partial occurrence ghost'; State = 'INITIAL_SEARCH'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate | Add-Member -NotePropertyName selectionBeforeNextOccurrenceKeys -NotePropertyValue @('ghost') } },
  @{ Name = 'whole DB scope unverified'; State = 'WHOLE_DB_RETRY'; Status = '차단'; Phase = 'BeforeNext'; Mutate = { param($candidate) $candidate.wholeDbScopeVerified = $false } }
)
foreach ($attack in $attacks) {
  $candidate = Copy-TestSnapshot $mixed
  & $attack.Mutate $candidate
  $result = Invoke-TestPhase $candidate $attack.Phase
  Assert-Value $result.State $attack.State "$($attack.Name) state"
  Assert-Value $result.Status $attack.Status "$($attack.Name) status"
  Assert-Value $result.CanNextStep $false "$($attack.Name) permission"
}

foreach ($attack in @(
  @{ Name = 'stale edit'; State = 'EDIT_VERIFY'; Mutate = { param($candidate) $candidate.edit.oldIds = @('old') } },
  @{ Name = 'collapsed draft'; State = 'EDIT_VERIFY'; Mutate = { param($candidate) $candidate.edit.draftIds = @() } },
  @{ Name = 'collapsed persistence'; State = 'PERSIST_VERIFY'; Mutate = { param($candidate) $candidate.persistence.ids = @() } },
  @{ Name = 'missing reload'; State = 'PERSIST_VERIFY'; Mutate = { param($candidate) $candidate.persistence.freshReloadVerified = $false } }
)) {
  $candidate = Copy-TestSnapshot $afterReload
  & $attack.Mutate $candidate
  $result = Invoke-TestPhase $candidate
  Assert-Value $result.State $attack.State "$($attack.Name) state"
  Assert-Value $result.Status '차단' "$($attack.Name) blocks reporting"
}

$twoSelected = Copy-TestSnapshot $afterReload
$twoSelected.targets[1] = Copy-TestSnapshot $success.targets[1]
$twoSelected.selectionBeforeNextIds = @($success.targets[0].selectedId, $success.targets[1].selectedId)
$twoSelected.edit.draftIds = @($twoSelected.selectionBeforeNextIds)
$twoSelected.persistence.ids = @($twoSelected.selectionBeforeNextIds)
$result = Invoke-TestPhase $twoSelected
Assert-Value $result.Status '부분 완료' 'two selected partial batch control'
foreach ($attack in @(
  @{ Name = 'selection permutation'; State = 'PRE_NEXT_GATE'; Mutate = { param($candidate) [array]::Reverse($candidate.selectionBeforeNextIds) } },
  @{ Name = 'draft permutation'; State = 'EDIT_VERIFY'; Mutate = { param($candidate) [array]::Reverse($candidate.edit.draftIds) } },
  @{ Name = 'persisted permutation'; State = 'PERSIST_VERIFY'; Mutate = { param($candidate) [array]::Reverse($candidate.persistence.ids) } }
)) {
  $candidate = Copy-TestSnapshot $twoSelected
  & $attack.Mutate $candidate
  $result = Invoke-TestPhase $candidate
  Assert-Value $result.State $attack.State "$($attack.Name) state"
  Assert-Value $result.Status '차단' "$($attack.Name) blocks partial save reporting"
}

$duplicate = Copy-TestSnapshot (@($fixture.cases | Where-Object { $_.name -ceq 'PartialDuplicateOccurrencesWithEvidence' })[0].input)
Set-TestBeforeNext $duplicate
$result = Invoke-TestPhase $duplicate 'BeforeNext'
Assert-Value $result.Status 'ready-for-next' 'duplicate occurrence before next permission'
Assert-Values $result.SelectedOccurrenceKeys @('source-page-1', 'source-page-2') 'duplicate occurrence selected bundle'
$duplicate.occurrenceProof.DuplicateAddControlVerified = $false
$result = Invoke-TestPhase $duplicate 'BeforeNext'
Assert-Value $result.Status '차단' 'unproven duplicate control blocks before next'

$zero = Copy-TestSnapshot (@($fixture.cases | Where-Object { $_.name -ceq 'ZeroSelection' })[0].input)
$zero | Add-Member -NotePropertyName requestedAction -NotePropertyValue 'partial-save'
$result = Invoke-TestPhase $zero
Assert-Value $result.Status '검색 완료/0선택' 'all closed misses retain zero selection status'
Assert-Values $result.ClosedMissedSourceNumbers @('1', '2') 'zero selection closed misses'
$zero.targets = @([pscustomobject]@{ number = 1; initial = 'not-started' })
$result = Invoke-TestPhase $zero
Assert-Value $result.Status 'candidate-recovery-required' 'zero selection unresolved cannot complete'
Assert-Value $result.CanNextStep $false 'zero selection unresolved next permission'
Assert-Values $result.UnresolvedSourceNumbers @('1') 'zero selection unresolved projection'

Write-Host 'PartialSavePhases PASS truth_scope=offline-contract product_behavior=false'
