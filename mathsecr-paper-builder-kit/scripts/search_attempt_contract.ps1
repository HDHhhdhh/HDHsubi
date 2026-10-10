# SEARCH_ATTEMPT_EXECUTABLE_SSOT
# This file is the canonical executable owner for search-attempt packet semantics.
# The kit SKILL's "Search Attempt Contract" section is the sole human-facing procedure.
. (Join-Path $PSScriptRoot 'search_observation_contract.ps1')
$script:MathSecrSearchChipProvenance = @(
  "literal-body", "literal-printed-metadata", "literal-visible-ui-metadata",
  "formula", "semantic-inference", "verified-index-term"
)
$script:MathSecrSearchAttemptScopes = @("initial-scope", "candidate-recovery", "whole-db")
$script:MathSecrSearchAttemptPhases = @("initial", "refinement", "backoff")
$script:MathSecrCandidateRecoveryRoutes = @(
  "same-source-inventory", "metadata-id-run", "source-paper-selector", "previous-candidate-map"
)

function Test-MathSecrSearchStrictBoolean {
  param($Value)
  return $Value -is [bool]
}

function Test-MathSecrSearchStrictInteger {
  param($Value)
  if ($null -eq $Value -or $Value -is [bool]) { return $false }
  if ($Value -is [uint64] -and $Value -gt [uint64][int64]::MaxValue) { return $false }
  return $Value -is [byte] -or $Value -is [sbyte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64] -or $Value -is [uint64]
}

function Test-MathSecrSearchNonblankString {
  param($Value)
  return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value) -and
    $Value -ceq $Value.Trim() -and -not [regex]::IsMatch($Value, '[\r\n]')
}

function Test-MathSecrSearchContainsWhitespace {
  param($Value)
  if ($Value -isnot [string]) { return $false }
  foreach ($character in $Value.ToCharArray()) {
    if ([System.Char]::IsWhiteSpace($character)) { return $true }
  }
  return $false
}

function ConvertTo-MathSecrSearchNormalizedClueText {
  param([string]$Value)
  $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
  return [regex]::Replace($normalized, '\s+', ' ')
}

function Test-MathSecrSearchKoreanClueText {
  param($Value)
  if (-not (Test-MathSecrSearchNonblankString $Value)) { return $false }
  $normalized = ConvertTo-MathSecrSearchNormalizedClueText ([string]$Value)
  return [regex]::IsMatch($normalized, '[가-힣]') -and
    -not [regex]::IsMatch($normalized, '[\p{P}\p{S}]')
}

function Test-MathSecrSearchSingleBodyWord {
  param($Value)
  if (-not (Test-MathSecrSearchKoreanClueText $Value)) { return $false }
  if (Test-MathSecrSearchContainsWhitespace $Value) { return $false }
  $normalized = ConvertTo-MathSecrSearchNormalizedClueText ([string]$Value)
  if (-not [regex]::IsMatch($normalized, '^(?:[0-9A-Za-z]+)?[가-힣]+$')) { return $false }
  if ($normalized.Length -gt 6) { return $false }
  return -not [regex]::IsMatch(
    $normalized,
    '^(모든|어떤|임의의|각각의)|(이아닌|가아닌|에대하여|라고할|이라할|라하면|이라하면|을만족|를만족)|(그러면|일때|할때|인경우|하는경우|구하여|구하시오|이다|한다|된다|같다)$'
  )
}

function Test-MathSecrSearchShortBodyClue {
  param($Value)
  if (-not (Test-MathSecrSearchKoreanClueText $Value)) { return $false }
  $tokens = @((ConvertTo-MathSecrSearchNormalizedClueText ([string]$Value)) -split ' ')
  return $tokens.Count -ge 1 -and $tokens.Count -le 2 -and
    @($tokens | Where-Object { -not (Test-MathSecrSearchSingleBodyWord $_) }).Count -eq 0
}

function Test-MathSecrSearchPhrasePrepassClue {
  param($Value)
  if (-not (Test-MathSecrSearchKoreanClueText $Value)) { return $false }
  return (Test-MathSecrSearchContainsWhitespace $Value)
}

function Test-MathSecrSearchCanonicalToken {
  param($Value)
  return (Test-MathSecrSearchNonblankString $Value) -and $Value -cne "없음" -and
    -not [regex]::IsMatch($Value, '[,\r\n]') -and
    -not [regex]::IsMatch($Value, '^[ \t\u00A0]|[ \t\u00A0]$')
}

function ConvertTo-MathSecrSearchNormalizedChip {
  param([string]$Value)
  $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
  $normalized = [regex]::Replace($normalized, '\s+', ' ')
  return $normalized.ToLowerInvariant()
}

function Test-MathSecrSearchRequiredProperties {
  param($Value, [string[]]$Names)
  if ($Value -isnot [pscustomobject]) { return $false }
  foreach ($name in $Names) {
    if ($null -eq $Value.PSObject.Properties[$name]) { return $false }
  }
  return $true
}

function Test-MathSecrSearchOrderedEqual {
  param($Left, $Right)
  $leftItems = @(if ($null -ne $Left) { @($Left) })
  $rightItems = @(if ($null -ne $Right) { @($Right) })
  if ($leftItems.Count -ne $rightItems.Count) { return $false }
  for ($index = 0; $index -lt $leftItems.Count; $index++) {
    if ([string]$leftItems[$index] -cne [string]$rightItems[$index]) { return $false }
  }
  return $true
}

