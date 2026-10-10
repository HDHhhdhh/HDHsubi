param(
  [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [ValidateSet("All", "bad-common-semantic-and", "bad-sentence-like-base", "goguk2-q2-exact-found", "synthetic-absence-control")]
  [string]$Case = "All"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "search_attempt_contract.ps1")

function Assert-Equal {
  param($Actual, $Expected, [string]$Label)
  if ($Actual -cne $Expected) { throw "$Label expected '$Expected' but got '$Actual'." }
}

function Assert-Sequence {
  param($Actual, $Expected, [string]$Label)
  $actualValues = @($Actual)
  $expectedValues = @($Expected)
  if ($actualValues.Count -ne $expectedValues.Count) {
    throw "$Label count expected $($expectedValues.Count) but got $($actualValues.Count)."
  }
  for ($index = 0; $index -lt $expectedValues.Count; $index++) {
    if ([string]$actualValues[$index] -cne [string]$expectedValues[$index]) {
      throw "$Label index $index expected '$($expectedValues[$index])' but got '$($actualValues[$index])'."
    }
  }
}

function Assert-Contains {
  param($Values, [string]$Expected, [string]$Label)
  if (@($Values | Where-Object { [string]$_ -ceq $Expected }).Count -eq 0) {
    throw "$Label expected to contain '$Expected'."
  }
}

function Assert-ContainsValue {
  param($Actual, $Expected, [string]$Label)
  if (-not (@($Actual) -ccontains $Expected)) {
    throw "$Label expected to contain '$Expected' but got '$(@($Actual) -join ', ')'."
  }
}

function Copy-Value {
  param($Value)
  return $Value | ConvertTo-Json -Depth 50 | ConvertFrom-Json
}

function Add-ValidPhrasePrepass {
  param($Packet, [bool]$ExactFound = $false)
  $phraseValue = "직선과 곡선이 만나는 두 점"
  $Packet.literalEvidence.body = @($Packet.literalEvidence.body) + @($phraseValue)
  $Packet.attempts[0].removedChips = @(
    [pscustomobject]@{ value = $phraseValue; removalReceipt = "$phraseValue 제거" }
  )
  $Packet | Add-Member -NotePropertyName phrasePrepass -NotePropertyValue ([pscustomobject][ordered]@{
      attemptId = "q2-phrase-prepass"
      scope = "initial-scope"
      chip = [pscustomobject][ordered]@{
        value = $phraseValue
        provenance = "literal-body"
        evidenceReceipt = "source-render:q2:continuous-phrase"
      }
      submitted = $true
      freshResultVerified = $true
      resultCount = 1
      exactFound = $ExactFound
      resetBefore = $true
      clearReceipt = "query-and-formula-empty-before-phrase-prepass"
      removedChips = @()
      followedByAttemptId = [string]$Packet.attempts[0].attemptId
    }) -Force
  return $Packet
}

$fixturePath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\search-attempts\goguk2-mid-q2.json"
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
$cases = @($fixture.cases | Where-Object { $Case -eq "All" -or $_.name -ceq $Case })
if ($cases.Count -eq 0) { throw "No search-attempt fixture matched case: $Case" }

$expectedTermProvenance = [ordered]@{
  "양수" = "semantic-inference"
  "길이" = "literal-visible-ui-metadata"
  "서로 다른" = "semantic-inference"
  "교점" = "semantic-inference"
  "선분" = "semantic-inference"
}
foreach ($term in @($fixture.incident.termEvidence)) {
  if (-not $expectedTermProvenance.Contains($term.value)) { throw "Unexpected incident term evidence: $($term.value)" }
  Assert-Equal $term.provenance $expectedTermProvenance[$term.value] "incident term '$($term.value)' provenance"
}
Assert-Equal @($fixture.incident.termEvidence).Count $expectedTermProvenance.Count "incident term evidence count"

foreach ($fixtureCase in $cases) {
  $result = Test-MathSecrSearchAttemptContract $fixtureCase.packet
  Assert-Equal $result.SchemaValid ([bool]$fixtureCase.expect.schemaValid) "$($fixtureCase.name) schema"
  Assert-Equal $result.ClaimsValid ([bool]$fixtureCase.expect.claimsValid) "$($fixtureCase.name) claims"
  Assert-Equal $result.CanCloseMiss ([bool]$fixtureCase.expect.canCloseMiss) "$($fixtureCase.name) miss closure"
  Assert-Equal $result.Status $fixtureCase.expect.status "$($fixtureCase.name) status"
  Assert-Equal $result.TargetBinding.SourceProblemNumber $fixtureCase.expect.targetBinding.sourceProblemNumber "$($fixtureCase.name) source problem binding"
  Assert-Equal $result.TargetBinding.OccurrenceKey $fixtureCase.expect.targetBinding.occurrenceKey "$($fixtureCase.name) occurrence binding"
  Assert-Sequence $result.ExactMatchIds $fixtureCase.expect.exactMatchIds "$($fixtureCase.name) exact IDs"
  Assert-Sequence $result.CommonChips $fixtureCase.expect.commonChips "$($fixtureCase.name) common chips"
  Assert-Sequence $result.CommonUnverifiedChips $fixtureCase.expect.commonUnverifiedChips "$($fixtureCase.name) common unverified chips"
  Assert-Equal $result.LiteralOnlyLadderCompleted ([bool]$fixtureCase.expect.literalOnlyLadderCompleted) "$($fixtureCase.name) literal-only ladder"
  Assert-Equal $result.ResetBackoffPerformed ([bool]$fixtureCase.expect.resetBackoffPerformed) "$($fixtureCase.name) reset/backoff"
  Assert-Equal $result.CandidateRecoveryCompleted ([bool]$fixtureCase.expect.candidateRecoveryCompleted) "$($fixtureCase.name) candidate recovery"
  Assert-Equal $result.CompleteCoverageVerified ([bool]$fixtureCase.expect.completeCoverageVerified) "$($fixtureCase.name) coverage"
}

if ($Case -eq "All") {
  $bad = @($fixture.cases | Where-Object name -ceq "bad-common-semantic-and")[0]
  $sentenceBase = @($fixture.cases | Where-Object name -ceq "bad-sentence-like-base")[0]
  $exact = @($fixture.cases | Where-Object name -ceq "goguk2-q2-exact-found")[0]
  $absence = @($fixture.cases | Where-Object name -ceq "synthetic-absence-control")[0]

  $malformed = Test-MathSecrSearchAttemptContract ([pscustomobject]@{})
  Assert-Equal $malformed.SchemaValid $false "malformed packet schema"
  Assert-Equal $malformed.CanCloseMiss $false "malformed packet closure"

  $missingWholeDb = Copy-Value $absence.packet
  $missingWholeDb.attempts = @($missingWholeDb.attempts | Where-Object scope -cne "whole-db")
  $missingWholeDbResult = Test-MathSecrSearchAttemptContract $missingWholeDb
  Assert-Equal $missingWholeDbResult.CanCloseMiss $false "missing whole-DB ladder closure"
  Assert-Equal $missingWholeDbResult.Status "candidate-recovery-pending" "missing whole-DB ladder status"

  $validWholeDb = Test-MathSecrSearchAttemptContract $absence.packet
  Assert-Equal $validWholeDb.CanCloseMiss $true "actual whole-DB ladder closure"
  Assert-Equal @($validWholeDb.ScopeLadders | Where-Object Scope -ceq "whole-db").Count 1 "whole-DB ladder derived"

  $sentenceBaseResult = Test-MathSecrSearchAttemptContract $sentenceBase.packet
  Assert-Equal $sentenceBaseResult.CanCloseMiss $false "sentence-like base cannot close miss"
  Assert-Equal $sentenceBaseResult.Status "candidate-recovery-pending" "sentence-like base status"
  Assert-Contains $sentenceBaseResult.Errors "invalid-literal-start-word-granularity:initial-scope" "sentence-like base error"

  $validPhrasePrepass = Copy-Value $absence.packet
  $validPhrasePrepass.literalEvidence.body = @($validPhrasePrepass.literalEvidence.body) + @("두 직선의 교점")
  $validPhrasePrepass.attempts[0].removedChips = @(
    [pscustomobject]@{ value = "두 직선의 교점"; removalReceipt = "두 직선의 교점 제거" }
  )
  $validPhrasePrepass | Add-Member -NotePropertyName phrasePrepass -NotePropertyValue ([pscustomobject]@{
    attemptId = "absence-phrase-prepass"
    scope = "initial-scope"
    chip = [pscustomobject]@{
      value = "두 직선의 교점"; provenance = "literal-body"; evidenceReceipt = "absence:body:line-intersection-phrase"
    }
    submitted = $true
    freshResultVerified = $true
    resultCount = 1
    exactFound = $false
    resetBefore = $true
    clearReceipt = "absence-prepass-clear"
    removedChips = @()
    followedByAttemptId = "absence-initial-2"
  }) -Force
  $validPhrasePrepassResult = Test-MathSecrSearchAttemptContract $validPhrasePrepass
  Assert-Equal $validPhrasePrepassResult.CanCloseMiss $true "single phrase prepass with removal receipt"

  $phrasePrepassWithoutRemoval = Copy-Value $validPhrasePrepass
  $phrasePrepassWithoutRemoval.attempts[0].removedChips = @()
  $phrasePrepassWithoutRemovalResult = Test-MathSecrSearchAttemptContract $phrasePrepassWithoutRemoval
  Assert-Equal $phrasePrepassWithoutRemovalResult.CanCloseMiss $false "phrase prepass without removal receipt"
  Assert-Contains $phrasePrepassWithoutRemovalResult.Errors "phrase-prepass-removal-not-receipted" "phrase prepass removal error"

  $knownExact = Test-MathSecrSearchAttemptContract $exact.packet
  Assert-Equal $knownExact.Status "exact-found" "known Q2 exact status"
  Assert-Equal $knownExact.CanCloseMiss $false "known Q2 exact cannot close miss"
  Assert-Sequence $knownExact.ExactMatchIds @("source-paper-10") "known Q2 exact IDs"
  Assert-Equal (Test-MathSecrSearchContainsWhitespace "다항함수") $false "single Korean compound token whitespace"
  Assert-Equal (Test-MathSecrSearchContainsWhitespace "두 점") $true "ordinary space detection"
  Assert-Equal (Test-MathSecrSearchContainsWhitespace ("두" + [char]9 + "점")) $true "tab whitespace detection"
  Assert-Equal (Test-MathSecrSearchContainsWhitespace ("두" + [char]0x00A0 + "점")) $true "NBSP whitespace detection"
  Assert-Equal (Test-MathSecrSearchSingleBodyWord "자연로그함수") $true "six-character Korean compound word boundary"
  Assert-Equal (Test-MathSecrSearchSingleBodyWord "x축") $true "ASCII variable plus Korean word boundary"
  Assert-Equal (Test-MathSecrSearchSingleBodyWord "0이아닌모든실수") $false "space-stripped clause length boundary"
  Assert-Equal (Test-MathSecrSearchSingleBodyWord "모든실수") $false "space-stripped quantifier boundary"
  Assert-Equal (Test-MathSecrSearchSingleBodyWord "함수이다,그러면") $false "internal punctuation boundary"
  Assert-Equal (Test-MathSecrSearchSingleBodyWord "함수이다그러면") $false "space-stripped connective boundary"
  Assert-Equal $exact.packet.attempts[2].chips[3].value "두 점" "multiword refinement fixture"
  $knownExactInitialLadder = @($knownExact.ScopeLadders | Where-Object Scope -ceq "initial-scope")
  Assert-Equal $knownExactInitialLadder[0].Valid $true "multiword refinement remains valid"

  $longRefinement = Copy-Value $exact.packet
  $longRefinementValue = "그래프가 그림과 같다"
  $longRefinement.literalEvidence.body = @($longRefinement.literalEvidence.body) + @($longRefinementValue)
  $longRefinement.attempts[2].chips[3].value = $longRefinementValue
  $longRefinement.attempts[3].removedChips[1].value = $longRefinementValue
  $longRefinementResult = Test-MathSecrSearchAttemptContract $longRefinement
  Assert-Equal $longRefinementResult.Status "candidate-recovery-pending" "long refinement status"
  Assert-ContainsValue $longRefinementResult.Errors "invalid-refinement-body-clue:q2-refine-4" "long refinement error"

  foreach ($collapsedBasePair in @(
    [pscustomobject]@{ First = "0이아닌모든실수"; Second = "곡선" },
    [pscustomobject]@{ First = "직선"; Second = "함수이다,그러면" }
  )) {
    $collapsedBase = Copy-Value $absence.packet
    foreach ($replacementValue in @([string]$collapsedBasePair.First, [string]$collapsedBasePair.Second)) {
      if (@($collapsedBase.literalEvidence.body) -cnotcontains $replacementValue) {
        $collapsedBase.literalEvidence.body = @($collapsedBase.literalEvidence.body) + @($replacementValue)
      }
    }
    foreach ($attempt in @($collapsedBase.attempts)) {
      foreach ($chip in @($attempt.chips)) {
        if ($chip.value -ceq "직선") { $chip.value = [string]$collapsedBasePair.First }
        if ($chip.value -ceq "곡선") { $chip.value = [string]$collapsedBasePair.Second }
      }
      foreach ($removedChip in @($attempt.removedChips)) {
        if ($removedChip.value -ceq "직선") { $removedChip.value = [string]$collapsedBasePair.First }
        if ($removedChip.value -ceq "곡선") { $removedChip.value = [string]$collapsedBasePair.Second }
      }
    }
    $collapsedBaseResult = Test-MathSecrSearchAttemptContract $collapsedBase
    Assert-Equal $collapsedBaseResult.CanCloseMiss $false "collapsed or punctuated clause base closure"
    Assert-ContainsValue $collapsedBaseResult.Errors "invalid-literal-start-word-granularity:initial-scope" "collapsed or punctuated clause initial error"
    Assert-ContainsValue $collapsedBaseResult.Errors "invalid-literal-start-word-granularity:whole-db" "collapsed or punctuated clause whole-DB error"
  }

  $oneSentenceBase = Copy-Value $exact.packet
  $oneSentenceValue = "0이 아닌 모든 실수"
  $oneSentenceBase.literalEvidence.body = @($oneSentenceBase.literalEvidence.body) + @($oneSentenceValue)
  foreach ($attemptIndex in 0..3) {
    $oneSentenceBase.attempts[$attemptIndex].chips[0].value = $oneSentenceValue
  }
  $oneSentenceBase.attempts[4].removedChips[0].value = $oneSentenceValue
  $oneSentenceBaseResult = Test-MathSecrSearchAttemptContract $oneSentenceBase
  Assert-Equal $oneSentenceBaseResult.SchemaValid $true "one sentence plus one word base schema"
  Assert-Equal $oneSentenceBaseResult.CanCloseMiss $false "one sentence plus one word base closure"
  Assert-Equal $oneSentenceBaseResult.Status "candidate-recovery-pending" "one sentence plus one word base status"
  Assert-ContainsValue $oneSentenceBaseResult.Errors "invalid-literal-start-word-granularity:initial-scope" "one sentence plus one word base error"

  $twoSentenceBase = Copy-Value $exact.packet
  $twoSentenceFirst = "0이 아닌 모든 실수"
  $twoSentenceSecond = "만족시킬 때"
  $twoSentenceBase.literalEvidence.body = @($twoSentenceBase.literalEvidence.body) +
    @($twoSentenceFirst, $twoSentenceSecond)
  foreach ($attemptIndex in 0..3) {
    $twoSentenceBase.attempts[$attemptIndex].chips[0].value = $twoSentenceFirst
    $twoSentenceBase.attempts[$attemptIndex].chips[1].value = $twoSentenceSecond
  }
  $twoSentenceBase.attempts[4].removedChips[0].value = $twoSentenceFirst
  $twoSentenceBase.attempts[4].removedChips[1].value = $twoSentenceSecond
  $twoSentenceBaseResult = Test-MathSecrSearchAttemptContract $twoSentenceBase
  Assert-Equal $twoSentenceBaseResult.SchemaValid $true "two sentence base schema"
  Assert-Equal $twoSentenceBaseResult.CanCloseMiss $false "two sentence base closure"
  Assert-Equal $twoSentenceBaseResult.Status "candidate-recovery-pending" "two sentence base status"
  Assert-ContainsValue $twoSentenceBaseResult.Errors "invalid-literal-start-word-granularity:initial-scope" "two sentence base error"

  $validPhrasePrepass = Add-ValidPhrasePrepass (Copy-Value $exact.packet)
  $validPhrasePrepassResult = Test-MathSecrSearchAttemptContract $validPhrasePrepass
  Assert-Equal $validPhrasePrepassResult.SchemaValid $true "valid phrase prepass schema"
  Assert-Equal $validPhrasePrepassResult.ClaimsValid $true "valid phrase prepass leaves claims unchanged"
  Assert-Equal $validPhrasePrepassResult.Status "exact-found" "valid phrase prepass leaves exact status unchanged"
  Assert-Sequence $validPhrasePrepassResult.ExactMatchIds $knownExact.ExactMatchIds "valid phrase prepass exact IDs"
  Assert-Sequence $validPhrasePrepassResult.CommonChips $knownExact.CommonChips "valid phrase prepass common chips"
  Assert-Equal @($validPhrasePrepassResult.AttemptSummaries).Count (@($validPhrasePrepass.attempts).Count + 1) "phrase prepass summary count"
  Assert-Equal $validPhrasePrepassResult.AttemptSummaries[0].AttemptId "q2-phrase-prepass" "phrase prepass summary order"
  Assert-Equal $validPhrasePrepassResult.AttemptSummaries[0].AttemptKind "phrase-prepass" "phrase prepass summary kind"
  Assert-Sequence $validPhrasePrepassResult.AttemptSummaries[0].OrderedChips @("직선과 곡선이 만나는 두 점") "phrase prepass ordered chips"
  Assert-Sequence $validPhrasePrepassResult.AttemptSummaries[0].OrderedProvenance @("literal-body") "phrase prepass ordered provenance"

  $repeatedPhrasePrepass = Copy-Value $validPhrasePrepass
  $repeatedPhrasePrepass.phrasePrepass = @(
    (Copy-Value $validPhrasePrepass.phrasePrepass),
    (Copy-Value $validPhrasePrepass.phrasePrepass)
  )
  $repeatedPhrasePrepassResult = Test-MathSecrSearchAttemptContract $repeatedPhrasePrepass
  Assert-Equal $repeatedPhrasePrepassResult.SchemaValid $false "repeated phrase prepass schema"
  Assert-ContainsValue $repeatedPhrasePrepassResult.Errors "phrase-prepass-shape" "repeated phrase prepass error"

  $twoChipPhrasePrepass = Copy-Value $validPhrasePrepass
  $twoChipPhrasePrepass.phrasePrepass.chip = @(
    (Copy-Value $validPhrasePrepass.phrasePrepass.chip),
    (Copy-Value $validPhrasePrepass.phrasePrepass.chip)
  )
  $twoChipPhrasePrepassResult = Test-MathSecrSearchAttemptContract $twoChipPhrasePrepass
  Assert-Equal $twoChipPhrasePrepassResult.SchemaValid $false "two-chip phrase prepass schema"
  Assert-ContainsValue $twoChipPhrasePrepassResult.Errors "phrase-prepass-shape" "two-chip phrase prepass error"

  $stalePhrasePrepass = Copy-Value $validPhrasePrepass
  $stalePhrasePrepass.phrasePrepass.submitted = $false
  $stalePhrasePrepass.phrasePrepass.freshResultVerified = $false
  $stalePhrasePrepassResult = Test-MathSecrSearchAttemptContract $stalePhrasePrepass
  Assert-Equal $stalePhrasePrepassResult.SchemaValid $true "stale phrase prepass schema"
  Assert-Equal $stalePhrasePrepassResult.Status "candidate-recovery-pending" "stale phrase prepass status"
  Assert-ContainsValue $stalePhrasePrepassResult.Errors "phrase-prepass-freshness" "stale phrase prepass error"

  $phraseExactWithoutProof = Add-ValidPhrasePrepass (Copy-Value $absence.packet) $true
  $phraseExactWithoutProofResult = Test-MathSecrSearchAttemptContract $phraseExactWithoutProof
  Assert-Equal $phraseExactWithoutProofResult.SchemaValid $true "phrase exact hint schema"
  Assert-Equal $phraseExactWithoutProofResult.CanCloseMiss $false "phrase exact hint cannot close miss"
  Assert-Equal $phraseExactWithoutProofResult.Status "candidate-recovery-pending" "phrase exact hint requires proof ladder exact"
  Assert-ContainsValue $phraseExactWithoutProofResult.Errors "phrase-prepass-exact-unconfirmed" "phrase exact hint error"

  $phraseOnly = Copy-Value $validPhrasePrepass
  $phraseOnly.attempts = @()
  $phraseOnlyResult = Test-MathSecrSearchAttemptContract $phraseOnly
  Assert-Equal $phraseOnlyResult.SchemaValid $false "phrase-only packet schema"
  Assert-Equal $phraseOnlyResult.CanCloseMiss $false "phrase-only packet closure"
  Assert-Equal $phraseOnlyResult.Status "candidate-recovery-pending" "phrase-only packet status"

  $forgedMiss = Copy-Value $exact.packet
  $forgedMiss.outcome = "missed"
  $forgedMissResult = Test-MathSecrSearchAttemptContract $forgedMiss
  Assert-Equal $forgedMissResult.CanCloseMiss $false "known exact coverage forged as miss"

  $ghostExact = Copy-Value $exact.packet
  $ghostExact.candidateRecoveryEvidence.coverage[1].exactMatchIds = @("ghost-id")
  $ghostExactResult = Test-MathSecrSearchAttemptContract $ghostExact
  Assert-Equal $ghostExactResult.CanCloseMiss $false "exact ID outside inspected coverage"
  Assert-Equal $ghostExactResult.CompleteCoverageVerified $false "exact ID subset coverage gate"

  $forgedCoverage = Copy-Value $absence.packet
  $forgedCoverage.candidateRecoveryEvidence.coverage[0].inspectedIds = @("absence-metadata-1")
  $forgedCoverageResult = Test-MathSecrSearchAttemptContract $forgedCoverage
  Assert-Equal $forgedCoverageResult.CanCloseMiss $false "copied aggregate coverage booleans"

  $semanticThenBackoff = Copy-Value $absence.packet
  $semanticThenBackoff.attempts[1].chips[2].value = "양수"
  $semanticThenBackoff.attempts[1].chips[2].provenance = "semantic-inference"
  $semanticThenBackoff.attempts[1].chips[2].evidenceReceipt = "translated-from:t>0"
  $semanticThenBackoff.attempts[2].removedChips[0].value = "양수"
  $semanticThenBackoffResult = Test-MathSecrSearchAttemptContract $semanticThenBackoff
  Assert-Equal $semanticThenBackoffResult.CanCloseMiss $true "semantic detour cleared by literal backoff and whole-DB proof"
  $semanticInitialLadder = @($semanticThenBackoffResult.ScopeLadders | Where-Object Scope -ceq "initial-scope")
  Assert-Equal $semanticInitialLadder.Count 1 "semantic detour initial ladder derived"
  Assert-Equal $semanticInitialLadder[0].ScanReady $false "semantic result count does not contribute to proof"
  Assert-Sequence $semanticInitialLadder[0].SemanticDetourAttemptIds @("absence-initial-refine") "semantic detour recorded"

  $semanticWithoutBackoff = Copy-Value $semanticThenBackoff
  $semanticWithoutBackoff.attempts = @(
    $semanticWithoutBackoff.attempts |
      Where-Object { $_.attemptId -cne "absence-initial-backoff" }
  )
  $semanticWithoutBackoffResult = Test-MathSecrSearchAttemptContract $semanticWithoutBackoff
  Assert-Equal $semanticWithoutBackoffResult.CanCloseMiss $false "semantic detour without removal backoff"

  $visibleMetadata = Copy-Value $absence.packet
  $visibleMetadata.literalEvidence.visibleUiMetadata = @("길이")
  $visibleMetadata.attempts[1].chips[2].value = "길이"
  $visibleMetadata.attempts[1].chips[2].provenance = "literal-visible-ui-metadata"
  $visibleMetadata.attempts[1].chips[2].evidenceReceipt = "visible-type:좌표와 길이"
  $visibleMetadata.attempts[2].removedChips[0].value = "길이"
  $visibleMetadataResult = Test-MathSecrSearchAttemptContract $visibleMetadata
  Assert-Equal $visibleMetadataResult.CanCloseMiss $false "visible metadata without verified index receipt"

  $formulaWithoutCommit = Copy-Value $absence.packet
  $formulaWithoutCommit.literalEvidence.formula = @("t>0")
  $formulaWithoutCommit.attempts[1].chips[2].value = "t>0"
  $formulaWithoutCommit.attempts[1].chips[2].provenance = "formula"
  $formulaWithoutCommit.attempts[1].chips[2].evidenceReceipt = "source-render:q2:t-positive"
  $formulaWithoutCommit.attempts[1].chips[2] | Add-Member -NotePropertyName indexEvidenceReceipt -NotePropertyValue "verified formula index match" -Force
  $formulaWithoutCommit.attempts[2].removedChips[0].value = "t>0"
  $formulaWithoutCommitResult = Test-MathSecrSearchAttemptContract $formulaWithoutCommit
  Assert-Equal $formulaWithoutCommitResult.CanCloseMiss $false "formula without editor commit receipt"

  $formulaWithoutIndexMatch = Copy-Value $formulaWithoutCommit
  $formulaWithoutIndexMatch.attempts[1].chips[2] |
    Add-Member -NotePropertyName formulaCommitReceipt -NotePropertyValue "formula-editor committed t>0 chip" -Force
  $formulaWithoutIndexMatch.attempts[1].chips[2].PSObject.Properties.Remove("indexEvidenceReceipt")
  $formulaWithoutIndexMatchResult = Test-MathSecrSearchAttemptContract $formulaWithoutIndexMatch
  Assert-Equal $formulaWithoutIndexMatchResult.CanCloseMiss $false "formula without index-match receipt"

  $formulaWithReceipts = Copy-Value $formulaWithoutCommit
  $formulaWithReceipts.attempts[1].chips[2] |
    Add-Member -NotePropertyName formulaCommitReceipt -NotePropertyValue "formula-editor committed t>0 chip" -Force
  $formulaWithReceiptsResult = Test-MathSecrSearchAttemptContract $formulaWithReceipts
  Assert-Equal $formulaWithReceiptsResult.CanCloseMiss $true "formula with editor commit and index-match receipts"

  $indexTermWithoutReceipt = Copy-Value $absence.packet
  $indexTermWithoutReceipt.attempts[1].chips[2].value = "양수"
  $indexTermWithoutReceipt.attempts[1].chips[2].provenance = "verified-index-term"
  $indexTermWithoutReceipt.attempts[1].chips[2].evidenceReceipt = "candidate index term"
  $indexTermWithoutReceipt.attempts[2].removedChips[0].value = "양수"
  $indexTermWithoutReceiptResult = Test-MathSecrSearchAttemptContract $indexTermWithoutReceipt
  Assert-Equal $indexTermWithoutReceiptResult.CanCloseMiss $false "verified index term without index receipt"

  $relabelTranslation = Copy-Value $absence.packet
  $relabelTranslation.attempts[1].chips[2].value = "양수"
  $relabelTranslation.attempts[1].chips[2].provenance = "literal-body"
  $relabelTranslation.attempts[1].chips[2].evidenceReceipt = "translated-from:t>0"
  $relabelTranslation.attempts[2].removedChips[0].value = "양수"
  $relabelTranslationResult = Test-MathSecrSearchAttemptContract $relabelTranslation
  Assert-Equal $relabelTranslationResult.CanCloseMiss $false "semantic translation relabeled as body literal"

  $missingExactArray = Copy-Value $exact.packet
  $missingExactArray.candidateRecoveryEvidence.coverage[1].PSObject.Properties.Remove("exactMatchIds")
  $missingExactArrayResult = Test-MathSecrSearchAttemptContract $missingExactArray
  Assert-Equal $missingExactArrayResult.CanCloseMiss $false "coverage exactMatchIds required"

  $badResult = Test-MathSecrSearchAttemptContract $bad.packet
  Assert-Equal $badResult.CanCloseMiss $false "bad Q2 semantic plan remains pending"

  # Early exact is an inspected candidate, not an exhaustive absence claim.
  $earlyExact = Copy-Value $exact.packet
  $earlyExact.attempts = @($earlyExact.attempts[0])
  $earlyExact.attempts[0].resultCount = 3
  $earlyExact.attempts[0].exactFound = $true
  $earlyExact.attempts[0] | Add-Member -NotePropertyName inspectedIds -NotePropertyValue @('early-candidate')
  $earlyExact.attempts[0] | Add-Member -NotePropertyName exactMatchIds -NotePropertyValue @('early-candidate')
  $earlyExact.candidateRecoveryEvidence = [pscustomobject]@{ routes = @(); coverage = @() }
  $earlyExact.candidateRecoveryCompleted = $false
  $earlyExact.completeCoverageVerified = $false
  $earlyExact.exactMatchIds = @('early-candidate')
  $earlyExactResult = Test-MathSecrSearchAttemptContract $earlyExact
  Assert-Equal $earlyExactResult.Status 'exact-found' 'early inspected exact without exhaustive coverage'
  Assert-Equal $earlyExactResult.CompleteCoverageVerified $false 'early exact preserves incomplete coverage'
  Assert-Equal $earlyExactResult.CanCloseMiss $false 'early exact cannot prove absence'

  $uninspectedExact = Copy-Value $earlyExact
  $uninspectedExact.attempts[0].inspectedIds = @('another-candidate')
  Assert-Equal (Test-MathSecrSearchAttemptContract $uninspectedExact).Status 'candidate-recovery-pending' 'uninspected early exact rejected'
  $forgedObservation = Copy-Value $earlyExact
  $forgedObservation.attempts[0] | Add-Member -NotePropertyName observationReceipt -NotePropertyValue ([pscustomobject]@{ freshResultVerified = $true })
  Assert-Equal (Test-MathSecrSearchAttemptContract $forgedObservation).Status 'candidate-recovery-pending' 'aggregate observation freshness rejected'
  . (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/body-comparison/synthetic_selection_test_support.ps1')
  $observedEarlyExact = Copy-Value $earlyExact
  $validObservation = New-MathSecrSyntheticSelectionObservation -AttemptId $earlyExact.attempts[0].attemptId `
    -Chips @($earlyExact.commonChips) -ResultCount 3 -OrderedIds @('early-candidate')
  $observedEarlyExact.attempts[0] | Add-Member -NotePropertyName observationReceipt -NotePropertyValue $validObservation
  Assert-Equal (Test-MathSecrSearchAttemptContract $observedEarlyExact).Status 'exact-found' 'valid observation malformed-chip control'
  foreach ($missingField in @('value', 'provenance')) {
    $missingChipField = $observedEarlyExact | ConvertTo-Json -Depth 60 | ConvertFrom-MathSecrSyntheticTestJson
    $missingChipField.attempts[0].chips[0].PSObject.Properties.Remove($missingField)
    Assert-Equal (Test-MathSecrSearchAttemptContract $missingChipField).SchemaValid $false "observation with missing chip $missingField rejects without exception"
  }
  $nullChip = $observedEarlyExact | ConvertTo-Json -Depth 60 | ConvertFrom-MathSecrSyntheticTestJson
  $nullChip.attempts[0].chips[0] = $null
  Assert-Equal (Test-MathSecrSearchAttemptContract $nullChip).SchemaValid $false 'observation with null chip rejects without exception'

  # Regression: a valid initial scope cannot launder an invalid exact-producing
  # candidate/whole-DB ladder through coverage and aggregate claims.
  $invalidExactLadder = Copy-Value $exact.packet
  $invalidExactLadder.attempts[-1].phase = 'refinement'
  $invalidExactLadder.literalOnlyLadderCompleted = $false
  Assert-Equal (Test-MathSecrSearchAttemptContract $invalidExactLadder).Status 'candidate-recovery-pending' 'invalid exact-producing ladder rejected'
}

Write-Host "Search-attempt contract tests PASS ($($cases.Count) fixture case(s))."
