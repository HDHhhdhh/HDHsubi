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

function Get-ObservedSignature {
  param([int]$Count, [string[]]$OrderedIds)
  return "{0}|{1}" -f $Count, ($OrderedIds -join ",")
}

function Test-StringSequenceEqual {
  param([string[]]$Left, [string[]]$Right)
  if ($Left.Count -ne $Right.Count) { return $false }
  for ($index = 0; $index -lt $Left.Count; $index++) {
    if ($Left[$index] -cne $Right[$index]) { return $false }
  }
  return $true
}

function Invoke-SearchCharacterizationValidation {
  param($Document)

  $expectedGuideSha256 = "CB2C575A72CF857197C25A094226E72EBFE5898E621FF3B7C18EC6FFE8696C5F"
  Assert-Equal ([string]$Document.schemaVersion) "mathsecr-search-characterization/1.0" "schemaVersion"
  Assert-True ([string]$Document.externalGuide.role -ceq "dated characterization input, not a product contract") "External guide must remain a dated characterization, not a product contract."
  Assert-Equal ([string]$Document.externalGuide.sha256) $expectedGuideSha256 "Pinned external guide SHA-256"
  $selectedSources = @(ConvertTo-StringArray $Document.scope.selectedSources)
  Assert-Equal $selectedSources.Count 1 "Characterization selected-source count"
  Assert-Equal $selectedSources[0] "교육청, 평가원" "Characterization selected source"
  Assert-Equal ([string]$Document.scope.sourceReceipt) "$($selectedSources[0]) 제거" "Characterization source receipt"
  Assert-Equal ([int]$Document.scope.problemSelectionActions) 0 "Live characterization problem-selection action count"

  $cases = @($Document.cases)
  Assert-True ($cases.Count -ge 4) "At least four live characterization cases are required."
  $caseIds = @(ConvertTo-StringArray $cases.id)
  Assert-Equal (@($caseIds | Sort-Object -Unique).Count) $caseIds.Count "Case IDs must be unique"

  foreach ($item in $cases) {
    Assert-True ([string]$item.mode -cin @("phrase", "split_and")) "Unsupported search mode for $($item.id)."
    $chips = @(ConvertTo-StringArray $item.chips)
    Assert-True ($chips.Count -ge 1) "Every case must contain at least one committed chip."
    Assert-True (@($chips | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "Committed chips cannot be blank."
    Assert-True (@($chips | Sort-Object -Unique).Count -eq $chips.Count) "Committed chips must be unique."

    $ids = @(ConvertTo-StringArray $item.orderedVisibleIds)
    Assert-True (@($ids | Where-Object { $_ -cnotmatch '^[0-9]+$' }).Count -eq 0) "Visible problem IDs must be numeric strings."
    Assert-True (@($ids | Sort-Object -Unique).Count -eq $ids.Count) "Visible problem IDs must be unique within one snapshot."
    Assert-True ([int]$item.reportedCount -ge $ids.Count) "Reported count cannot be smaller than visible ID count."
    if ([bool]$item.completeResultSet) {
      Assert-Equal ([int]$item.reportedCount) $ids.Count "Complete result set count for $($item.id)"
    }

    $expectedSignature = Get-ObservedSignature ([int]$item.reportedCount) $ids
    $snapshots = @(ConvertTo-StringArray $item.snapshotSignatures)
    Assert-True ($snapshots.Count -ge 3) "Every live case must have at least three post-submit snapshots."
    foreach ($snapshot in $snapshots) {
      Assert-Equal $snapshot $expectedSignature "Snapshot signature for $($item.id)"
    }
  }

  $pairs = @($cases | Group-Object pairId)
  Assert-True ($pairs.Count -ge 2) "At least two phrase/split pairs are required."
  foreach ($pair in $pairs) {
    $phrase = @($pair.Group | Where-Object { $_.mode -ceq "phrase" })
    $split = @($pair.Group | Where-Object { $_.mode -ceq "split_and" })
    Assert-Equal $phrase.Count 1 "Phrase case count for pair $($pair.Name)"
    Assert-Equal $split.Count 1 "Split-AND case count for pair $($pair.Name)"
    Assert-True ([int]$phrase[0].reportedCount -le [int]$split[0].reportedCount) "Phrase search must not be broader than its observed split-AND pair."

    if ([bool]$phrase[0].completeResultSet -and [bool]$split[0].completeResultSet) {
      $splitIds = @(ConvertTo-StringArray $split[0].orderedVisibleIds)
      foreach ($phraseId in @(ConvertTo-StringArray $phrase[0].orderedVisibleIds)) {
        Assert-True ($splitIds -ccontains $phraseId) "Complete phrase result '$phraseId' is missing from split-AND result for pair $($pair.Name)."
      }
    }
  }

  $transition = $Document.freshnessTransition
  $transitionQuery = @(ConvertTo-StringArray $transition.query)
  Assert-True ($transitionQuery.Count -ge 1) "Freshness transition query must contain at least one committed chip."
  $postCases = @($cases | Where-Object {
    $_.mode -ceq "phrase" -and
    (Test-StringSequenceEqual @(ConvertTo-StringArray $_.chips) $transitionQuery)
  })
  Assert-Equal $postCases.Count 1 "Freshness transition post-submit case binding"
  $postCaseSignature = Get-ObservedSignature ([int]$postCases[0].reportedCount) @(ConvertTo-StringArray $postCases[0].orderedVisibleIds)
  Assert-Equal ([string]$transition.postSubmitFirstReadSignature) $postCaseSignature "Freshness transition first-read signature binding"

  $preCases = @($cases | Where-Object {
    $candidateSignature = Get-ObservedSignature ([int]$_.reportedCount) @(ConvertTo-StringArray $_.orderedVisibleIds)
    $candidateSignature -ceq [string]$transition.preSubmitSignature -and $_.id -cne $postCases[0].id
  })
  Assert-True ($preCases.Count -ge 1) "Freshness transition pre-submit signature must bind to an observed different query case."
  Assert-True ([string]$transition.preSubmitSignature -cne [string]$transition.postSubmitFirstReadSignature) "Freshness transition must distinguish the stale pre-submit result from the submitted result."
  Assert-Equal ([string]$transition.postSubmitFirstReadSignature) ([string]$transition.postFirstReadAfter100msDelaySignature) "First read versus read after a 100ms delay"
  Assert-Equal ([string]$transition.postFirstReadAfter100msDelaySignature) ([string]$transition.postSecondReadAfter150msDelaySignature) "Second read versus read after a further 150ms delay"
  Assert-True ([int]$transition.firstReadOffsetFromClickMs -ge 0) "Click-to-first-read latency cannot be negative."

  Assert-Equal ([int]$Document.cleanup.selectedCount) 0 "Cleanup selected count"
  Assert-Equal @($Document.cleanup.sourceRemovalControls).Count 0 "Cleanup source controls"
  Assert-Equal @($Document.cleanup.queryRemovalControls).Count 0 "Cleanup query controls"
  Assert-Equal @($Document.cleanup.resultCardIds).Count 0 "Cleanup result cards"
  Assert-Equal ([string]$Document.cleanup.resultText) "" "Cleanup result text"
  Assert-True (-not [bool]$Document.cleanup.issueClicked) "출제하기 must remain unclicked."
  Assert-True (-not [bool]$Document.cleanup.nextStepClicked) "다음 단계 must remain unclicked during characterization."
}

function Copy-SearchCharacterizationDocument {
  param($Document)
  return ($Document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
}

$fixturePath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\search-characterization\phrase-stability-2026-07-31.json"
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
  throw "Missing search characterization fixture: $fixturePath"
}
$fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Case -cin @("All", "Evidence")) {
  Invoke-SearchCharacterizationValidation $fixture
}

if ($Case -cin @("All", "Red")) {
  $redCases = @()

  $unstableThirdRead = Copy-SearchCharacterizationDocument $fixture
  $unstableThirdRead.cases[0].snapshotSignatures[2] = "1|999999"
  $redCases += @{ Name = "unstable third snapshot"; Document = $unstableThirdRead }

  $broaderPhrase = Copy-SearchCharacterizationDocument $fixture
  $broaderPhrase.cases[0].reportedCount = 9
  $broaderPhrase.cases[0].orderedVisibleIds = @( "232881", "900001", "900002", "900003", "900004", "900005", "900006", "900007", "900008" )
  $broaderPhrase.cases[0].snapshotSignatures = @(
    "9|232881,900001,900002,900003,900004,900005,900006,900007,900008",
    "9|232881,900001,900002,900003,900004,900005,900006,900007,900008",
    "9|232881,900001,900002,900003,900004,900005,900006,900007,900008"
  )
  $redCases += @{ Name = "phrase broader than split"; Document = $broaderPhrase }

  $brokenSubset = Copy-SearchCharacterizationDocument $fixture
  $brokenSubset.cases[1].orderedVisibleIds[2] = "999999"
  $brokenSubset.cases[1].snapshotSignatures = @(
    "8|224907,223898,999999,1413,230326,1133786,1054,219102",
    "8|224907,223898,999999,1413,230326,1133786,1054,219102",
    "8|224907,223898,999999,1413,230326,1133786,1054,219102"
  )
  $redCases += @{ Name = "complete phrase subset violation"; Document = $brokenSubset }

  $dirtyCleanup = Copy-SearchCharacterizationDocument $fixture
  $dirtyCleanup.cleanup.selectedCount = 1
  $redCases += @{ Name = "dirty cleanup"; Document = $dirtyCleanup }

  $wrongGuideHash = Copy-SearchCharacterizationDocument $fixture
  $wrongGuideHash.externalGuide.sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  $redCases += @{ Name = "wrong external guide hash"; Document = $wrongGuideHash }

  $missingScopeReceipt = Copy-SearchCharacterizationDocument $fixture
  $missingScopeReceipt.scope.selectedSources = @()
  $missingScopeReceipt.scope.sourceReceipt = ""
  $redCases += @{ Name = "missing selected-scope receipt"; Document = $missingScopeReceipt }

  $unlinkedFreshness = Copy-SearchCharacterizationDocument $fixture
  $unlinkedFreshness.freshnessTransition.query = @( "unlinked garbage query" )
  $redCases += @{ Name = "unlinked freshness transition"; Document = $unlinkedFreshness }

  foreach ($redCase in $redCases) {
    $rejected = $false
    try {
      Invoke-SearchCharacterizationValidation $redCase.Document
    } catch {
      $rejected = $true
    }
    Assert-True $rejected "Red case '$($redCase.Name)' unexpectedly passed."
  }
}

switch ($Case) {
  "Evidence" {
    Write-Host "SearchCharacterization Evidence PASS (4 live cases; 3-snapshot evidence; truth_scope=dated-characterization product_contract=false)"
  }
  "Red" {
    Write-Host "SearchCharacterization Red PASS (7 intentional rejection cases; truth_scope=dated-characterization product_contract=false)"
  }
  default {
    Write-Host "SearchCharacterization PASS (4 live cases; 3-snapshot evidence; 7 red cases; truth_scope=dated-characterization product_contract=false)"
  }
}
