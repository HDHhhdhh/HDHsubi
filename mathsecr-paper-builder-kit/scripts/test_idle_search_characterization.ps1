param(
  [string]$ProjectRoot = (Get-Location).Path,
  [ValidateSet("All", "Evidence", "Red")]
  [string]$Case = "All"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -cne $Expected) {
    throw "$Message. Expected '$Expected', got '$Actual'."
  }
}

function ConvertTo-StringArray {
  param($Value)
  if ($null -eq $Value) { return @() }
  return @($Value | ForEach-Object { [string]$_ })
}

function Test-StringSequenceEqual {
  param([string[]]$Left, [string[]]$Right)
  if ($Left.Count -ne $Right.Count) { return $false }
  for ($index = 0; $index -lt $Left.Count; $index++) {
    if ($Left[$index] -cne $Right[$index]) { return $false }
  }
  return $true
}

function Copy-IdleSearchCharacterizationDocument {
  param($Document)
  return ($Document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
}

function ConvertTo-ObservedTimestamp {
  param([string]$Value, [string]$Name)
  try {
    return [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
  } catch {
    throw "$Name is not a valid timestamp: '$Value'."
  }
}

function Assert-StableExpectedSignatures {
  param($Value, [string]$Expected, [string]$Name)
  $signatures = @(ConvertTo-StringArray $Value)
  Assert-True ($signatures.Count -ge 2) "$Name requires at least two post-submit reads."
  foreach ($signature in $signatures) {
    Assert-Equal $signature $Expected "$Name signature"
  }
}

function Invoke-IdleSearchCharacterizationValidation {
  param($Document)

  Assert-Equal ([string]$Document.schemaVersion) "mathsecr-idle-search-characterization/1.0" "schemaVersion"
  Assert-True ([string]$Document.capturedOn -cmatch '^\d{4}-\d{2}-\d{2}$') "capturedOn must be an ISO date."
  Assert-Equal ([string]$Document.captureSurface) "Codex in-app Browser (iab)" "Capture surface"
  Assert-True ([bool]$Document.claimBoundary.datedObservation) "The characterization must remain date-scoped."
  Assert-Equal ([int]$Document.claimBoundary.authenticatedIabSessionCount) 1 "Authenticated IAB session count"
  Assert-Equal ([int]$Document.claimBoundary.paperCount) 1 "Observed paper count"
  Assert-Equal ([int]$Document.claimBoundary.committedQueryCount) 1 "Observed committed-query count"
  Assert-Equal ([int]$Document.claimBoundary.observedIdleTabCount) 3 "Observed idle-tab count"
  Assert-Equal ([int]$Document.claimBoundary.observedTabCount) 4 "Total observed tab count"
  Assert-True (-not [bool]$Document.claimBoundary.serviceAvailabilityContract) "The observation cannot claim a service-availability contract."
  Assert-True (-not [bool]$Document.claimBoundary.latencyContract) "The observation cannot claim a latency contract."
  Assert-True (-not [bool]$Document.claimBoundary.resultCountContract) "The observation cannot claim a result-count contract."
  Assert-True (-not [bool]$Document.claimBoundary.standardFreshReceiptClaim) "Two reads after a scope mutation cannot claim the standard fresh-search receipt."
  Assert-True (-not [bool]$Document.claimBoundary.exactOrMissDecisionClaim) "The idle observation cannot claim an exact/miss decision."
  Assert-True ([bool]$Document.claimBoundary.offlineValidationOnly) "Regression must remain frozen-fixture validation only."
  Assert-True (-not [bool]$Document.claimBoundary.regressionReplaysLiveWaits) "Regression cannot claim to replay the live idle waits."
  Assert-True ([string]$Document.paper.url -cmatch '^https://www\.mathsecr\.com/mypaper/[0-9]+$') "Paper URL must be a MathSecr mypaper URL."
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Document.paper.title)) "Paper title is required."

  $query = $Document.queryContract
  Assert-Equal ([string]$query.source) "교육청, 평가원" "Query source"
  Assert-Equal ([string]$query.sourceReceipt) "$($query.source) 제거" "Query source receipt"
  $chips = @(ConvertTo-StringArray $query.chips)
  Assert-True ($chips.Count -ge 1) "At least one committed query chip is required."
  Assert-True (@($chips | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "Committed query chips cannot be blank."
  Assert-True (@($chips | Sort-Object -Unique).Count -eq $chips.Count) "Committed query chips must be unique."
  $expectedChipReceipts = @($chips | ForEach-Object { "$_ 제거" })
  $queryChipReceipts = @(ConvertTo-StringArray $query.chipReceipts)
  Assert-True (Test-StringSequenceEqual $queryChipReceipts $expectedChipReceipts) "Query chip receipts do not match the committed chips."
  Assert-True ([string]$query.observedSignature -cmatch '^[0-9]+\|[0-9]+(?:,[0-9]+)*$') "Observed result signature is malformed."
  $signatureParts = ([string]$query.observedSignature).Split('|')
  $signatureIds = @($signatureParts[1].Split(','))
  Assert-Equal $signatureIds.Count 1 "This bounded characterization requires exactly one visible result ID"
  Assert-Equal ([string]$query.observedProblemId) $signatureIds[0] "Observed problem ID binding"
  Assert-Equal ([int]$query.idleProblemSelectionActions) 0 "Idle checkpoint problem-selection action count"

  $baselineSubmittedAt = ConvertTo-ObservedTimestamp ([string]$Document.immediateBaseline.submittedAtUtc) "Immediate baseline submittedAtUtc"
  $baselineCompletedAt = ConvertTo-ObservedTimestamp ([string]$Document.immediateBaseline.submitCompletedAtUtc) "Immediate baseline submitCompletedAtUtc"
  Assert-True ($baselineCompletedAt -ge $baselineSubmittedAt) "Immediate baseline completion precedes submission."
  Assert-StableExpectedSignatures $Document.immediateBaseline.stableSignatures ([string]$query.observedSignature) "Immediate baseline"

  $duplicate = $Document.duplicateClickProbe
  $duplicateProbeTabId = [string]$duplicate.tabId
  Assert-True (-not [string]::IsNullOrWhiteSpace($duplicateProbeTabId)) "Duplicate-probe tab ID is required."
  Assert-Equal ([string]$duplicate.problemId) ([string]$query.observedProblemId) "Duplicate-click problem ID"
  $firstClickAt = ConvertTo-ObservedTimestamp ([string]$duplicate.firstClickAtUtc) "Duplicate firstClickAtUtc"
  $secondClickAt = ConvertTo-ObservedTimestamp ([string]$duplicate.secondClickAtUtc) "Duplicate secondClickAtUtc"
  Assert-True ($firstClickAt -ge $baselineCompletedAt) "Duplicate probe starts before the immediate baseline completes."
  Assert-True ($secondClickAt -gt $firstClickAt) "Duplicate second click must follow the first click."
  Assert-True ([bool]$duplicate.afterFirstClick.checked) "The first result-card activation must select the card."
  $firstSelectedIds = @(ConvertTo-StringArray $duplicate.afterFirstClick.selectedIds)
  Assert-True (Test-StringSequenceEqual $firstSelectedIds @([string]$duplicate.problemId)) "The first activation must yield exactly one selected ID."
  Assert-True ([bool]$duplicate.afterFirstClick.nextStepVisible) "The first activation must expose the next-step control."
  Assert-True (-not [bool]$duplicate.afterSecondClick.checked) "The second activation must toggle the card off."
  Assert-Equal @(ConvertTo-StringArray $duplicate.afterSecondClick.selectedIds).Count 0 "Second-activation selected ID count"
  Assert-True (-not [bool]$duplicate.afterSecondClick.nextStepVisible) "The second activation must hide the next-step control."
  Assert-Equal ([int]$duplicate.cardActivationCount) 2 "Duplicate-probe card activation count"
  Assert-True (-not [bool]$duplicate.duplicateInsertionObserved) "Duplicate insertion must remain unobserved."

  $idleStartedAt = ConvertTo-ObservedTimestamp ([string]$Document.idleRun.startedAtUtc) "Idle run startedAtUtc"
  Assert-True ($idleStartedAt -gt $secondClickAt) "Idle run must start after the duplicate-click probe."
  $checkpoints = @($Document.idleRun.checkpoints)
  Assert-Equal $checkpoints.Count 3 "Idle checkpoint count"
  $targetMinutes = @($checkpoints | ForEach-Object { [int]$_.targetMinutes })
  Assert-True (($targetMinutes -join ',') -ceq "15,30,60") "Idle checkpoint targets must be exactly 15,30,60 in order."
  $tabIds = @($checkpoints.tabId | ForEach-Object { [string]$_ })
  Assert-True (@($tabIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "Idle checkpoint tab IDs cannot be blank."
  Assert-Equal @($tabIds | Sort-Object -Unique).Count 3 "Idle checkpoint tab IDs must be unique"
  Assert-True (-not ($tabIds -ccontains $duplicateProbeTabId)) "Duplicate probe must remain separate from the three prepared idle tabs."

  foreach ($checkpoint in $checkpoints) {
    $target = [int]$checkpoint.targetMinutes
    Assert-Equal ([string]$checkpoint.status) "completed" "Checkpoint $target status"
    Assert-Equal ([int]$checkpoint.initialState.sourceRemovals) 0 "Checkpoint $target initial source-removal count"
    Assert-Equal ([int]$checkpoint.initialState.resultCards) 0 "Checkpoint $target initial result-card count"
    Assert-Equal ([int]$checkpoint.initialState.selectedCards) 0 "Checkpoint $target initial selected-card count"
    Assert-True ([bool]$checkpoint.firstSearchInTab) "Checkpoint $target must be the first search in its tab."
    Assert-Equal ([int]$checkpoint.queryOrdinal) 1 "Checkpoint $target query ordinal"
    Assert-Equal ([int]$checkpoint.searchSubmitCount) 1 "Checkpoint $target search-submit count"

    $tabPreparedAt = ConvertTo-ObservedTimestamp ([string]$checkpoint.tabPreparedAtUtc) "Checkpoint $target tabPreparedAtUtc"
    $firstInteractionAt = ConvertTo-ObservedTimestamp ([string]$checkpoint.firstInteractionAtUtc) "Checkpoint $target firstInteractionAtUtc"
    $submittedAt = ConvertTo-ObservedTimestamp ([string]$checkpoint.submittedAtUtc) "Checkpoint $target submittedAtUtc"
    $submitCompletedAt = ConvertTo-ObservedTimestamp ([string]$checkpoint.submitCompletedAtUtc) "Checkpoint $target submitCompletedAtUtc"
    $completedAt = ConvertTo-ObservedTimestamp ([string]$checkpoint.completedAtUtc) "Checkpoint $target completedAtUtc"
    Assert-True ($tabPreparedAt -le $idleStartedAt) "Checkpoint $target tab was not prepared by the declared idle-run start."
    Assert-True ($firstInteractionAt -ge $tabPreparedAt.AddMinutes($target)) "Checkpoint $target was touched before its target tab-idle interval."
    Assert-True ($submittedAt -ge $firstInteractionAt) "Checkpoint $target submission precedes its first interaction."
    Assert-True ($submitCompletedAt -ge $submittedAt) "Checkpoint $target submit completion precedes submission."
    Assert-True ($completedAt -ge $submitCompletedAt) "Checkpoint $target completion precedes submit completion."

    $observedFirstIdle = ($firstInteractionAt - $tabPreparedAt).TotalSeconds
    $observedSubmitIdle = ($submittedAt - $tabPreparedAt).TotalSeconds
    Assert-True ([int]$checkpoint.actualIdleSecondsBeforeFirstInteraction -ge ($target * 60)) "Checkpoint $target recorded first-interaction idle duration is below target."
    Assert-True ([int]$checkpoint.actualIdleSecondsBeforeSubmit -ge [int]$checkpoint.actualIdleSecondsBeforeFirstInteraction) "Checkpoint $target submit idle duration precedes its first-interaction duration."
    Assert-True ([Math]::Abs(([double]$checkpoint.actualIdleSecondsBeforeFirstInteraction) - $observedFirstIdle) -le 1.0) "Checkpoint $target first-interaction idle receipt does not match timestamps."
    Assert-True ([Math]::Abs(([double]$checkpoint.actualIdleSecondsBeforeSubmit) - $observedSubmitIdle) -le 1.0) "Checkpoint $target submit idle receipt does not match timestamps."

    Assert-Equal ([string]$checkpoint.sourceReceipt) ([string]$query.sourceReceipt) "Checkpoint $target source receipt"
    $checkpointChipReceipts = @(ConvertTo-StringArray $checkpoint.chipReceipts)
    Assert-True (Test-StringSequenceEqual $checkpointChipReceipts $queryChipReceipts) "Checkpoint $target chip receipts do not match the query contract."
    Assert-StableExpectedSignatures $checkpoint.stableSignatures ([string]$query.observedSignature) "Checkpoint $target"
    Assert-Equal ([int]$checkpoint.selectedCardsAfter) 0 "Checkpoint $target selected-card count after search"
    Assert-True (-not [bool]$checkpoint.nextStepVisibleAfter) "Checkpoint $target unexpectedly exposed next step."
  }

  $lastCheckpointCompletedAt = ConvertTo-ObservedTimestamp ([string]$checkpoints[-1].completedAtUtc) "Last checkpoint completedAtUtc"
  Assert-True (($lastCheckpointCompletedAt - $idleStartedAt).TotalSeconds -ge 3600) "The observed idle run is shorter than one hour."
  Assert-True (-not [bool]$Document.safety.nonIabManipulation) "Live manipulation left the in-app Browser surface."
  Assert-True (-not [bool]$Document.safety.nextStepClicked) "다음 단계 must remain unclicked during idle characterization."
  Assert-True (-not [bool]$Document.safety.issueClicked) "출제하기 must remain unclicked during idle characterization."
  Assert-True (-not [bool]$Document.safety.helpOrDocsOpenedInLivePaperTab) "Help/docs must not replace the live paper tab."
}

$fixtureRelativePath = "mathsecr-paper-builder-kit/test-fixtures/search-characterization/idle-first-query-2026-07-31.json"
$evidenceRelativePath = ".omo/evidence/mathsecr_idle_search_characterization_2026-07-31.md"
$fixturePath = Join-Path $ProjectRoot ($fixtureRelativePath -replace '/', '\')
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
  throw "Missing idle search characterization fixture: $fixturePath"
}
$fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Case -cin @("All", "Evidence")) {
  Invoke-IdleSearchCharacterizationValidation $fixture
}

if ($Case -cin @("All", "Red")) {
  $redCases = @()

  $wrongSurface = Copy-IdleSearchCharacterizationDocument $fixture
  $wrongSurface.captureSurface = "Chrome"
  $redCases += @{ Name = "non-iab capture surface"; Document = $wrongSurface }

  $overclaimedAvailability = Copy-IdleSearchCharacterizationDocument $fixture
  $overclaimedAvailability.claimBoundary.serviceAvailabilityContract = $true
  $redCases += @{ Name = "overclaimed service availability"; Document = $overclaimedAvailability }

  $independentSessionClaim = Copy-IdleSearchCharacterizationDocument $fixture
  $independentSessionClaim.claimBoundary.authenticatedIabSessionCount = 3
  $redCases += @{ Name = "independent authenticated-session overclaim"; Document = $independentSessionClaim }

  $notOfflineOnly = Copy-IdleSearchCharacterizationDocument $fixture
  $notOfflineOnly.claimBoundary.offlineValidationOnly = $false
  $redCases += @{ Name = "offline-only boundary removed"; Document = $notOfflineOnly }

  $liveWaitReplayClaim = Copy-IdleSearchCharacterizationDocument $fixture
  $liveWaitReplayClaim.claimBoundary.regressionReplaysLiveWaits = $true
  $redCases += @{ Name = "live-wait replay claim"; Document = $liveWaitReplayClaim }

  $standardFreshReceiptClaim = Copy-IdleSearchCharacterizationDocument $fixture
  $standardFreshReceiptClaim.claimBoundary.standardFreshReceiptClaim = $true
  $redCases += @{ Name = "standard fresh-receipt claim"; Document = $standardFreshReceiptClaim }

  $exactMissDecisionClaim = Copy-IdleSearchCharacterizationDocument $fixture
  $exactMissDecisionClaim.claimBoundary.exactOrMissDecisionClaim = $true
  $redCases += @{ Name = "exact-or-miss decision claim"; Document = $exactMissDecisionClaim }

  $retainedSecondSelection = Copy-IdleSearchCharacterizationDocument $fixture
  $retainedSecondSelection.duplicateClickProbe.afterSecondClick.checked = $true
  $retainedSecondSelection.duplicateClickProbe.afterSecondClick.selectedIds = @( [string]$fixture.queryContract.observedProblemId )
  $redCases += @{ Name = "duplicate probe retained selection"; Document = $retainedSecondSelection }

  $duplicateInsertionClaim = Copy-IdleSearchCharacterizationDocument $fixture
  $duplicateInsertionClaim.duplicateClickProbe.duplicateInsertionObserved = $true
  $redCases += @{ Name = "duplicate insertion overclaim"; Document = $duplicateInsertionClaim }

  $missingSixtyMinuteCheckpoint = Copy-IdleSearchCharacterizationDocument $fixture
  $missingSixtyMinuteCheckpoint.idleRun.checkpoints = @($missingSixtyMinuteCheckpoint.idleRun.checkpoints | Where-Object { [int]$_.targetMinutes -ne 60 })
  $redCases += @{ Name = "missing sixty-minute checkpoint"; Document = $missingSixtyMinuteCheckpoint }

  $blankTabId = Copy-IdleSearchCharacterizationDocument $fixture
  $blankTabId.idleRun.checkpoints[1].tabId = ""
  $redCases += @{ Name = "blank idle tab ID"; Document = $blankTabId }

  $duplicateTabId = Copy-IdleSearchCharacterizationDocument $fixture
  $duplicateTabId.idleRun.checkpoints[1].tabId = [string]$duplicateTabId.idleRun.checkpoints[0].tabId
  $redCases += @{ Name = "duplicate idle tab ID"; Document = $duplicateTabId }

  $reusedProbeTab = Copy-IdleSearchCharacterizationDocument $fixture
  $reusedProbeTab.idleRun.checkpoints[0].tabId = [string]$reusedProbeTab.duplicateClickProbe.tabId
  $redCases += @{ Name = "idle tab reused duplicate-probe tab"; Document = $reusedProbeTab }

  $wrongObservedTabCount = Copy-IdleSearchCharacterizationDocument $fixture
  $wrongObservedTabCount.claimBoundary.observedTabCount = 3
  $redCases += @{ Name = "wrong total observed tab count"; Document = $wrongObservedTabCount }

  $earlySixtyMinuteCheckpoint = Copy-IdleSearchCharacterizationDocument $fixture
  $earlySixtyMinuteCheckpoint.idleRun.checkpoints[2].firstInteractionAtUtc = ([DateTimeOffset]::Parse([string]$fixture.idleRun.checkpoints[2].tabPreparedAtUtc)).AddMinutes(59).ToString("o")
  $redCases += @{ Name = "early sixty-minute interaction"; Document = $earlySixtyMinuteCheckpoint }

  $latePreparationReceipt = Copy-IdleSearchCharacterizationDocument $fixture
  $latePreparationReceipt.idleRun.checkpoints[1].tabPreparedAtUtc = ([DateTimeOffset]::Parse([string]$fixture.idleRun.startedAtUtc)).AddSeconds(1).ToString("o")
  $redCases += @{ Name = "tab prepared after idle-run start"; Document = $latePreparationReceipt }

  $forgedDuration = Copy-IdleSearchCharacterizationDocument $fixture
  $forgedDuration.idleRun.checkpoints[0].actualIdleSecondsBeforeFirstInteraction = 999999
  $redCases += @{ Name = "forged idle duration"; Document = $forgedDuration }

  $unstableSignature = Copy-IdleSearchCharacterizationDocument $fixture
  $unstableSignature.idleRun.checkpoints[1].stableSignatures[1] = "1|999999"
  $redCases += @{ Name = "unstable idle result signature"; Document = $unstableSignature }

  $missingScopeReceipt = Copy-IdleSearchCharacterizationDocument $fixture
  $missingScopeReceipt.idleRun.checkpoints[0].sourceReceipt = ""
  $redCases += @{ Name = "missing idle source receipt"; Document = $missingScopeReceipt }

  $idleSelectionAction = Copy-IdleSearchCharacterizationDocument $fixture
  $idleSelectionAction.queryContract.idleProblemSelectionActions = 1
  $redCases += @{ Name = "idle problem-selection action"; Document = $idleSelectionAction }

  $secondSubmit = Copy-IdleSearchCharacterizationDocument $fixture
  $secondSubmit.idleRun.checkpoints[1].searchSubmitCount = 2
  $redCases += @{ Name = "second submit in idle tab"; Document = $secondSubmit }

  $notFirstSearch = Copy-IdleSearchCharacterizationDocument $fixture
  $notFirstSearch.idleRun.checkpoints[1].firstSearchInTab = $false
  $redCases += @{ Name = "not first search in idle tab"; Document = $notFirstSearch }

  $nonFirstQuery = Copy-IdleSearchCharacterizationDocument $fixture
  $nonFirstQuery.idleRun.checkpoints[1].queryOrdinal = 2
  $redCases += @{ Name = "non-first query ordinal"; Document = $nonFirstQuery }

  $selectedAfterSearch = Copy-IdleSearchCharacterizationDocument $fixture
  $selectedAfterSearch.idleRun.checkpoints[2].selectedCardsAfter = 1
  $redCases += @{ Name = "selected card after idle search"; Document = $selectedAfterSearch }

  $nextStepVisible = Copy-IdleSearchCharacterizationDocument $fixture
  $nextStepVisible.idleRun.checkpoints[2].nextStepVisibleAfter = $true
  $redCases += @{ Name = "next step visible after idle search"; Document = $nextStepVisible }

  $issueClicked = Copy-IdleSearchCharacterizationDocument $fixture
  $issueClicked.safety.issueClicked = $true
  $redCases += @{ Name = "issue clicked"; Document = $issueClicked }

  $nonIabManipulation = Copy-IdleSearchCharacterizationDocument $fixture
  $nonIabManipulation.safety.nonIabManipulation = $true
  $redCases += @{ Name = "non-iab live manipulation"; Document = $nonIabManipulation }

  foreach ($redCase in $redCases) {
    $rejected = $false
    try {
      Invoke-IdleSearchCharacterizationValidation $redCase.Document
    } catch {
      $rejected = $true
    }
    Assert-True $rejected "Red case '$($redCase.Name)' unexpectedly passed."
  }
}

switch ($Case) {
  "Evidence" {
    Write-Host "IdleSearchCharacterization Evidence PASS mode=offline-frozen-evidence-validation truth_scope=dated-characterization product_contract=false fixture=$fixtureRelativePath evidence=$evidenceRelativePath checkpoints=3 targets=15,30,60 one_query_per_tab=true duplicate_toggle_off=true"
  }
  "Red" {
    Write-Host "IdleSearchCharacterization Red PASS mode=offline-frozen-evidence-validation truth_scope=dated-characterization product_contract=false fixture=$fixtureRelativePath intentional_red_cases=27"
  }
  default {
    Write-Host "IdleSearchCharacterization PASS mode=offline-frozen-evidence-validation truth_scope=dated-characterization product_contract=false fixture=$fixtureRelativePath evidence=$evidenceRelativePath checkpoints=3 targets=15,30,60 one_query_per_tab=true duplicate_toggle_off=true intentional_red_cases=27"
  }
}