function Test-MathSecrSearchStrictStringArray {
  param($Value, [bool]$CanonicalTokens = $false)
  if ($Value -isnot [System.Array]) { return $false }
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($item in @($Value)) {
    $valid = if ($CanonicalTokens) { Test-MathSecrSearchCanonicalToken $item } else { Test-MathSecrSearchNonblankString $item }
    if (-not $valid -or -not $seen.Add([string]$item)) { return $false }
  }
  return $true
}

function Get-MathSecrSearchChipValues {
  param($Attempt)
  return @($Attempt.chips | ForEach-Object { [string]$_.value })
}

function Test-MathSecrSearchChipIsUnverified {
  param($Chip)
  if ($Chip.provenance -ceq "semantic-inference") { return $true }
  if ($Chip.provenance -ceq "formula") {
    $commitReceipt = $Chip.PSObject.Properties['formulaCommitReceipt']
    $indexReceipt = $Chip.PSObject.Properties['indexEvidenceReceipt']
    return $null -eq $commitReceipt -or -not (Test-MathSecrSearchNonblankString $commitReceipt.Value) -or
      $null -eq $indexReceipt -or -not (Test-MathSecrSearchNonblankString $indexReceipt.Value)
  }
  if ($Chip.provenance -in @("literal-visible-ui-metadata", "verified-index-term")) {
    $indexReceipt = $Chip.PSObject.Properties['indexEvidenceReceipt']
    return $null -eq $indexReceipt -or -not (Test-MathSecrSearchNonblankString $indexReceipt.Value)
  }
  return $false
}

function Test-MathSecrSearchCoverageRow {
  param($CoverageRow)
  if (-not (Test-MathSecrSearchRequiredProperties $CoverageRow @(
    "route", "receipt", "reportedResultCount", "inspectedIds", "exactMatchIds", "endReadSnapshots"
  ))) { return [pscustomobject]@{ Valid = $false; ExactMatchIds = @() } }
  if (
    -not (Test-MathSecrSearchNonblankString $CoverageRow.route) -or
    -not (Test-MathSecrSearchNonblankString $CoverageRow.receipt) -or
    -not (Test-MathSecrSearchStrictInteger $CoverageRow.reportedResultCount) -or
    [int64]$CoverageRow.reportedResultCount -lt 0 -or
    -not (Test-MathSecrSearchStrictStringArray $CoverageRow.inspectedIds $true) -or
    -not (Test-MathSecrSearchStrictStringArray $CoverageRow.exactMatchIds $true) -or
    $CoverageRow.endReadSnapshots -isnot [System.Array] -or @($CoverageRow.endReadSnapshots).Count -lt 3
  ) { return [pscustomobject]@{ Valid = $false; ExactMatchIds = @() } }

  $inspectedIds = @($CoverageRow.inspectedIds)
  $exactMatchIds = @($CoverageRow.exactMatchIds)
  if ($inspectedIds.Count -ne [int64]$CoverageRow.reportedResultCount) {
    return [pscustomobject]@{ Valid = $false; ExactMatchIds = @() }
  }
  $inspectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($inspectedId in $inspectedIds) { [void]$inspectedSet.Add([string]$inspectedId) }
  foreach ($exactMatchId in $exactMatchIds) {
    if (-not $inspectedSet.Contains([string]$exactMatchId)) {
      return [pscustomobject]@{ Valid = $false; ExactMatchIds = @() }
    }
  }

  $snapshots = @($CoverageRow.endReadSnapshots)
  foreach ($snapshot in $snapshots) {
    if (-not (Test-MathSecrSearchStrictStringArray $snapshot $true)) {
      return [pscustomobject]@{ Valid = $false; ExactMatchIds = @() }
    }
  }
  $last = @($snapshots[-1])
  if (
    -not (Test-MathSecrSearchOrderedEqual $inspectedIds $last) -or
    -not (Test-MathSecrSearchOrderedEqual $snapshots[-2] $last) -or
    -not (Test-MathSecrSearchOrderedEqual $snapshots[-3] $last)
  ) { return [pscustomobject]@{ Valid = $false; ExactMatchIds = @() } }
  return [pscustomobject]@{ Valid = $true; ExactMatchIds = @($exactMatchIds) }
}

