[CmdletBinding()]
param(
  [string]$ProjectRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$docs = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\docs"
$verifier = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\scripts\verify_body_exact_benchmark.ps1"
$exporter = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\scripts\export_body_exact_blind_run.ps1"
$blinded = Join-Path $docs "body_exact_benchmark_blinded.json"
$gold = Join-Path $docs "body_exact_benchmark_gold.json"
$manifest = Join-Path $docs "body_exact_benchmark_manifest.json"
$observations = Join-Path $docs "body_exact_benchmark_observations.json"
$evidence = Join-Path $docs "body_exact_benchmark_evidence.md"
$stateEvidence = Join-Path $ProjectRoot ".omo\evidence\mathsecr_state_contamination_2026-06-05.md"
$recoveryEvidence = Join-Path $ProjectRoot ".omo\evidence\mathsecr_search_regression_recovery_policy_2026-06-07.md"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mathsecr-task8-" + [guid]::NewGuid().ToString("N"))
$childWrapper = Join-Path $tempRoot "invoke-child.ps1"
$powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source

function Initialize-ChildWrapper {
  $wrapperSource = @'
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Target,
  [Parameter(Mandatory = $true)]
  [string]$ArgumentListBase64
)

$ErrorActionPreference = "Stop"
try {
  $argumentListJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgumentListBase64))
  $parsedArguments = ConvertFrom-Json -InputObject $argumentListJson
  $targetArguments = @()
  foreach ($argument in $parsedArguments) {
    $targetArguments += [string]$argument
  }
  $targetParameters = @{}
  for ($index = 0; $index -lt $targetArguments.Count; $index++) {
    $parameterToken = [string]$targetArguments[$index]
    if ($parameterToken -notmatch "^-[A-Za-z][A-Za-z0-9]*$") {
      throw "Child argument '$parameterToken' is not a named parameter."
    }
    $parameterName = $parameterToken.Substring(1)
    $parameterValue = $true
    if ($index + 1 -lt $targetArguments.Count -and ([string]$targetArguments[$index + 1]) -notmatch "^-[A-Za-z][A-Za-z0-9]*$") {
      $parameterValue = [string]$targetArguments[$index + 1]
      $index++
    }
    $targetParameters[$parameterName] = $parameterValue
  }
  & $Target @targetParameters
  $childExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  if ($childExitCode -ne 0) { exit $childExitCode }
  exit 0
} catch {
  [Console]::Out.WriteLine("TASK8_RAW_ERROR: " + $_.Exception.Message)
  exit 1
}
'@
  Write-Utf8NoBom $wrapperSource $childWrapper
}

function Invoke-Child {
  param([string]$ScriptPath, [string[]]$Arguments)
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $argumentListJson = ConvertTo-Json -InputObject @($Arguments) -Compress
    $argumentListBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argumentListJson))
    $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $childWrapper -Target $ScriptPath -ArgumentListBase64 $argumentListBase64 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output | Out-String) }
}

function Invoke-Verifier {
  param([string[]]$ExtraArguments = @())
  $arguments = @("-ProjectRoot", $ProjectRoot) + $ExtraArguments
  return Invoke-Child $verifier $arguments
}

function Test-OutputContainsSignal {
  param([string]$Output, [string]$Needle)
  if ($Output -like "*$Needle*") { return $true }

  # PowerShell 5.1 may hard-wrap native error text inside a diagnostic token.
  $lineBreakFreeOutput = $Output -replace '\r\n?|\n', ''
  return $lineBreakFreeOutput -like "*$Needle*"
}

function Require-ExpectedFailure {
  param($Result, [string]$Needle, [string]$Label)
  if ($Result.ExitCode -eq 0) { throw "TASK8_TEST: $Label unexpectedly passed." }
  if (-not (Test-OutputContainsSignal $Result.Output $Needle)) { throw "TASK8_TEST: $Label failed without expected signal '$Needle'. Output: $($Result.Output)" }
}