function Test-MathSecrSearchScopeLadder {
  param([string]$Scope, [object[]]$Attempts, [object]$PriorAttempt)
  $errors = [System.Collections.Generic.List[string]]::new()
  if ($Attempts.Count -eq 0) {
    return [pscustomobject]@{
      Scope = $Scope; Valid = $false; LiteralStart = $false; ResetBackoffSatisfied = $false
      ScanReady = $false; ExactFound = $false; Errors = @("missing-scope-ladder:$Scope")
    }
  }

  $baseAttempt = $Attempts[0]
  $baseValues = @(Get-MathSecrSearchChipValues $baseAttempt)
  $expectedPriorRemoval = if ($null -eq $PriorAttempt) { @() } else { @(Get-MathSecrSearchChipValues $PriorAttempt) }
  $actualPriorRemoval = @($baseAttempt.removedChips | ForEach-Object { [string]$_.value })
  $wordGranularity = $baseValues.Count -eq 2 -and
    @($baseAttempt.chips | Where-Object {
      -not (Test-MathSecrSearchSingleBodyWord $_.value)
    }).Count -eq 0
  $literalStart = $baseAttempt.phase -ceq "initial" -and $baseAttempt.resetBefore -eq $true -and
    (Test-MathSecrSearchNonblankString $baseAttempt.clearReceipt) -and
    (Test-MathSecrSearchOrderedEqual $actualPriorRemoval $expectedPriorRemoval) -and
    $baseValues.Count -eq 2 -and
    $wordGranularity -and
    @($baseAttempt.chips | Where-Object { $_.provenance -cne "literal-body" }).Count -eq 0
  $valid = $literalStart
  if (-not $literalStart) { $errors.Add("invalid-literal-start:$Scope") }
  if ($baseValues.Count -eq 2 -and -not $wordGranularity) {
    $errors.Add("invalid-literal-start-word-granularity:$Scope")
  }
  $scanReady = [int64]$baseAttempt.resultCount -le 100
  $exactFound = [bool]$baseAttempt.exactFound
  $sawRefinement = $false
  $validBackoff = $false
  $exactRefinement = $false
  $pendingSemanticDetour = $false
  $semanticDetourAttemptIds = [System.Collections.Generic.List[string]]::new()
  $previousAttempt = $baseAttempt

  for ($index = 1; $index -lt $Attempts.Count; $index++) {
    $attempt = $Attempts[$index]
    if ($attempt.phase -ceq "refinement") {
      if ($validBackoff) { $valid = $false; $errors.Add("refinement-after-backoff:$($attempt.attemptId)") }
      $sawRefinement = $true
      $previousValues = @(Get-MathSecrSearchChipValues $previousAttempt)
      $currentValues = @(Get-MathSecrSearchChipValues $attempt)
      $prefixMatches = $currentValues.Count -eq ($previousValues.Count + 1)
      if ($prefixMatches) {
        for ($chipIndex = 0; $chipIndex -lt $previousValues.Count; $chipIndex++) {
          if ($currentValues[$chipIndex] -cne $previousValues[$chipIndex]) { $prefixMatches = $false; break }
        }
      }
      $addedChip = if ($currentValues.Count -gt 0) { $attempt.chips[-1] } else { $null }
      $semanticDetour = $null -ne $addedChip -and $addedChip.provenance -ceq "semantic-inference"
      $addedChipAllowed = $null -ne $addedChip -and
        $addedChip.provenance -in @(
          "literal-body", "literal-printed-metadata", "literal-visible-ui-metadata", "formula", "verified-index-term"
        ) -and -not (Test-MathSecrSearchChipIsUnverified $addedChip)
      $bodyClueGranularity = $null -eq $addedChip -or $addedChip.provenance -cne "literal-body" -or
        (Test-MathSecrSearchShortBodyClue $addedChip.value)
      if (
        [int64]$previousAttempt.resultCount -le 100 -or -not $prefixMatches -or
        (-not $addedChipAllowed -and -not $semanticDetour) -or
        -not $bodyClueGranularity -or
        $pendingSemanticDetour -or
        $attempt.resetBefore -or @($attempt.removedChips).Count -ne 0
      ) { $valid = $false; $errors.Add("invalid-refinement:$($attempt.attemptId)") }
      if (-not $bodyClueGranularity) {
        $errors.Add("invalid-refinement-body-clue:$($attempt.attemptId)")
      }
      if ($semanticDetour) {
        $semanticDetourAttemptIds.Add([string]$attempt.attemptId)
        $pendingSemanticDetour = $true
        if ($attempt.exactFound) { $valid = $false; $errors.Add("semantic-detour-cannot-prove-exact:$($attempt.attemptId)") }
      } else {
        if ([int64]$attempt.resultCount -le 100) { $scanReady = $true }
        if ($attempt.exactFound) { $exactFound = $true; $exactRefinement = $true }
      }
      $previousAttempt = $attempt
      continue
    }

    if ($attempt.phase -ceq "backoff") {
      if ($index -ne ($Attempts.Count - 1)) { $valid = $false; $errors.Add("backoff-not-final:$($attempt.attemptId)") }
      $backoffValues = @(Get-MathSecrSearchChipValues $attempt)
      $requiredRemoved = @((Get-MathSecrSearchChipValues $previousAttempt) | Where-Object { $_ -cnotin $baseValues })
      $actualRemoved = @($attempt.removedChips | ForEach-Object { [string]$_.value })
      $validBackoff = $sawRefinement -and (Test-MathSecrSearchOrderedEqual $backoffValues $baseValues) -and
        @($attempt.chips | Where-Object { $_.provenance -cne "literal-body" }).Count -eq 0 -and
        $attempt.resetBefore -eq $true -and (Test-MathSecrSearchNonblankString $attempt.clearReceipt) -and
        (Test-MathSecrSearchOrderedEqual $actualRemoved $requiredRemoved)
      if (-not $validBackoff) { $valid = $false; $errors.Add("invalid-backoff:$($attempt.attemptId)") }
      if ($validBackoff) { $pendingSemanticDetour = $false }
      if ([int64]$attempt.resultCount -le 100) { $scanReady = $true }
      if ($attempt.exactFound) { $exactFound = $true }
      $previousAttempt = $attempt
      continue
    }

    $valid = $false
    $errors.Add("invalid-phase-sequence:$($attempt.attemptId)")
    $previousAttempt = $attempt
  }

  $resetBackoffSatisfied = -not $sawRefinement -or $exactRefinement -or $validBackoff
  if ($pendingSemanticDetour) { $valid = $false; $errors.Add("semantic-detour-not-cleared:$Scope") }
  if (-not $resetBackoffSatisfied) { $valid = $false; $errors.Add("missing-backoff:$Scope") }
  return [pscustomobject]@{
    Scope = $Scope; Valid = [bool]$valid; LiteralStart = [bool]$literalStart
    ResetBackoffSatisfied = [bool]$resetBackoffSatisfied; ScanReady = [bool]$scanReady
    ExactFound = [bool]$exactFound; SemanticDetourAttemptIds = @($semanticDetourAttemptIds)
    Errors = @($errors)
  }
}