function Require-ExpectedSuccess {
  param($Result, [string]$Needle, [string]$Label)
  if ($Result.ExitCode -ne 0) { throw "TASK8_TEST: $Label failed. Output: $($Result.Output)" }
  if (-not (Test-OutputContainsSignal $Result.Output $Needle)) { throw "TASK8_TEST: $Label passed without expected signal '$Needle'. Output: $($Result.Output)" }
}

function Write-Json {
  param($Value, [string]$Path, [int]$Depth = 16)
  $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-Utf8NoBom {
  param([string]$Value, [string]$Path)
  [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

function New-ManifestFor {
  param(
    [string]$OutPath,
    [string]$GoldPath = $gold,
    [string]$BlindPath = $blinded,
    [string]$ObservationsPath = $observations,
    [string]$EvidencePath = $evidence
  )
  $copy = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
  $copy.gold_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $GoldPath).Hash
  $copy.blinded_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $BlindPath).Hash
  $copy.observations_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ObservationsPath).Hash
  $copy.evidence_contract_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $EvidencePath).Hash
  Write-Json $copy $OutPath 8
}

function Get-OwnedPathSnapshot {
  param([string[]]$RelativePaths)
  $snapshot = @()
  foreach ($relativePath in $RelativePaths) {
    $fullPath = Join-Path $ProjectRoot ($relativePath -replace "/", "\")
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    $hash = if ($exists) { (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToUpperInvariant() } else { "" }
    $snapshot += "$relativePath`t$($exists.ToString().ToLowerInvariant())`t$hash"
  }
  return $snapshot
}

$ownedPaths = @(
  "mathsecr-paper-builder-kit/scripts/test_body_exact_benchmark.ps1",
  "mathsecr-paper-builder-kit/scripts/verify_body_exact_benchmark.ps1",
  "mathsecr-paper-builder-kit/scripts/ground_truth_contract.ps1",
  "mathsecr-paper-builder-kit/scripts/test_ground_truth_contract.ps1",
  "mathsecr-paper-builder-kit/scripts/export_body_exact_blind_run.ps1",
  "mathsecr-paper-builder-kit/test-fixtures/evaluation/ground-truth-claims.json",
  "mathsecr-paper-builder-kit/test-fixtures/docs/body_exact_benchmark_blinded.json",
  "mathsecr-paper-builder-kit/test-fixtures/docs/body_exact_benchmark_gold.json",
  "mathsecr-paper-builder-kit/test-fixtures/docs/body_exact_benchmark_manifest.json",
  "mathsecr-paper-builder-kit/test-fixtures/docs/body_exact_benchmark_observations.json",
  "mathsecr-paper-builder-kit/test-fixtures/docs/body_exact_benchmark_evidence.md",
  ".omo/evidence/mathsecr_state_contamination_2026-06-05.md",
  ".omo/evidence/mathsecr_search_regression_recovery_policy_2026-06-07.md"
)
$ownedSnapshotBefore = Get-OwnedPathSnapshot $ownedPaths

try {
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  Initialize-ChildWrapper

  $baselineFirst = Invoke-Verifier
  Require-ExpectedSuccess $baselineFirst "ordered_records=23 scoreable=7 quarantined=16 evidence_contract=v2" "baseline characterization"
  $baselineSecond = Invoke-Verifier
  if ($baselineFirst.Output -cne $baselineSecond.Output) { throw "TASK8_TEST: repeated verifier output was flaky." }

  $stateRaw = Get-Content -LiteralPath $stateEvidence -Raw -Encoding UTF8
  $recoveryRaw = Get-Content -LiteralPath $recoveryEvidence -Raw -Encoding UTF8
  $stateCrLf = Join-Path $tempRoot "origin-state-crlf.md"
  $recoveryCrLf = Join-Path $tempRoot "origin-recovery-crlf.md"
  Write-Utf8NoBom (((($stateRaw -replace "`r`n", "`n") -replace "`r", "`n") -replace "`n", "`r`n")) $stateCrLf
  Write-Utf8NoBom (((($recoveryRaw -replace "`r`n", "`n") -replace "`r", "`n") -replace "`n", "`r`n")) $recoveryCrLf
  $normalizedLfResult = Invoke-Verifier @("-StateEvidencePath", $stateCrLf, "-RecoveryEvidencePath", $recoveryCrLf)
  Require-ExpectedSuccess $normalizedLfResult "origin_evidence=direct" "normalized-LF origin evidence proof"

  $badStateEvidence = Join-Path $tempRoot "origin-state-corrupt.md"
  Write-Utf8NoBom ($stateRaw.Replace("1475258", "1475259")) $badStateEvidence
  $badStateResult = Invoke-Verifier @("-StateEvidencePath", $badStateEvidence)
  Require-ExpectedFailure $badStateResult "origin state evidence normalized-LF hash mismatch" "origin state file mutation proof"

  $badRecoveryEvidence = Join-Path $tempRoot "origin-recovery-corrupt.md"
  Write-Utf8NoBom ($recoveryRaw.Replace("229337", "229338")) $badRecoveryEvidence
  $badRecoveryResult = Invoke-Verifier @("-RecoveryEvidencePath", $badRecoveryEvidence)
  Require-ExpectedFailure $badRecoveryResult "origin recovery evidence normalized-LF hash mismatch" "origin recovery file mutation proof"

  $badStateMarkerEvidence = Join-Path $tempRoot "origin-state-marker-corrupt.md"
  Write-Utf8NoBom ($stateRaw.Replace("Fresh search workflow found and selected 7 intended exact IDs:", "Fresh marker removed:")) $badStateMarkerEvidence
  $badStateMarkerResult = Invoke-Verifier @("-StateEvidencePath", $badStateMarkerEvidence)
  Require-ExpectedFailure $badStateMarkerResult "origin state evidence marker must appear exactly once" "origin source marker mutation proof"

  $badOriginMarkerObservations = Join-Path $tempRoot "observations-origin-marker-drift.json"
  $badOriginMarkerManifest = Join-Path $tempRoot "manifest-origin-marker-drift.json"
  $badOriginMarkerObject = Get-Content -LiteralPath $observations -Raw -Encoding UTF8 | ConvertFrom-Json
  $badOriginMarkerObject.origin_evidence.fresh_selection_and_contamination.markers.fresh_selected = "Fresh marker drift"
  Write-Json $badOriginMarkerObject $badOriginMarkerObservations
  New-ManifestFor $badOriginMarkerManifest -ObservationsPath $badOriginMarkerObservations
  $badOriginMarkerResult = Invoke-Verifier @("-ObservationsPath", $badOriginMarkerObservations, "-ManifestPath", $badOriginMarkerManifest)
  Require-ExpectedFailure $badOriginMarkerResult "origin state evidence marker 'fresh_selected' drifted" "origin marker spec mutation proof"

  $badOriginHashObservations = Join-Path $tempRoot "observations-origin-hash-drift.json"
  $badOriginHashManifest = Join-Path $tempRoot "manifest-origin-hash-drift.json"
  $badOriginHashObject = Get-Content -LiteralPath $observations -Raw -Encoding UTF8 | ConvertFrom-Json
  $badOriginHashObject.origin_evidence.fresh_selection_and_contamination.normalized_lf_sha256 = "0" * 64
  Write-Json $badOriginHashObject $badOriginHashObservations
  New-ManifestFor $badOriginHashManifest -ObservationsPath $badOriginHashObservations
  $badOriginHashResult = Invoke-Verifier @("-ObservationsPath", $badOriginHashObservations, "-ManifestPath", $badOriginHashManifest)
  Require-ExpectedFailure $badOriginHashResult "origin state evidence path or normalized-LF hash spec drifted" "origin hash spec mutation proof"

  $badDerivedObservations = Join-Path $tempRoot "observations-origin-negative-drift.json"
  $badDerivedEvidence = Join-Path $tempRoot "evidence-origin-negative-drift.md"
  $badDerivedManifest = Join-Path $tempRoot "manifest-origin-negative-drift.json"
  $badDerivedObject = Get-Content -LiteralPath $observations -Raw -Encoding UTF8 | ConvertFrom-Json
  $badDerivedObject.negative_candidate_ids[1].id = "221077"
  Write-Json $badDerivedObject $badDerivedObservations
  Write-Utf8NoBom ((Get-Content -LiteralPath $evidence -Raw -Encoding UTF8).Replace("NEGATIVE|unmapped|221076|stale_prior_live_state", "NEGATIVE|unmapped|221077|stale_prior_live_state")) $badDerivedEvidence
  New-ManifestFor $badDerivedManifest -ObservationsPath $badDerivedObservations -EvidencePath $badDerivedEvidence
  $badDerivedResult = Invoke-Verifier @("-ObservationsPath", $badDerivedObservations, "-EvidenceContractPath", $badDerivedEvidence, "-ManifestPath", $badDerivedManifest)
  Require-ExpectedFailure $badDerivedResult "negative candidate observations must equal persisted-minus-fresh origin evidence" "origin negative derivation proof"

  $badPriorObservations = Join-Path $tempRoot "observations-origin-prior-order-drift.json"
  $badPriorEvidence = Join-Path $tempRoot "evidence-origin-prior-order-drift.md"
  $badPriorManifest = Join-Path $tempRoot "manifest-origin-prior-order-drift.json"
  $badPriorObject = Get-Content -LiteralPath $observations -Raw -Encoding UTF8 | ConvertFrom-Json
  $badPriorObject.quarantined_records[0].candidate_hint_ids = @("229338")
  Write-Json $badPriorObject $badPriorObservations
  Write-Utf8NoBom ((Get-Content -LiteralPath $evidence -Raw -Encoding UTF8).Replace("HINT_ONLY|goguk2-print2::1|229337|prior_candidate_map_only", "HINT_ONLY|goguk2-print2::1|229338|prior_candidate_map_only")) $badPriorEvidence
  New-ManifestFor $badPriorManifest -ObservationsPath $badPriorObservations -EvidencePath $badPriorEvidence
  $badPriorResult = Invoke-Verifier @("-ObservationsPath", $badPriorObservations, "-EvidenceContractPath", $badPriorEvidence, "-ManifestPath", $badPriorManifest)
  Require-ExpectedFailure $badPriorResult "does not match its ordered origin prior-map ID" "origin prior-map order proof"

  $missingRationaleGold = Join-Path $tempRoot "gold-missing-rationale.json"
  $missingRationale = Get-Content -LiteralPath $gold -Raw -Encoding UTF8 | ConvertFrom-Json
  $missingRationale.records[2].body_exact_rationale = ""
  Write-Json $missingRationale $missingRationaleGold
  $missingRationaleResult = Invoke-Verifier @("-GoldPath", $missingRationaleGold)
  Require-ExpectedFailure $missingRationaleResult "body_exact_rationale must be a nonblank string" "missing-rationale proof"

  $weakObservations = Join-Path $tempRoot "observations-weak-evidence.json"
  $weakManifest = Join-Path $tempRoot "manifest-weak-evidence.json"
  $weakObject = Get-Content -LiteralPath $observations -Raw -Encoding UTF8 | ConvertFrom-Json
  $weakObject.scoreable_records[0].evidence_level = "hint_only_prior_candidate_map"
  Write-Json $weakObject $weakObservations
  New-ManifestFor $weakManifest -ObservationsPath $weakObservations
  $weakResult = Invoke-Verifier @("-ObservationsPath", $weakObservations, "-ManifestPath", $weakManifest)
  Require-ExpectedFailure $weakResult "lacks fresh_selected_exact evidence" "nonblank-rationale-with-weak-evidence proof"

  $staleGold = Join-Path $tempRoot "gold-stale-id.json"
  $staleManifest = Join-Path $tempRoot "manifest-stale-id.json"
  $staleObject = Get-Content -LiteralPath $gold -Raw -Encoding UTF8 | ConvertFrom-Json
  $staleObject.records[2].expected_body_exact_ids = @("991190")
  Write-Json $staleObject $staleGold
  New-ManifestFor $staleManifest -GoldPath $staleGold
  $staleResult = Invoke-Verifier @("-GoldPath", $staleGold, "-ManifestPath", $staleManifest)
  Require-ExpectedFailure $staleResult "scoreable gold uses negative or stale candidate ID '991190'" "stale-ID negative evidence proof"

  $badFixtureObservations = Join-Path $tempRoot "observations-bad-fixture-hash.json"
  $badFixtureManifest = Join-Path $tempRoot "manifest-bad-fixture-hash.json"
  $badFixtureObject = Get-Content -LiteralPath $observations -Raw -Encoding UTF8 | ConvertFrom-Json
  $badFixtureObject.scoreable_records[0].source_fixture_sha256 = "0" * 64
  Write-Json $badFixtureObject $badFixtureObservations
  New-ManifestFor $badFixtureManifest -ObservationsPath $badFixtureObservations
  $badFixtureResult = Invoke-Verifier @("-ObservationsPath", $badFixtureObservations, "-ManifestPath", $badFixtureManifest)
  Require-ExpectedFailure $badFixtureResult "source fixture for goguk2-print2::3 hash mismatch" "source-fixture provenance proof"

  $dependentBlind = Join-Path $tempRoot "blinded-dependent-clue-mutation.json"
  $dependentObservations = Join-Path $tempRoot "observations-dependent-clue-mutation.json"
  $dependentManifest = Join-Path $tempRoot "manifest-dependent-clue-mutation.json"
  $dependentBlindObject = Get-Content -LiteralPath $blinded -Raw -Encoding UTF8 | ConvertFrom-Json
  $dependentObservationObject = Get-Content -LiteralPath $observations -Raw -Encoding UTF8 | ConvertFrom-Json
  $dependentBlindObject.records[2].korean_clues = @("DELIBERATELY FALSE SOURCE BODY", "NOT PRESENT IN PINNED IMAGE")
  $dependentBlindObject.records[2].formula_or_figure_clue = "FALSE FORMULA 1+1=3"
  $dependentObservationObject.scoreable_records[0].source_clues = @("DELIBERATELY FALSE SOURCE BODY", "NOT PRESENT IN PINNED IMAGE")
  $dependentObservationObject.scoreable_records[0].formula_or_figure_clue = "FALSE FORMULA 1+1=3"
  Write-Json $dependentBlindObject $dependentBlind
  Write-Json $dependentObservationObject $dependentObservations
  New-ManifestFor $dependentManifest -BlindPath $dependentBlind -ObservationsPath $dependentObservations
  $dependentMutationResult = Invoke-Verifier @("-BlindedPath", $dependentBlind, "-ObservationsPath", $dependentObservations, "-ManifestPath", $dependentManifest)
  Require-ExpectedSuccess $dependentMutationResult "truth_scope=dated-characterization independent_body_oracle=false" "coherent dependent mutation claim-boundary proof"
  if ($dependentMutationResult.Output -like "*verdict=SUCCESS*" -or $dependentMutationResult.Output -like "*truth_scope=external-ground-truth*") {
    throw "TASK8_TEST: coherent dependent mutation was promoted beyond corpus consistency."
  }

  $badMetadataObservations = Join-Path $tempRoot "observations-bad-metadata.json"
  $badMetadataManifest = Join-Path $tempRoot "manifest-bad-metadata.json"
  $badMetadataObject = Get-Content -LiteralPath $observations -Raw -Encoding UTF8 | ConvertFrom-Json
  $badMetadataObject.scoreable_records[0].candidate_metadata_tokens[1] = "definitely-not-in-candidate"
  Write-Json $badMetadataObject $badMetadataObservations
  New-ManifestFor $badMetadataManifest -ObservationsPath $badMetadataObservations
  $badMetadataResult = Invoke-Verifier @("-ObservationsPath", $badMetadataObservations, "-ManifestPath", $badMetadataManifest)
  Require-ExpectedFailure $badMetadataResult "is missing metadata token 'definitely-not-in-candidate'" "candidate identity proof"

  $badEvidence = Join-Path $tempRoot "evidence-missing-marker.md"
  $badEvidenceManifest = Join-Path $tempRoot "manifest-missing-marker.json"
  (Get-Content -LiteralPath $evidence -Raw -Encoding UTF8).Replace("SCOREABLE|goguk2-print2::3|1475258|fresh_selected_exact", "SCOREABLE_MARKER_REMOVED") | Set-Content -LiteralPath $badEvidence -Encoding UTF8
  New-ManifestFor $badEvidenceManifest -EvidencePath $badEvidence
  $badEvidenceResult = Invoke-Verifier @("-EvidenceContractPath", $badEvidence, "-ManifestPath", $badEvidenceManifest)
  Require-ExpectedFailure $badEvidenceResult "marker must appear exactly once" "evidence marker proof"

  $malformedGold = Join-Path $tempRoot "gold-malformed.json"
  '{"schema_version":' | Set-Content -LiteralPath $malformedGold -Encoding UTF8
  $malformedResult = Invoke-Verifier @("-GoldPath", $malformedGold)
  Require-ExpectedFailure $malformedResult "not valid JSON" "malformed-gold probe"

  $nestedLeakBlind = Join-Path $tempRoot "blinded-nested-gold-leak.json"
  $nestedLeakObject = Get-Content -LiteralPath $blinded -Raw -Encoding UTF8 | ConvertFrom-Json
  $nestedLeakObject.records[0].source_metadata | Add-Member -NotePropertyName "nested_audit" -NotePropertyValue ([pscustomobject]@{ probes = @([pscustomobject]@{ opaque_note = "1475258" }) })
  Write-Json $nestedLeakObject $nestedLeakBlind
  $nestedLeakResult = Invoke-Verifier @("-BlindedPath", $nestedLeakBlind)
  Require-ExpectedFailure $nestedLeakResult "leaks scorer-only gold ID '1475258'" "nested-gold-ID leak probe"

  $nestedFieldBlind = Join-Path $tempRoot "blinded-nested-candidate-field.json"
  $nestedFieldObject = Get-Content -LiteralPath $blinded -Raw -Encoding UTF8 | ConvertFrom-Json
  $nestedFieldObject.records[0].source_metadata | Add-Member -NotePropertyName "nested_source" -NotePropertyValue ([pscustomobject]@{ id_candidate = "not-a-gold-id" })
  Write-Json $nestedFieldObject $nestedFieldBlind
  $nestedFieldResult = Invoke-Verifier @("-BlindedPath", $nestedFieldBlind)
  Require-ExpectedFailure $nestedFieldResult "leaks forbidden scorer-ID field 'id_candidate'" "nested-candidate-field probe"

  $manifestObject = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
  $goldObject = Get-Content -LiteralPath $gold -Raw -Encoding UTF8 | ConvertFrom-Json
  $correctRecords = @()
  $wrongRecords = @()
  foreach ($goldRecord in $goldObject.records) {
    if ($goldRecord.expected_match_state -eq "unscored_no_offline_gold") { continue }
    $recordKey = "$($goldRecord.source_key)::$($goldRecord.source_order)"
    $correctRecords += [pscustomobject]@{
      record_key = $recordKey
      selected_ids = @($goldRecord.expected_body_exact_ids)
      body_only_preflight_rationale = "Blind-run probe: source body constraints and the requested value were compared before reporting the candidate."
    }
    $wrongRecords += [pscustomobject]@{
      record_key = $recordKey
      selected_ids = @("999999999")
      body_only_preflight_rationale = "Intentional nonmatching candidate used to test the success gate."
    }
  }

  $misleadingSubmission = Join-Path $tempRoot "misleading-success.json"
  Write-Json ([pscustomobject]@{ corpus_id = $goldObject.corpus_id; blinded_sha256 = $manifestObject.blinded_sha256; status = "success"; records = @($correctRecords[0]) }) $misleadingSubmission 8
  $misleadingResult = Invoke-Verifier @("-SubmissionPath", $misleadingSubmission)
  Require-ExpectedFailure $misleadingResult "claims success but exactly matched 1 of 7 scoreable records" "misleading-success probe"

  $wrongSubmission = Join-Path $tempRoot "wrong-complete-success.json"
  Write-Json ([pscustomobject]@{ corpus_id = $goldObject.corpus_id; blinded_sha256 = $manifestObject.blinded_sha256; status = "success"; records = $wrongRecords }) $wrongSubmission 8
  $wrongResult = Invoke-Verifier @("-SubmissionPath", $wrongSubmission)
  Require-ExpectedFailure $wrongResult "claims success but exactly matched 0 of 7 scoreable records" "complete-wrong-ID success probe"

  $correctSubmission = Join-Path $tempRoot "correct-complete-success.json"
  Write-Json ([pscustomobject]@{ corpus_id = $goldObject.corpus_id; blinded_sha256 = $manifestObject.blinded_sha256; status = "success"; records = $correctRecords }) $correctSubmission 8
  $correctResult = Invoke-Verifier @("-SubmissionPath", $correctSubmission)
  Require-ExpectedSuccess $correctResult "TASK8_SCORE: verdict=CORPUS_MATCH status=success exact=7/7 submitted_scoreable=7 submitted_quarantined=0 non_exact=0 unsubmitted_scoreable=0 quarantined=16" "complete-correct-ID corpus-match probe"

  $partialSubmission = Join-Path $tempRoot "partial.json"
  Write-Json ([pscustomobject]@{ corpus_id = $goldObject.corpus_id; blinded_sha256 = $manifestObject.blinded_sha256; status = "partial"; records = @($correctRecords[0]) }) $partialSubmission 8
  $partialResult = Invoke-Verifier @("-SubmissionPath", $partialSubmission)
  Require-ExpectedSuccess $partialResult "verdict=CORPUS_NON_MATCH status=partial exact=1/7 submitted_scoreable=1 submitted_quarantined=0" "partial metrics probe"

  $quarantinedSubmission = Join-Path $tempRoot "quarantined-partial.json"
  $quarantinedRecord = [pscustomobject]@{ record_key = "goguk2-print2::1"; selected_ids = @("229337"); body_only_preflight_rationale = "Blind runner reported a candidate; scorer retains it as unscored because the offline gold is quarantined." }
  Write-Json ([pscustomobject]@{ corpus_id = $goldObject.corpus_id; blinded_sha256 = $manifestObject.blinded_sha256; status = "partial"; records = @($quarantinedRecord) }) $quarantinedSubmission 8
  $quarantinedResult = Invoke-Verifier @("-SubmissionPath", $quarantinedSubmission)
  Require-ExpectedSuccess $quarantinedResult "submitted_scoreable=0 submitted_quarantined=1" "quarantined submission metrics probe"

  $noMatchSubmission = Join-Path $tempRoot "no-match.json"
  Write-Json ([pscustomobject]@{ corpus_id = $goldObject.corpus_id; blinded_sha256 = $manifestObject.blinded_sha256; status = "no_match"; records = @() }) $noMatchSubmission 8
  $noMatchResult = Invoke-Verifier @("-SubmissionPath", $noMatchSubmission)
  Require-ExpectedSuccess $noMatchResult "verdict=CORPUS_NON_MATCH status=no_match exact=0/7" "no-match metrics probe"

  $missingRecordsSubmission = Join-Path $tempRoot "no-match-missing-records.json"
  Write-Json ([pscustomobject]@{ corpus_id = $goldObject.corpus_id; blinded_sha256 = $manifestObject.blinded_sha256; status = "no_match" }) $missingRecordsSubmission 8
  $missingRecordsResult = Invoke-Verifier @("-SubmissionPath", $missingRecordsSubmission)
  Require-ExpectedFailure $missingRecordsResult "missing required property 'records'" "missing submission records probe"

  $goldHashSubmission = Join-Path $tempRoot "gold-hash-leak.json"
  Write-Json ([pscustomobject]@{ corpus_id = $goldObject.corpus_id; blinded_sha256 = $manifestObject.blinded_sha256; gold_sha256 = $manifestObject.gold_sha256; status = "no_match"; records = @() }) $goldHashSubmission 8
  $goldHashResult = Invoke-Verifier @("-SubmissionPath", $goldHashSubmission)
  Require-ExpectedFailure $goldHashResult "forbidden scorer-only field 'gold_sha256'" "gold-hash submission leak probe"

  $nestedExpectedSubmission = Join-Path $tempRoot "nested-expected-field-leak.json"
  Write-Json ([pscustomobject]@{
      corpus_id = $goldObject.corpus_id
      blinded_sha256 = $manifestObject.blinded_sha256
      status = "no_match"
      records = @()
      diagnostics = [pscustomobject]@{ expected_body_exact_ids = @("1475258") }
    }) $nestedExpectedSubmission 8
  $nestedExpectedResult = Invoke-Verifier @("-SubmissionPath", $nestedExpectedSubmission)
  Require-ExpectedFailure $nestedExpectedResult "forbidden scorer-only field 'expected_body_exact_ids'" "nested expected-field submission leak probe"

  $exportDir = Join-Path $tempRoot "blind-export"
  $exportResult = Invoke-Child $exporter @("-ProjectRoot", $ProjectRoot, "-OutDir", $exportDir)
  Require-ExpectedSuccess $exportResult "TASK8_EXPORT: PASS" "blind export"
  $exportFiles = @(Get-ChildItem -LiteralPath $exportDir -File | Sort-Object Name)
  if ($exportFiles.Count -ne 2) { throw "TASK8_TEST: blind export did not contain exactly two files." }
  $exportText = ($exportFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
  if ($exportText -like "*$($manifestObject.gold_sha256)*" -or $exportText -like "*1475258*") {
    throw "TASK8_TEST: blind export leaked scorer-only gold hash or ID."
  }
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $resolvedTemp.StartsWith($resolvedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "TASK8_TEST: refusing to clean a path outside the temporary directory."
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}

$ownedSnapshotAfter = Get-OwnedPathSnapshot $ownedPaths
if (($ownedSnapshotBefore -join "`n") -cne ($ownedSnapshotAfter -join "`n")) {
  throw "TASK8_TEST: benchmark tests changed the existence or SHA-256 of owned paths."
}

Write-Output "TASK8_TEST: PASS baseline=2 scoreable=7 quarantined=16 origin_files=detected origin_source_marker=detected origin_marker_spec=detected origin_hash=detected origin_negative_derivation=detected origin_prior_order=detected normalized_lf=accepted weak_evidence=detected stale_id=detected source_hash=detected coherent_dependent_mutation=bounded candidate_identity=detected evidence_marker=detected malformed=detected nested_leaks=detected misleading_success=detected complete_wrong_success=detected complete_correct_corpus_match=reported partial_metrics=reported quarantined_metrics=reported no_match_metrics=reported missing_records=detected submission_scorer_leaks=detected blind_export=gold_free owned_paths=unchanged"