function New-MathSecrSearchContractInvalidResult {
  param($Errors, $AttemptSummaries, $TargetBinding)
  return [pscustomobject]@{
    SchemaValid = $false; ClaimsValid = $false; CanCloseMiss = $false
    Status = "candidate-recovery-pending"; TargetBinding = $TargetBinding; ExactMatchIds = @()
    CommonChips = @(); CommonUnverifiedChips = @(); LiteralOnlyLadderCompleted = $false
    ResetBackoffPerformed = $false; CandidateRecoveryCompleted = $false
    CompleteCoverageVerified = $false; AttemptSummaries = @($AttemptSummaries)
    ScopeLadders = @(); Errors = @($Errors)
  }
}

function Test-MathSecrSearchAttemptContract {
  [CmdletBinding()]
  param([pscustomobject]$Packet)

  $errors = [System.Collections.Generic.List[string]]::new()
  $schemaValid = $true
  $policyValid = $true
  $attemptSummaries = [System.Collections.Generic.List[object]]::new()
  $targetBinding = $null

  if (-not (Test-MathSecrSearchRequiredProperties $Packet @(
    "targetBinding", "outcome", "literalEvidence", "attempts", "candidateRecoveryEvidence",
    "commonChips", "exactMatchIds", "literalOnlyLadderCompleted", "resetBackoffPerformed",
    "candidateRecoveryCompleted", "completeCoverageVerified"
  ))) { $schemaValid = $false; $errors.Add("packet-required-properties") }

  $bindingProperty = if ($Packet -is [pscustomobject]) { $Packet.PSObject.Properties['targetBinding'] } else { $null }
  if (
    $null -eq $bindingProperty -or
    -not (Test-MathSecrSearchRequiredProperties $bindingProperty.Value @("sourceProblemNumber", "occurrenceKey")) -or
    -not (Test-MathSecrSearchCanonicalToken $bindingProperty.Value.sourceProblemNumber) -or
    -not (Test-MathSecrSearchCanonicalToken $bindingProperty.Value.occurrenceKey)
  ) { $schemaValid = $false; $errors.Add("target-binding-shape") } else {
    $targetBinding = [pscustomobject]@{
      SourceProblemNumber = [string]$bindingProperty.Value.sourceProblemNumber
      OccurrenceKey = [string]$bindingProperty.Value.occurrenceKey
    }
  }

  $attempts = @(if ($schemaValid -and $Packet.attempts -is [System.Array]) { @($Packet.attempts) } else { @() })
  if (
    -not $schemaValid -or $Packet.outcome -isnot [string] -or
    $Packet.outcome -cnotin @("missed", "exact", "pending") -or
    $Packet.attempts -isnot [System.Array] -or $attempts.Count -eq 0
  ) { $schemaValid = $false; $errors.Add("packet-shape") }

  $literalEvidenceSets = @{}
  $literalEvidenceProperty = if ($Packet -is [pscustomobject]) { $Packet.PSObject.Properties['literalEvidence'] } else { $null }
  if (
    $null -eq $literalEvidenceProperty -or
    -not (Test-MathSecrSearchRequiredProperties $literalEvidenceProperty.Value @(
      "body", "printedMetadata", "visibleUiMetadata", "formula"
    ))
  ) { $schemaValid = $false; $errors.Add("literal-evidence-shape") } else {
    foreach ($evidenceKind in @("body", "printedMetadata", "visibleUiMetadata", "formula")) {
      $values = $literalEvidenceProperty.Value.$evidenceKind
      if (-not (Test-MathSecrSearchStrictStringArray $values)) {
        $schemaValid = $false; $errors.Add("literal-evidence-values:$evidenceKind"); continue
      }
      $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
      foreach ($value in @($values)) {
        if (-not $set.Add((ConvertTo-MathSecrSearchNormalizedChip $value))) {
          $schemaValid = $false; $errors.Add("literal-evidence-duplicate:$evidenceKind")
        }
      }
      $literalEvidenceSets[$evidenceKind] = $set
    }
  }

  $attemptIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $attemptExactIds = [System.Collections.Generic.List[string]]::new()
  foreach ($attempt in $attempts) {
    if (-not (Test-MathSecrSearchRequiredProperties $attempt @(
      "attemptId", "scope", "phase", "chips", "submitted", "freshResultVerified",
      "resultCount", "exactFound", "resetBefore", "clearReceipt", "removedChips"
    ))) { $schemaValid = $false; $errors.Add("attempt-required-properties"); continue }
    if (
      -not (Test-MathSecrSearchCanonicalToken $attempt.attemptId) -or -not $attemptIds.Add([string]$attempt.attemptId) -or
      $attempt.scope -isnot [string] -or $attempt.scope -cnotin $script:MathSecrSearchAttemptScopes -or
      $attempt.phase -isnot [string] -or $attempt.phase -cnotin $script:MathSecrSearchAttemptPhases -or
      $attempt.chips -isnot [System.Array] -or @($attempt.chips).Count -eq 0 -or
      -not (Test-MathSecrSearchStrictBoolean $attempt.submitted) -or
      -not (Test-MathSecrSearchStrictBoolean $attempt.freshResultVerified) -or
      -not (Test-MathSecrSearchStrictInteger $attempt.resultCount) -or [int64]$attempt.resultCount -lt 0 -or
      -not (Test-MathSecrSearchStrictBoolean $attempt.exactFound) -or
      -not (Test-MathSecrSearchStrictBoolean $attempt.resetBefore) -or
      $attempt.clearReceipt -isnot [string] -or $attempt.removedChips -isnot [System.Array]
    ) { $schemaValid = $false; $errors.Add("attempt-shape:$($attempt.attemptId)"); continue }
    if (
      -not $attempt.submitted -or -not $attempt.freshResultVerified -or
      ($attempt.resetBefore -and -not (Test-MathSecrSearchNonblankString $attempt.clearReceipt)) -or
      (-not $attempt.resetBefore -and $attempt.clearReceipt -cne "")
    ) { $policyValid = $false; $errors.Add("attempt-freshness-or-reset:$($attempt.attemptId)") }

    # Guard chip property access before projecting it into the typed capture
    # validator; malformed JSON must return invalid even under StrictMode.
    if (@($attempt.chips | Where-Object {
      -not (Test-MathSecrSearchRequiredProperties $_ @('value', 'provenance', 'evidenceReceipt'))
    }).Count -gt 0) {
      $schemaValid = $false; $errors.Add("chip-required-properties:$($attempt.attemptId)"); continue
    }

    # New capture packets derive freshness and the report projection from one
    # read sequence. Historical packets remain readable, but state selection
    # requires this packet on the exact-producing attempt.
    $observation = $null
    $observationProperty = $attempt.PSObject.Properties['observationReceipt']
    if ($null -ne $observationProperty) {
      $observation = Test-MathSecrSearchObservation -Packet $observationProperty.Value `
        -AttemptId $attempt.attemptId -Chips @($attempt.chips | ForEach-Object { $_.value }) -ResultCount $attempt.resultCount
      if (-not $observation.FreshResultVerified) {
        $policyValid = $false; $errors.Add("attempt-observation-invalid:$($attempt.attemptId)")
      } else {
        for ($chipIndex = 0; $chipIndex -lt @($attempt.chips).Count; $chipIndex++) {
          $expectedKind = if ($attempt.chips[$chipIndex].provenance -ceq 'formula') { 'formula' } else { 'text' }
          if ($observationProperty.Value.submission.criteria.chips[$chipIndex].kind -cne $expectedKind) {
            $policyValid = $false; $errors.Add("attempt-observed-chip-kind:$($attempt.attemptId)")
          }
        }
        if ($attempt.scope -ceq 'whole-db' -and $observation.Projection.ScopeMode -cne '전체 DB') {
          $policyValid = $false; $errors.Add("attempt-whole-db-mode-not-observed:$($attempt.attemptId)")
        }
      }
    }
    $inspectedProperty = $attempt.PSObject.Properties['inspectedIds']
    $exactIdsProperty = $attempt.PSObject.Properties['exactMatchIds']
    if ($null -ne $inspectedProperty -or $null -ne $exactIdsProperty) {
      if ($null -eq $inspectedProperty -or $null -eq $exactIdsProperty -or
          -not (Test-MathSecrSearchStrictStringArray $inspectedProperty.Value $true) -or
          -not (Test-MathSecrSearchStrictStringArray $exactIdsProperty.Value $true) -or
          @($inspectedProperty.Value).Count -gt [int64]$attempt.resultCount -or
          [bool]$attempt.exactFound -ne (@($exactIdsProperty.Value).Count -gt 0)) {
        $schemaValid = $false; $errors.Add("attempt-inspection-shape:$($attempt.attemptId)")
      } else {
        foreach ($exactId in @($exactIdsProperty.Value)) {
          if (@($inspectedProperty.Value) -cnotcontains $exactId) {
            $policyValid = $false; $errors.Add("attempt-exact-not-inspected:$($attempt.attemptId)")
          } else { $attemptExactIds.Add($exactId) }
        }
      }
    }

    $chipNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $orderedValues = [System.Collections.Generic.List[string]]::new()
    $orderedProvenance = [System.Collections.Generic.List[string]]::new()
    foreach ($chip in @($attempt.chips)) {
      if (-not (Test-MathSecrSearchRequiredProperties $chip @("value", "provenance", "evidenceReceipt"))) {
        $schemaValid = $false; $errors.Add("chip-required-properties:$($attempt.attemptId)"); continue
      }
      if (
        -not (Test-MathSecrSearchNonblankString $chip.value) -or
        -not (Test-MathSecrSearchNonblankString $chip.evidenceReceipt) -or
        $chip.provenance -isnot [string] -or $chip.provenance -cnotin $script:MathSecrSearchChipProvenance
      ) { $schemaValid = $false; $errors.Add("chip-shape:$($attempt.attemptId)"); continue }
      $normalizedChip = ConvertTo-MathSecrSearchNormalizedChip $chip.value
      if (-not $chipNames.Add($normalizedChip)) { $schemaValid = $false; $errors.Add("chip-duplicate:$($attempt.attemptId):$($chip.value)") }
      $orderedValues.Add([string]$chip.value)
      $orderedProvenance.Add([string]$chip.provenance)
      $evidenceKind = switch ($chip.provenance) {
        "literal-body" { "body" }; "literal-printed-metadata" { "printedMetadata" }
        "literal-visible-ui-metadata" { "visibleUiMetadata" }; "formula" { "formula" }; default { $null }
      }
      if (
        $null -ne $evidenceKind -and
        (-not $literalEvidenceSets.ContainsKey($evidenceKind) -or -not $literalEvidenceSets[$evidenceKind].Contains($normalizedChip))
      ) { $policyValid = $false; $errors.Add("provenance-evidence-mismatch:$($attempt.attemptId):$($chip.value)") }
      if (Test-MathSecrSearchChipIsUnverified $chip) {
        if ($chip.provenance -cne "semantic-inference") {
          $policyValid = $false; $errors.Add("unverified-and-chip:$($attempt.attemptId):$($chip.value)")
        }
      }
    }

    $removedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($removedChip in @($attempt.removedChips)) {
      if (
        -not (Test-MathSecrSearchRequiredProperties $removedChip @("value", "removalReceipt")) -or
        -not (Test-MathSecrSearchNonblankString $removedChip.value) -or
        -not (Test-MathSecrSearchNonblankString $removedChip.removalReceipt)
      ) { $schemaValid = $false; $errors.Add("removal-receipt-shape:$($attempt.attemptId)"); continue }
      if (-not $removedNames.Add((ConvertTo-MathSecrSearchNormalizedChip $removedChip.value))) {
        $schemaValid = $false; $errors.Add("removal-receipt-duplicate:$($attempt.attemptId):$($removedChip.value)")
      }
    }

    $attemptSummaries.Add([pscustomobject]@{
      AttemptId = [string]$attempt.attemptId; Scope = [string]$attempt.scope; Phase = [string]$attempt.phase
      AttemptKind = "proof"
      OrderedChips = @($orderedValues); OrderedProvenance = @($orderedProvenance)
      ResultCount = [int64]$attempt.resultCount; ExactFound = [bool]$attempt.exactFound
      ResetBefore = [bool]$attempt.resetBefore
      SearchObservation = if ($null -ne $observation -and $observation.FreshResultVerified) { $observation.Projection } else { $null }
    })
  }

  $phrasePrepassProperty = if ($Packet -is [pscustomobject]) {
    $Packet.PSObject.Properties['phrasePrepass']
  } else {
    $null
  }
  if ($null -ne $phrasePrepassProperty) {
    $phrasePrepass = $phrasePrepassProperty.Value
    if (
      -not (Test-MathSecrSearchRequiredProperties $phrasePrepass @(
        "attemptId", "scope", "chip", "submitted", "freshResultVerified", "resultCount",
        "exactFound", "resetBefore", "clearReceipt", "removedChips", "followedByAttemptId"
      )) -or
      -not (Test-MathSecrSearchRequiredProperties $phrasePrepass.chip @(
        "value", "provenance", "evidenceReceipt"
      )) -or
      -not (Test-MathSecrSearchCanonicalToken $phrasePrepass.attemptId) -or
      -not (Test-MathSecrSearchCanonicalToken $phrasePrepass.followedByAttemptId) -or
      $phrasePrepass.scope -isnot [string] -or
      -not (Test-MathSecrSearchStrictBoolean $phrasePrepass.submitted) -or
      -not (Test-MathSecrSearchStrictBoolean $phrasePrepass.freshResultVerified) -or
      -not (Test-MathSecrSearchStrictInteger $phrasePrepass.resultCount) -or
      [int64]$phrasePrepass.resultCount -lt 0 -or
      -not (Test-MathSecrSearchStrictBoolean $phrasePrepass.exactFound) -or
      -not (Test-MathSecrSearchStrictBoolean $phrasePrepass.resetBefore) -or
      $phrasePrepass.clearReceipt -isnot [string] -or
      $phrasePrepass.removedChips -isnot [System.Array] -or
      -not (Test-MathSecrSearchNonblankString $phrasePrepass.chip.value) -or
      $phrasePrepass.chip.provenance -isnot [string] -or
      -not (Test-MathSecrSearchNonblankString $phrasePrepass.chip.evidenceReceipt)
    ) {
      $schemaValid = $false
      $errors.Add("phrase-prepass-shape")
    } else {
      $phraseValue = [string]$phrasePrepass.chip.value
      $normalizedPhrase = ConvertTo-MathSecrSearchNormalizedChip $phraseValue
      $attemptSummaries.Insert(0, [pscustomobject]@{
        AttemptId = [string]$phrasePrepass.attemptId; Scope = [string]$phrasePrepass.scope
        Phase = "phrase-prepass"; AttemptKind = "phrase-prepass"
        OrderedChips = @($phraseValue); OrderedProvenance = @([string]$phrasePrepass.chip.provenance)
        ResultCount = [int64]$phrasePrepass.resultCount; ExactFound = [bool]$phrasePrepass.exactFound
        ResetBefore = [bool]$phrasePrepass.resetBefore
      })
      $phraseBodyEvidenceMatches = $literalEvidenceSets.ContainsKey("body") -and
        $literalEvidenceSets["body"].Contains($normalizedPhrase)
      $phraseOrderingValid = $attempts.Count -gt 0 -and
        $phrasePrepass.scope -ceq "initial-scope" -and
        $phrasePrepass.followedByAttemptId -ceq [string]$attempts[0].attemptId -and
        -not $attemptIds.Contains([string]$phrasePrepass.attemptId)
      $phraseChipValid = $phrasePrepass.chip.provenance -ceq "literal-body" -and
        (Test-MathSecrSearchPhrasePrepassClue $phraseValue) -and
        $phraseBodyEvidenceMatches
      $firstAttemptRemovedValues = if ($attempts.Count -gt 0) {
        @($attempts[0].removedChips | ForEach-Object { [string]$_.value })
      } else {
        @()
      }
      $phraseTransitionValid = $attempts.Count -gt 0 -and $attempts[0].resetBefore -eq $true -and
        (Test-MathSecrSearchNonblankString $attempts[0].clearReceipt) -and
        (Test-MathSecrSearchOrderedEqual $firstAttemptRemovedValues @($phraseValue))
      if (-not $phraseOrderingValid -or -not $phraseChipValid) {
        $policyValid = $false
        $errors.Add("invalid-phrase-prepass")
      }
      if (-not $phraseTransitionValid) {
        $policyValid = $false
        $errors.Add("phrase-prepass-removal-not-receipted")
      }
      if (
        -not $phrasePrepass.submitted -or
        -not $phrasePrepass.freshResultVerified -or
        -not $phrasePrepass.resetBefore -or
        -not (Test-MathSecrSearchNonblankString $phrasePrepass.clearReceipt) -or
        @($phrasePrepass.removedChips).Count -ne 0
      ) {
        $policyValid = $false
        $errors.Add("phrase-prepass-freshness")
      }
      if (
        $phrasePrepass.exactFound -and
        @($attempts | Where-Object { $_.exactFound }).Count -eq 0
      ) {
        $policyValid = $false
        $errors.Add("phrase-prepass-exact-unconfirmed")
      }
    }
  }
  if (-not $schemaValid) { return New-MathSecrSearchContractInvalidResult $errors $attemptSummaries $targetBinding }

  $commonChips = @()
  $commonUnverifiedChips = @()
  foreach ($firstChip in @($attempts[0].chips)) {
    $normalizedFirst = ConvertTo-MathSecrSearchNormalizedChip $firstChip.value
    $presentEverywhere = $true
    $unverifiedSomewhere = $false
    foreach ($attempt in $attempts) {
      $matching = @($attempt.chips | Where-Object { (ConvertTo-MathSecrSearchNormalizedChip $_.value) -ceq $normalizedFirst })
      if ($matching.Count -eq 0) { $presentEverywhere = $false; break }
      foreach ($chip in $matching) { if (Test-MathSecrSearchChipIsUnverified $chip) { $unverifiedSomewhere = $true } }
    }
    if ($presentEverywhere) {
      $commonChips += [string]$firstChip.value
      if ($unverifiedSomewhere) { $commonUnverifiedChips += [string]$firstChip.value }
    }
  }
  if ($commonUnverifiedChips.Count -gt 0) { $policyValid = $false; $errors.Add("common-unverified-and-chip") }

  $scopeRank = @{ "initial-scope" = 0; "candidate-recovery" = 1; "whole-db" = 2 }
  $seenScopes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $scopeOrder = [System.Collections.Generic.List[string]]::new()
  $previousScope = $null
  $lastRank = -1
  foreach ($attempt in $attempts) {
    if ($attempt.scope -cne $previousScope) {
      if ($seenScopes.Contains([string]$attempt.scope) -or $scopeRank[$attempt.scope] -lt $lastRank) {
        $policyValid = $false; $errors.Add("scope-order-or-contiguity:$($attempt.scope)")
      } else {
        [void]$seenScopes.Add([string]$attempt.scope)
        $scopeOrder.Add([string]$attempt.scope)
        $lastRank = $scopeRank[$attempt.scope]
      }
      $previousScope = [string]$attempt.scope
    }
  }

  $scopeLadders = [System.Collections.Generic.List[object]]::new()
  $priorAttempt = if ($null -ne $phrasePrepassProperty) {
    [pscustomobject]@{ chips = @($phrasePrepassProperty.Value.chip) }
  } else {
    $null
  }
  foreach ($scope in $scopeOrder) {
    $scopeAttempts = @($attempts | Where-Object { $_.scope -ceq $scope })
    $ladder = Test-MathSecrSearchScopeLadder $scope $scopeAttempts $priorAttempt
    $scopeLadders.Add($ladder)
    foreach ($ladderError in @($ladder.Errors)) { $errors.Add([string]$ladderError) }
    $priorAttempt = $scopeAttempts[-1]
  }
  $literalOnlyLadderCompleted = $scopeLadders.Count -gt 0 -and @($scopeLadders | Where-Object { -not $_.LiteralStart }).Count -eq 0
  $adaptiveLaddersValid = $scopeLadders.Count -gt 0 -and @($scopeLadders | Where-Object { -not $_.Valid }).Count -eq 0
  $resetBackoffPerformed = $scopeLadders.Count -gt 0 -and @($scopeLadders | Where-Object { -not $_.ResetBackoffSatisfied }).Count -eq 0

  $candidateRecoveryCompleted = $false
  $completeCoverageVerified = $false
  $derivedExactMatchIds = [System.Collections.Generic.List[string]]::new()
  $derivedExactSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($exactId in $attemptExactIds) {
    if ($derivedExactSet.Add($exactId)) { $derivedExactMatchIds.Add($exactId) }
  }
  if (
    (Test-MathSecrSearchRequiredProperties $Packet.candidateRecoveryEvidence @("routes", "coverage")) -and
    $Packet.candidateRecoveryEvidence.routes -is [System.Array] -and
    $Packet.candidateRecoveryEvidence.coverage -is [System.Array]
  ) {
    $routeKinds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $routesValid = $true
    foreach ($route in @($Packet.candidateRecoveryEvidence.routes)) {
      if (
        -not (Test-MathSecrSearchRequiredProperties $route @("kind", "completed", "receipt")) -or
        $route.kind -isnot [string] -or $route.kind -cnotin $script:MathSecrCandidateRecoveryRoutes -or
        -not $routeKinds.Add([string]$route.kind) -or
        -not (Test-MathSecrSearchStrictBoolean $route.completed) -or -not $route.completed -or
        -not (Test-MathSecrSearchNonblankString $route.receipt)
      ) { $routesValid = $false }
    }
    $candidateRecoveryCompleted = $routesValid -and $routeKinds.Contains("metadata-id-run") -and $routeKinds.Contains("source-paper-selector")
    $coverageRoutes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $coverageValid = $candidateRecoveryCompleted
    foreach ($coverageRow in @($Packet.candidateRecoveryEvidence.coverage)) {
      $coverageResult = Test-MathSecrSearchCoverageRow $coverageRow
      if (
        -not $coverageResult.Valid -or -not $routeKinds.Contains([string]$coverageRow.route) -or
        -not $coverageRoutes.Add([string]$coverageRow.route)
      ) { $coverageValid = $false } else {
        foreach ($exactMatchId in @($coverageResult.ExactMatchIds)) {
          if ($derivedExactSet.Add([string]$exactMatchId)) { $derivedExactMatchIds.Add([string]$exactMatchId) }
        }
      }
    }
    foreach ($routeKind in $routeKinds) { if (-not $coverageRoutes.Contains($routeKind)) { $coverageValid = $false } }
    $completeCoverageVerified = $coverageValid
  } else { $schemaValid = $false; $errors.Add("candidate-recovery-shape") }
  if ($Packet.outcome -cne 'exact' -or $attemptExactIds.Count -eq 0) {
    if (-not $candidateRecoveryCompleted) { $errors.Add("candidate-recovery-incomplete") }
    if (-not $completeCoverageVerified) { $errors.Add("complete-coverage-incomplete") }
  }

  $attemptExactCount = @($attempts | Where-Object { $_.exactFound }).Count
  $outcomeConsistent =
    ($Packet.outcome -ceq "missed" -and $attemptExactCount -eq 0 -and $derivedExactMatchIds.Count -eq 0) -or
    ($Packet.outcome -ceq "exact" -and $attemptExactCount -gt 0 -and $derivedExactMatchIds.Count -gt 0) -or
    ($Packet.outcome -ceq "pending" -and $attemptExactCount -eq 0 -and $derivedExactMatchIds.Count -eq 0)
  if (-not $outcomeConsistent) { $errors.Add("outcome-inconsistent") }

  $claimsValid = $false
  if (
    $schemaValid -and (Test-MathSecrSearchStrictStringArray $Packet.commonChips) -and
    (Test-MathSecrSearchStrictStringArray $Packet.exactMatchIds $true) -and
    (Test-MathSecrSearchStrictBoolean $Packet.literalOnlyLadderCompleted) -and
    (Test-MathSecrSearchStrictBoolean $Packet.resetBackoffPerformed) -and
    (Test-MathSecrSearchStrictBoolean $Packet.candidateRecoveryCompleted) -and
    (Test-MathSecrSearchStrictBoolean $Packet.completeCoverageVerified)
  ) {
    $claimsValid = (Test-MathSecrSearchOrderedEqual $Packet.commonChips $commonChips) -and
      (Test-MathSecrSearchOrderedEqual $Packet.exactMatchIds $derivedExactMatchIds) -and
      $Packet.literalOnlyLadderCompleted -eq $literalOnlyLadderCompleted -and
      $Packet.resetBackoffPerformed -eq $resetBackoffPerformed -and
      $Packet.candidateRecoveryCompleted -eq $candidateRecoveryCompleted -and
      $Packet.completeCoverageVerified -eq $completeCoverageVerified
  }
  if (-not $claimsValid) { $errors.Add("derived-claims-mismatch") }

  $initialLadder = @($scopeLadders | Where-Object { $_.Scope -ceq "initial-scope" })
  $wholeDbLadder = @($scopeLadders | Where-Object { $_.Scope -ceq "whole-db" })
  $missScopesReady = $initialLadder.Count -eq 1 -and $wholeDbLadder.Count -eq 1 -and
    $initialLadder[0].Valid -and
    $wholeDbLadder[0].Valid -and $wholeDbLadder[0].ScanReady
  if ($Packet.outcome -ceq "missed" -and -not $missScopesReady) { $errors.Add("required-miss-scope-ladder-incomplete") }

  $canCloseMiss = [bool](
    $schemaValid -and $policyValid -and $claimsValid -and $Packet.outcome -ceq "missed" -and
    $outcomeConsistent -and $missScopesReady -and $literalOnlyLadderCompleted -and
    $adaptiveLaddersValid -and $resetBackoffPerformed -and $candidateRecoveryCompleted -and
    $completeCoverageVerified -and $derivedExactMatchIds.Count -eq 0 -and $commonUnverifiedChips.Count -eq 0
  )
  $exactFound = [bool](
    $schemaValid -and $policyValid -and $claimsValid -and $Packet.outcome -ceq "exact" -and
    $outcomeConsistent -and $initialLadder.Count -eq 1 -and $initialLadder[0].Valid -and
    $adaptiveLaddersValid -and
    (($attemptExactIds.Count -gt 0) -or ($candidateRecoveryCompleted -and $completeCoverageVerified))
  )

  return [pscustomobject]@{
    SchemaValid = [bool]$schemaValid; ClaimsValid = [bool]$claimsValid; CanCloseMiss = $canCloseMiss
    Status = if ($canCloseMiss) { "miss-closure-ready" } elseif ($exactFound) { "exact-found" } else { "candidate-recovery-pending" }
    TargetBinding = $targetBinding; ExactMatchIds = @($derivedExactMatchIds)
    CommonChips = @($commonChips); CommonUnverifiedChips = @($commonUnverifiedChips)
    LiteralOnlyLadderCompleted = [bool]$literalOnlyLadderCompleted
    ResetBackoffPerformed = [bool]$resetBackoffPerformed
    CandidateRecoveryCompleted = [bool]$candidateRecoveryCompleted
    CompleteCoverageVerified = [bool]$completeCoverageVerified
    AttemptSummaries = @($attemptSummaries); ScopeLadders = @($scopeLadders); Errors = @($errors)
  }
}
