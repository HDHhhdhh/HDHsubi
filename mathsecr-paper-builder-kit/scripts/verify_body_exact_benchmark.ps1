[CmdletBinding()]
param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$BlindedPath,
  [string]$GoldPath,
  [string]$ManifestPath,
  [string]$ObservationsPath,
  [string]$EvidenceContractPath,
  [string]$StateEvidencePath,
  [string]$RecoveryEvidencePath,
  [string]$GroundTruthRegistryPath,
  [string]$SubmissionPath
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

function Stop-Verify {
  param([string]$Message)
  throw "TASK8_VERIFY: $Message"
}

function Test-HasProperty {
  param($Object, [string]$Name)
  return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Require-Property {
  param($Object, [string]$Name, [string]$Context)
  if (-not (Test-HasProperty $Object $Name)) {
    Stop-Verify "$Context is missing required property '$Name'."
  }
  return $Object.PSObject.Properties[$Name].Value
}

function Require-NonBlankString {
  param($Value, [string]$Context)
  if ($null -eq $Value -or $Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
    Stop-Verify "$Context must be a nonblank string."
  }
  return $Value.Trim()
}

function Read-JsonDocument {
  param([string]$Path, [string]$Label)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Stop-Verify "$Label file does not exist: $Path"
  }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
      Stop-Verify "$Label is empty: $Path"
    }
    return $raw | ConvertFrom-Json
  } catch {
    if ($_.Exception.Message -like "TASK8_VERIFY:*") { throw }
    Stop-Verify "$Label is not valid JSON: $Path ($($_.Exception.Message))"
  }
}

function Read-TextDocument {
  param([string]$Path, [string]$Label)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Stop-Verify "$Label file does not exist: $Path"
  }
  $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($text)) {
    Stop-Verify "$Label is empty: $Path"
  }
  return $text
}

function Assert-ExactStringArray {
  param($Actual, [string[]]$Expected, [string]$Context)
  $actualItems = @($Actual)
  if ($actualItems.Count -ne $Expected.Count) {
    Stop-Verify "$Context count differs from the contract."
  }
  for ($index = 0; $index -lt $Expected.Count; $index++) {
    if ($actualItems[$index] -isnot [string] -or $actualItems[$index] -cne $Expected[$index]) {
      Stop-Verify "$Context differs from the contract at index $index."
    }
  }
}

function Get-RecordKey {
  param($Record, [string]$Context)
  $sourceKey = Require-NonBlankString (Require-Property $Record "source_key" $Context) "$Context.source_key"
  $sourceOrder = Require-Property $Record "source_order" $Context
  if (($sourceOrder -isnot [int] -and $sourceOrder -isnot [long]) -or [long]$sourceOrder -lt 1) {
    Stop-Verify "$Context.source_order must be a positive integer."
  }
  return "$sourceKey::$sourceOrder"
}

function Get-FileSha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-NormalizedLfText {
  param([string]$Text)
  return ($Text -replace "`r`n", "`n") -replace "`r", "`n"
}

function Get-NormalizedLfSha256 {
  param([string]$Text)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  $bytes = $encoding.GetBytes((Get-NormalizedLfText $Text))
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
  } finally {
    $sha.Dispose()
  }
}

function Get-IdsAfterMarker {
  param([string]$Text, [string]$Marker, [string]$Context)
  $normalized = Get-NormalizedLfText $Text
  $index = $normalized.IndexOf($Marker, [System.StringComparison]::Ordinal)
  if ($index -lt 0) { Stop-Verify "$Context marker is absent." }
  $tail = $normalized.Substring($index + $Marker.Length)
  $end = $tail.IndexOf(".", [System.StringComparison]::Ordinal)
  if ($end -lt 0) { Stop-Verify "$Context marker has no terminating evidence sentence." }
  $segment = $tail.Substring(0, $end)
  $ids = @([regex]::Matches($segment, "(?<![0-9])[0-9]+(?![0-9])") | ForEach-Object { $_.Value })
  if ($ids.Count -eq 0) { Stop-Verify "$Context marker has no numeric IDs." }
  return $ids
}

function Get-IdsOnMarkerLine {
  param([string]$Text, [string]$Marker, [string]$Context)
  $lines = @((Get-NormalizedLfText $Text).Split("`n") | Where-Object { $_.Contains($Marker) })
  if ($lines.Count -ne 1) { Stop-Verify "$Context marker must identify exactly one line." }
  $ids = @([regex]::Matches($lines[0], "(?<![0-9])[0-9]+(?![0-9])") | ForEach-Object { $_.Value })
  if ($ids.Count -eq 0) { Stop-Verify "$Context marker line has no numeric IDs." }
  return $ids
}

function Assert-UniqueNumericIds {
  param([string[]]$Ids, [int]$ExpectedCount, [string]$Context)
  if ($Ids.Count -ne $ExpectedCount) { Stop-Verify "$Context must contain exactly $ExpectedCount IDs." }
  $seen = @{}
  foreach ($id in $Ids) {
    if ($id -notmatch "^[0-9]+$" -or $seen.ContainsKey($id)) { Stop-Verify "$Context contains a malformed or repeated ID '$id'." }
    $seen[$id] = $true
  }
}

function Assert-Sha256 {
  param([string]$Actual, [string]$Expected, [string]$Context)
  if ($Expected -notmatch "^[A-Fa-f0-9]{64}$") {
    Stop-Verify "$Context expected hash is not a SHA-256 hexadecimal digest."
  }
  if ($Actual.ToUpperInvariant() -cne $Expected.ToUpperInvariant()) {
    Stop-Verify "$Context hash mismatch: expected=$Expected actual=$Actual."
  }
}

function Resolve-ProjectRelativeFile {
  param([string]$RelativePath, [string]$Context)
  $relative = Require-NonBlankString $RelativePath $Context
  if ([System.IO.Path]::IsPathRooted($relative) -or $relative -match "(^|[\\/])\.\.([\\/]|$)") {
    Stop-Verify "$Context must be a repository-relative path without parent traversal."
  }
  $full = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot ($relative -replace "/", "\")))
  $rootPrefix = $ProjectRoot.TrimEnd("\") + "\"
  if (-not $full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-Verify "$Context resolves outside ProjectRoot."
  }
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    Stop-Verify "$Context does not exist: $relative"
  }
  return $full
}

function Assert-MarkerOnce {
  param([string]$Text, [string]$Marker, [string]$Context)
  $count = ([regex]::Matches($Text, [regex]::Escape($Marker))).Count
  if ($count -ne 1) {
    Stop-Verify "$Context marker must appear exactly once: $Marker (found $count)."
  }
}

function Test-ExactIdSet {
  param([string[]]$Actual, [string[]]$Expected)
  if ($Actual.Count -ne $Expected.Count) { return $false }
  $actualSet = @{}
  foreach ($id in $Actual) { $actualSet[$id] = $true }
  foreach ($id in $Expected) {
    if (-not $actualSet.ContainsKey($id)) { return $false }
  }
  return $true
}

function Test-ForbiddenBlindedPropertyName {
  param([string]$Name)
  $tokenizedName = $Name -replace "([a-z0-9])([A-Z])", '$1 $2' -replace "[^A-Za-z0-9]+", " "
  $tokens = @($tokenizedName.ToLowerInvariant().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries))
  $normalized = $tokens -join ""
  if ($normalized -in @("expectedmatchstate", "expectedbodyexactids", "bodyexactrationale", "multiexactrationale")) { return $true }
  $semanticTokens = @("candidate", "expected", "gold", "selected", "target")
  $idTokens = @("id", "ids", "identifier", "identifiers", "cellid", "cellids")
  if (@($tokens | Where-Object { $_ -in $semanticTokens }).Count -gt 0 -and @($tokens | Where-Object { $_ -in $idTokens }).Count -gt 0) { return $true }
  foreach ($semanticToken in $semanticTokens) {
    foreach ($idToken in $idTokens) {
      if ($normalized -eq "$semanticToken$idToken" -or $normalized -eq "$idToken$semanticToken") { return $true }
      if ($normalized -match "^$semanticToken$idToken(map|maps|list|lists|set|sets|value|values|by|record|records|field|fields|provenance|reference|references)$") { return $true }
      if ($normalized -match "^$idToken$semanticToken(map|maps|list|lists|set|sets|value|values|by|record|records|field|fields|provenance|reference|references)$") { return $true }
    }
  }
  return $false
}

function Assert-NoScorerDataInBlindedValue {
  param($Value, [hashtable]$GoldIds, [string]$Path)
  if ($null -eq $Value) { return }
  if ($Value -is [string]) {
    foreach ($goldId in $GoldIds.Keys) {
      if ($Value -like "*$goldId*") { Stop-Verify "blinded corpus leaks scorer-only gold ID '$goldId' at $Path." }
    }
    return
  }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]) {
    $scalar = [string]$Value
    if ($GoldIds.ContainsKey($scalar)) { Stop-Verify "blinded corpus leaks scorer-only gold ID '$scalar' at $Path." }
    return
  }
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($propertyName in $Value.Keys) {
      $propertyPath = "$Path.$propertyName"
      if (Test-ForbiddenBlindedPropertyName ([string]$propertyName)) { Stop-Verify "blinded corpus leaks forbidden scorer-ID field '$propertyName' at $propertyPath." }
      Assert-NoScorerDataInBlindedValue $Value[$propertyName] $GoldIds $propertyPath
    }
    return
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    $itemIndex = 0
    foreach ($item in $Value) {
      Assert-NoScorerDataInBlindedValue $item $GoldIds "${Path}[$itemIndex]"
      $itemIndex++
    }
    return
  }
  foreach ($property in $Value.PSObject.Properties) {
    $propertyPath = "$Path.$($property.Name)"
    if (Test-ForbiddenBlindedPropertyName $property.Name) { Stop-Verify "blinded corpus leaks forbidden scorer-ID field '$($property.Name)' at $propertyPath." }
    Assert-NoScorerDataInBlindedValue $property.Value $GoldIds $propertyPath
  }
}

function Test-ForbiddenSubmissionPropertyName {
  param([string]$Name)
  $tokenized = [regex]::Replace($Name, "([a-z0-9])([A-Z])", '$1_$2')
  $normalized = ([regex]::Replace($tokenized, "[^A-Za-z0-9]+", "_")).Trim("_").ToLowerInvariant()
  if ($normalized -eq "gold_sha256" -or $normalized.StartsWith("expected_")) { return $true }
  if ($normalized -in @("body_exact_rationale", "multi_exact_rationale")) { return $true }
  return $false
}

function Assert-NoScorerFieldsInSubmission {
  param($Value, [string]$Path)
  if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsValueType) { return }
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($name in $Value.Keys) {
      if (Test-ForbiddenSubmissionPropertyName ([string]$name)) {
        Stop-Verify "benchmark submission contains forbidden scorer-only field '$name' at $Path.$name."
      }
      Assert-NoScorerFieldsInSubmission $Value[$name] "$Path.$name"
    }
    return
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    $index = 0
    foreach ($item in $Value) {
      Assert-NoScorerFieldsInSubmission $item "${Path}[$index]"
      $index++
    }
    return
  }
  foreach ($property in $Value.PSObject.Properties) {
    if (Test-ForbiddenSubmissionPropertyName $property.Name) {
      Stop-Verify "benchmark submission contains forbidden scorer-only field '$($property.Name)' at $Path.$($property.Name)."
    }
    Assert-NoScorerFieldsInSubmission $property.Value "$Path.$($property.Name)"
  }
}

function Assert-ExactObjectShape {
  param($Value, [string[]]$RequiredProperties, [string]$Context)
  if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
    Stop-Verify "$Context must be a JSON object."
  }
  $actual = @($Value.PSObject.Properties.Name)
  foreach ($required in $RequiredProperties) {
    if ($actual -notcontains $required) { Stop-Verify "$Context is missing required property '$required'." }
  }
  foreach ($name in $actual) {
    if ($RequiredProperties -notcontains $name) { Stop-Verify "$Context contains unsupported property '$name'." }
  }
}

$docsDir = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\docs"
if (-not $BlindedPath) { $BlindedPath = Join-Path $docsDir "body_exact_benchmark_blinded.json" }
if (-not $GoldPath) { $GoldPath = Join-Path $docsDir "body_exact_benchmark_gold.json" }
if (-not $ManifestPath) { $ManifestPath = Join-Path $docsDir "body_exact_benchmark_manifest.json" }
if (-not $ObservationsPath) { $ObservationsPath = Join-Path $docsDir "body_exact_benchmark_observations.json" }
if (-not $EvidenceContractPath) { $EvidenceContractPath = Join-Path $docsDir "body_exact_benchmark_evidence.md" }
if (-not $GroundTruthRegistryPath) { $GroundTruthRegistryPath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\evaluation\ground-truth-claims.json" }

$groundTruthContract = Join-Path $PSScriptRoot "ground_truth_contract.ps1"
if (-not (Test-Path -LiteralPath $groundTruthContract -PathType Leaf)) { Stop-Verify "ground-truth contract is missing: $groundTruthContract" }
. $groundTruthContract
try {
  $groundTruthSummary = Test-MathSecrGroundTruthRegistry -RegistryPath $GroundTruthRegistryPath -ProjectRoot $ProjectRoot
} catch {
  Stop-Verify "ground-truth registry rejected the scorer boundary: $($_.Exception.Message)"
}
$bodyTruthClaim = @($groundTruthSummary.Claims | Where-Object { $_.Id -ceq 'body-exact-corpus-scoring' })
if ($bodyTruthClaim.Count -ne 1 -or $bodyTruthClaim[0].ClaimClass -cne 'dated-characterization' -or $bodyTruthClaim[0].IndependentOracleComplete) {
  Stop-Verify "body-exact scoring must remain a dated characterization until its independent body oracle is complete."
}

$blinded = Read-JsonDocument $BlindedPath "blinded corpus"
$gold = Read-JsonDocument $GoldPath "scorer-only gold corpus"
$manifest = Read-JsonDocument $ManifestPath "hash manifest"
$observations = Read-JsonDocument $ObservationsPath "scorer-only observations"
$evidenceText = Read-TextDocument $EvidenceContractPath "scorer-only evidence contract"

foreach ($document in @(
  @{ Name = "blinded corpus"; Value = $blinded },
  @{ Name = "scorer-only gold corpus"; Value = $gold },
  @{ Name = "scorer-only observations"; Value = $observations }
)) {
  $schemaVersion = Require-Property $document.Value "schema_version" $document.Name
  if ($schemaVersion -ne 2) { Stop-Verify "$($document.Name).schema_version must equal 2." }
  [void](Require-NonBlankString (Require-Property $document.Value "corpus_id" $document.Name) "$($document.Name).corpus_id")
}
if ($blinded.corpus_id -cne $gold.corpus_id -or $gold.corpus_id -cne $observations.corpus_id) {
  Stop-Verify "blinded, gold, and observations corpus_id values differ."
}

if ((Require-Property $observations "origin_evidence_contract_version" "scorer-only observations") -ne 1) {
  Stop-Verify "observations.origin_evidence_contract_version must equal 1."
}
$originEvidence = Require-Property $observations "origin_evidence" "scorer-only observations"
Assert-ExactObjectShape $originEvidence @("fresh_selection_and_contamination", "prior_candidate_map") "observations.origin_evidence"
$stateSpec = Require-Property $originEvidence "fresh_selection_and_contamination" "observations.origin_evidence"
$recoverySpec = Require-Property $originEvidence "prior_candidate_map" "observations.origin_evidence"
Assert-ExactObjectShape $stateSpec @("path", "normalized_lf_sha256", "markers") "observations origin state evidence"
Assert-ExactObjectShape $recoverySpec @("path", "normalized_lf_sha256", "markers") "observations origin recovery evidence"

$expectedStatePath = ".omo/evidence/mathsecr_state_contamination_2026-06-05.md"
$expectedStateHash = "03A1B4E6B0DF75AF983D355CDD24FFF4DDA9BA9556BAEACE0B3409D0ECB061AD"
$expectedRecoveryPath = ".omo/evidence/mathsecr_search_regression_recovery_policy_2026-06-07.md"
$expectedRecoveryHash = "65A8D22C26DA9EC26AD81FE9C1AA844BD187570D278189D2B1EE2B39B002805F"
$expectedStateMarkers = [ordered]@{
  fresh_selected = "Fresh search workflow found and selected 7 intended exact IDs:"
  persisted_after_collapse = 'After `다음 단계`, final edit/persisted state contained only 4 IDs:'
  explicit_stale = "were stale prior live state, not fresh-confirmed exact targets."
  survivor_overlap = 'Only `62005` survived from the fresh selected bundle.'
}
$expectedRecoveryMarkers = [ordered]@{
  ordered_ids = "- Prior search-UI target IDs:"
  hint_only_authority = "The map is a recovery aid for the same PDF/source, not a rule to blindly select IDs."
}

if ((Require-NonBlankString $stateSpec.path "origin state evidence path") -cne $expectedStatePath -or
    (Require-NonBlankString $stateSpec.normalized_lf_sha256 "origin state evidence hash").ToUpperInvariant() -cne $expectedStateHash) {
  Stop-Verify "origin state evidence path or normalized-LF hash spec drifted from the pinned contract."
}
if ((Require-NonBlankString $recoverySpec.path "origin recovery evidence path") -cne $expectedRecoveryPath -or
    (Require-NonBlankString $recoverySpec.normalized_lf_sha256 "origin recovery evidence hash").ToUpperInvariant() -cne $expectedRecoveryHash) {
  Stop-Verify "origin recovery evidence path or normalized-LF hash spec drifted from the pinned contract."
}
Assert-ExactObjectShape $stateSpec.markers @($expectedStateMarkers.Keys) "origin state evidence markers"
Assert-ExactObjectShape $recoverySpec.markers @($expectedRecoveryMarkers.Keys) "origin recovery evidence markers"
foreach ($name in $expectedStateMarkers.Keys) {
  if ($stateSpec.markers.$name -cne $expectedStateMarkers[$name]) { Stop-Verify "origin state evidence marker '$name' drifted from the pinned contract." }
}
foreach ($name in $expectedRecoveryMarkers.Keys) {
  if ($recoverySpec.markers.$name -cne $expectedRecoveryMarkers[$name]) { Stop-Verify "origin recovery evidence marker '$name' drifted from the pinned contract." }
}

$canonicalStateEvidence = Resolve-ProjectRelativeFile $stateSpec.path "origin state evidence path"
$canonicalRecoveryEvidence = Resolve-ProjectRelativeFile $recoverySpec.path "origin recovery evidence path"
$resolvedStateEvidence = if ($StateEvidencePath) { [System.IO.Path]::GetFullPath($StateEvidencePath) } else { $canonicalStateEvidence }
$resolvedRecoveryEvidence = if ($RecoveryEvidencePath) { [System.IO.Path]::GetFullPath($RecoveryEvidencePath) } else { $canonicalRecoveryEvidence }
if (-not (Test-Path -LiteralPath $resolvedStateEvidence -PathType Leaf)) { Stop-Verify "origin state evidence file does not exist: $resolvedStateEvidence" }
if (-not (Test-Path -LiteralPath $resolvedRecoveryEvidence -PathType Leaf)) { Stop-Verify "origin recovery evidence file does not exist: $resolvedRecoveryEvidence" }
$stateEvidenceText = Read-TextDocument $resolvedStateEvidence "origin state evidence"
$recoveryEvidenceText = Read-TextDocument $resolvedRecoveryEvidence "origin recovery evidence"
foreach ($marker in $expectedStateMarkers.Values) { Assert-MarkerOnce $stateEvidenceText $marker "origin state evidence" }
foreach ($marker in $expectedRecoveryMarkers.Values) { Assert-MarkerOnce $recoveryEvidenceText $marker "origin recovery evidence" }
Assert-Sha256 (Get-NormalizedLfSha256 $stateEvidenceText) $expectedStateHash "origin state evidence normalized-LF"
Assert-Sha256 (Get-NormalizedLfSha256 $recoveryEvidenceText) $expectedRecoveryHash "origin recovery evidence normalized-LF"

$freshOriginIds = @(Get-IdsAfterMarker $stateEvidenceText $expectedStateMarkers.fresh_selected "origin fresh-selected IDs")
$persistedOriginIds = @(Get-IdsAfterMarker $stateEvidenceText $expectedStateMarkers.persisted_after_collapse "origin persisted IDs")
$explicitStaleOriginIds = @(Get-IdsOnMarkerLine $stateEvidenceText $expectedStateMarkers.explicit_stale "origin explicit stale IDs")
$survivorOriginIds = @(Get-IdsOnMarkerLine $stateEvidenceText $expectedStateMarkers.survivor_overlap "origin survivor overlap")
$priorCandidateIds = @(Get-IdsAfterMarker $recoveryEvidenceText $expectedRecoveryMarkers.ordered_ids "origin prior candidate map")
Assert-UniqueNumericIds $freshOriginIds 7 "origin fresh-selected set"
Assert-UniqueNumericIds $persistedOriginIds 4 "origin persisted-after-collapse set"
Assert-UniqueNumericIds $explicitStaleOriginIds 3 "origin explicit stale set"
Assert-UniqueNumericIds $survivorOriginIds 1 "origin survivor overlap"
Assert-UniqueNumericIds $priorCandidateIds 18 "origin ordered prior candidate map"

$freshOriginSet = @{}
foreach ($id in $freshOriginIds) { $freshOriginSet[$id] = $true }
$derivedOverlapIds = @($persistedOriginIds | Where-Object { $freshOriginSet.ContainsKey($_) })
$derivedNegativeIds = @($persistedOriginIds | Where-Object { -not $freshOriginSet.ContainsKey($_) })
Assert-ExactStringArray $survivorOriginIds $derivedOverlapIds "origin persisted/fresh overlap"
Assert-ExactStringArray $explicitStaleOriginIds $derivedNegativeIds "origin derived stale negatives"
if ($derivedOverlapIds[0] -cne "62005") { Stop-Verify "origin persisted/fresh overlap must be exactly 62005." }

Assert-ExactStringArray (Require-Property $blinded "record_key_fields" "blinded corpus") @("source_key", "source_order") "blinded corpus.record_key_fields"
Assert-ExactStringArray (Require-Property $gold "record_key_fields" "scorer-only gold corpus") @("source_key", "source_order") "scorer-only gold corpus.record_key_fields"

$blindedRecords = @($blinded.records)
$goldRecords = @($gold.records)
if ($blindedRecords.Count -eq 0 -or $blindedRecords.Count -ne $goldRecords.Count) {
  Stop-Verify "blinded and gold record counts must be equal and nonzero."
}

$blindByKey = @{}
$goldByKey = @{}
$orderedKeys = @()
$globalGoldIds = @{}
$scoreableGold = @()
$quarantinedGold = @()
for ($index = 0; $index -lt $blindedRecords.Count; $index++) {
  $blind = $blindedRecords[$index]
  $goldRecord = $goldRecords[$index]
  $blindKey = Get-RecordKey $blind "blinded.records[$index]"
  $goldKey = Get-RecordKey $goldRecord "gold.records[$index]"
  if ($blindKey -cne $goldKey) { Stop-Verify "blinded and gold ordered keys differ at index $index." }
  if ($blindByKey.ContainsKey($blindKey)) { Stop-Verify "corpus repeats ordered key '$blindKey'." }
  $blindByKey[$blindKey] = $blind
  $goldByKey[$goldKey] = $goldRecord
  $orderedKeys += $blindKey

  $pdfPage = Require-Property $blind "pdf_page" "blinded.records[$index]"
  if (($pdfPage -isnot [int] -and $pdfPage -isnot [long]) -or [long]$pdfPage -lt 1) { Stop-Verify "blinded.records[$index].pdf_page must be positive." }
  [void](Require-NonBlankString (Require-Property $blind "visible_number" "blinded.records[$index]") "blinded.records[$index].visible_number")
  $clues = @($blind.korean_clues)
  if ($clues.Count -lt 2) { Stop-Verify "blinded.records[$index].korean_clues must contain at least two strings." }
  foreach ($clue in $clues) { [void](Require-NonBlankString $clue "blinded.records[$index].korean_clues") }
  [void](Require-NonBlankString $blind.formula_or_figure_clue "blinded.records[$index].formula_or_figure_clue")
  [void](Require-NonBlankString $blind.confidence "blinded.records[$index].confidence")

  $state = Require-NonBlankString $goldRecord.expected_match_state "gold.records[$index].expected_match_state"
  $ids = @($goldRecord.expected_body_exact_ids)
  [void](Require-NonBlankString $goldRecord.body_exact_rationale "gold.records[$index].body_exact_rationale")
  if ($state -eq "unique") {
    if ($ids.Count -ne 1) { Stop-Verify "gold.records[$index] unique state requires exactly one ID." }
    $scoreableGold += $goldRecord
  } elseif ($state -eq "multi_exact") {
    if ($ids.Count -lt 2) { Stop-Verify "gold.records[$index] multi_exact state requires two or more IDs." }
    [void](Require-NonBlankString $goldRecord.multi_exact_rationale "gold.records[$index].multi_exact_rationale")
    $scoreableGold += $goldRecord
  } elseif ($state -eq "unscored_no_offline_gold") {
    if ($ids.Count -ne 0) { Stop-Verify "gold.records[$index] quarantined state must not contain IDs." }
    $quarantinedGold += $goldRecord
  } else {
    Stop-Verify "gold.records[$index].expected_match_state is unsupported."
  }
  foreach ($id in $ids) {
    $normalizedId = Require-NonBlankString $id "gold.records[$index].expected_body_exact_ids"
    if ($normalizedId -notmatch "^[0-9]+$") { Stop-Verify "gold.records[$index] contains a nonnumeric ID '$normalizedId'." }
    if ($globalGoldIds.ContainsKey($normalizedId)) { Stop-Verify "gold reuses ID '$normalizedId'." }
    $globalGoldIds[$normalizedId] = $goldKey
  }
}
if ($scoreableGold.Count -eq 0) { Stop-Verify "corpus must retain at least one evidence-backed scoreable record." }
Assert-NoScorerDataInBlindedValue $blinded $globalGoldIds "blinded"

$negativeIds = @{}
$negativeObservationIds = @()
foreach ($negative in @($observations.negative_candidate_ids)) {
  $id = Require-NonBlankString $negative.id "observations.negative_candidate_ids.id"
  $reason = Require-NonBlankString $negative.reason "observations.negative_candidate_ids.reason"
  $recordKey = Require-NonBlankString $negative.record_key "observations.negative_candidate_ids.record_key"
  if ($id -notmatch "^[0-9]+$" -or $reason -cne "stale_prior_live_state") { Stop-Verify "negative candidate observation is malformed." }
  if ($negativeIds.ContainsKey($id)) { Stop-Verify "negative candidate ID '$id' is repeated." }
  $priorIndex = [Array]::IndexOf([string[]]$priorCandidateIds, $id)
  $expectedRecordKey = if ($priorIndex -ge 0) { "goguk2-print2::$($priorIndex + 1)" } else { "unmapped" }
  if ($recordKey -cne $expectedRecordKey) { Stop-Verify "negative candidate '$id' record mapping differs from origin evidence." }
  $negativeIds[$id] = $reason
  $negativeObservationIds += $id
  Assert-MarkerOnce $evidenceText "NEGATIVE|$recordKey|$id|$reason" "negative evidence"
}
if (-not (Test-ExactIdSet $negativeObservationIds $derivedNegativeIds)) {
  Stop-Verify "negative candidate observations must equal persisted-minus-fresh origin evidence."
}
foreach ($id in $globalGoldIds.Keys) {
  if ($negativeIds.ContainsKey($id)) { Stop-Verify "scoreable gold uses negative or stale candidate ID '$id'." }
}

$inventorySpec = Require-Property $observations "candidate_inventory" "observations"
$inventoryPath = Resolve-ProjectRelativeFile $inventorySpec.path "observations.candidate_inventory.path"
Assert-Sha256 (Get-FileSha256 $inventoryPath) (Require-NonBlankString $inventorySpec.sha256 "observations.candidate_inventory.sha256") "candidate inventory"
$inventoryDocument = Read-JsonDocument $inventoryPath "candidate inventory"
$inventory = @($inventoryDocument | ForEach-Object { $_ })

$observedKeys = @{}
$scoreableByKey = @{}
$scoreableCandidateIds = @()
foreach ($observation in @($observations.scoreable_records)) {
  $recordKey = Require-NonBlankString $observation.record_key "observations.scoreable_records.record_key"
  if ($observedKeys.ContainsKey($recordKey) -or -not $blindByKey.ContainsKey($recordKey)) { Stop-Verify "scoreable observation key '$recordKey' is duplicate or unknown." }
  $observedKeys[$recordKey] = $true
  $candidateId = Require-NonBlankString $observation.candidate_id "scoreable observation candidate_id"
  if ($candidateId -notmatch "^[0-9]+$" -or $negativeIds.ContainsKey($candidateId)) { Stop-Verify "scoreable observation uses invalid, stale, or negative candidate ID '$candidateId'." }
  if (-not $freshOriginSet.ContainsKey($candidateId)) { Stop-Verify "scoreable observation '$recordKey' is absent from the origin fresh-selected set." }
  $sourceOrder = [int]$blindByKey[$recordKey].source_order
  if ($blindByKey[$recordKey].source_key -cne "goguk2-print2" -or $sourceOrder -lt 1 -or $sourceOrder -gt $priorCandidateIds.Count) {
    Stop-Verify "scoreable origin evidence applies only to mapped goguk2-print2 rows."
  }
  $priorIdAtRow = $priorCandidateIds[$sourceOrder - 1]
  if ($candidateId -ceq $priorIdAtRow) {
    if (Test-HasProperty $observation "superseded_prior_candidate_id") { Stop-Verify "scoreable observation '$recordKey' declares an unnecessary superseded prior ID." }
  } elseif ($recordKey -ceq "goguk2-print2::11" -and $candidateId -ceq "1419409" -and $priorIdAtRow -ceq "1419412") {
    $supersededId = Require-NonBlankString (Require-Property $observation "superseded_prior_candidate_id" "scoreable observation '$recordKey'") "scoreable observation superseded prior ID"
    if ($supersededId -cne $priorIdAtRow) { Stop-Verify "scoreable observation '$recordKey' does not name the origin prior ID it superseded." }
  } else {
    Stop-Verify "scoreable observation '$recordKey' does not preserve or explicitly supersede its origin prior-map row."
  }
  if ((Require-NonBlankString $observation.evidence_level "scoreable observation evidence_level") -cne "fresh_selected_exact") {
    Stop-Verify "scoreable observation '$recordKey' lacks fresh_selected_exact evidence."
  }
  Assert-MarkerOnce $evidenceText "SCOREABLE|$recordKey|$candidateId|fresh_selected_exact" "scoreable evidence"
  if ($goldByKey[$recordKey].expected_match_state -eq "unscored_no_offline_gold" -or -not (Test-ExactIdSet @($goldByKey[$recordKey].expected_body_exact_ids) @($candidateId))) {
    Stop-Verify "scoreable observation '$recordKey' does not match gold IDs."
  }

  $sourceFixture = Resolve-ProjectRelativeFile $observation.source_fixture "scoreable observation source_fixture"
  Assert-Sha256 (Get-FileSha256 $sourceFixture) (Require-NonBlankString $observation.source_fixture_sha256 "scoreable observation source_fixture_sha256") "source fixture for $recordKey"
  $expectedPageName = "page-$($blindByKey[$recordKey].pdf_page).png"
  if ((Split-Path -Leaf $sourceFixture) -cne $expectedPageName) { Stop-Verify "source fixture for '$recordKey' does not match blinded pdf_page." }
  Assert-ExactStringArray $observation.source_clues @($blindByKey[$recordKey].korean_clues) "source clues for $recordKey"
  if ((Require-NonBlankString $observation.formula_or_figure_clue "scoreable observation formula_or_figure_clue") -cne $blindByKey[$recordKey].formula_or_figure_clue) {
    Stop-Verify "source formula/figure clue differs for '$recordKey'."
  }

  $matches = @($inventory | Where-Object { [string]$_.id -ceq $candidateId })
  if ($matches.Count -ne 1) { Stop-Verify "candidate inventory must contain exactly one record for '$candidateId'." }
  $metadataText = "$($matches[0].text)`n$($matches[0].type)`n$($matches[0].db)`n$($matches[0].source)"
  $tokens = @($observation.candidate_metadata_tokens)
  if ($tokens.Count -lt 2) { Stop-Verify "scoreable observation '$recordKey' needs at least two candidate metadata tokens." }
  foreach ($token in $tokens) {
    $requiredToken = Require-NonBlankString $token "scoreable observation candidate_metadata_tokens"
    if ($metadataText -notlike "*$requiredToken*") { Stop-Verify "candidate '$candidateId' is missing metadata token '$requiredToken'." }
  }
  $scoreableByKey[$recordKey] = $goldByKey[$recordKey]
  $scoreableCandidateIds += $candidateId
}
if (-not (Test-ExactIdSet $scoreableCandidateIds $freshOriginIds)) {
  Stop-Verify "scoreable candidate IDs must equal the seven-ID origin fresh-selected set."
}

$allowedQuarantineReasons = @("hint_only_prior_candidate_map", "stale_or_contaminated", "no_offline_candidate_body")
foreach ($observation in @($observations.quarantined_records)) {
  $recordKey = Require-NonBlankString $observation.record_key "observations.quarantined_records.record_key"
  if ($observedKeys.ContainsKey($recordKey) -or -not $blindByKey.ContainsKey($recordKey)) { Stop-Verify "quarantine observation key '$recordKey' is duplicate or unknown." }
  $observedKeys[$recordKey] = $true
  $reason = Require-NonBlankString $observation.reason "quarantine observation reason"
  if ($reason -notin $allowedQuarantineReasons) { Stop-Verify "quarantine observation '$recordKey' has unsupported reason '$reason'." }
  if ($goldByKey[$recordKey].expected_match_state -cne "unscored_no_offline_gold" -or @($goldByKey[$recordKey].expected_body_exact_ids).Count -ne 0) {
    Stop-Verify "quarantine observation '$recordKey' is incorrectly scoreable in gold."
  }
  $hintIds = @($observation.candidate_hint_ids)
  foreach ($id in $hintIds) {
    $hintId = Require-NonBlankString $id "quarantine observation candidate_hint_ids"
    if ($hintId -notmatch "^[0-9]+$") { Stop-Verify "quarantine observation '$recordKey' contains a nonnumeric hint ID." }
  }
  if ($blindByKey[$recordKey].source_key -ceq "goguk2-print2") {
    $sourceOrder = [int]$blindByKey[$recordKey].source_order
    if ($sourceOrder -lt 1 -or $sourceOrder -gt $priorCandidateIds.Count) { Stop-Verify "quarantine '$recordKey' falls outside the origin prior candidate map." }
    $priorIdAtRow = $priorCandidateIds[$sourceOrder - 1]
    if ($freshOriginSet.ContainsKey($priorIdAtRow)) { Stop-Verify "quarantine '$recordKey' contains an origin fresh-selected prior ID and must be scoreable." }
    $expectedReason = if ($negativeIds.ContainsKey($priorIdAtRow)) { "stale_or_contaminated" } else { "hint_only_prior_candidate_map" }
    if ($reason -cne $expectedReason -or $hintIds.Count -ne 1 -or [string]$hintIds[0] -cne $priorIdAtRow) {
      Stop-Verify "quarantine '$recordKey' does not match its ordered origin prior-map ID and derived classification."
    }
  } elseif ($blindByKey[$recordKey].source_key -cne "baekyang2-geometry-print1" -or $reason -cne "no_offline_candidate_body") {
    Stop-Verify "quarantine '$recordKey' has no supported origin-evidence classification."
  }
  if ($reason -eq "hint_only_prior_candidate_map") {
    if ($hintIds.Count -ne 1) { Stop-Verify "hint-only quarantine '$recordKey' must contain exactly one hint ID." }
    Assert-MarkerOnce $evidenceText "HINT_ONLY|$recordKey|$($hintIds[0])|prior_candidate_map_only" "hint-only evidence"
  } elseif ($reason -eq "stale_or_contaminated") {
    if ($hintIds.Count -ne 1 -or -not $negativeIds.ContainsKey([string]$hintIds[0])) { Stop-Verify "stale quarantine '$recordKey' must reference one negative ID." }
    Assert-MarkerOnce $evidenceText "NEGATIVE|$recordKey|$($hintIds[0])|stale_prior_live_state" "stale evidence"
  } else {
    if ($hintIds.Count -ne 0) { Stop-Verify "no-offline-gold quarantine '$recordKey' must not contain candidate hints." }
    Assert-MarkerOnce $evidenceText "NO_OFFLINE_GOLD|$recordKey|no_offline_candidate_body" "no-offline evidence"
  }
}
if ($observedKeys.Count -ne $orderedKeys.Count) { Stop-Verify "observations do not partition every corpus record exactly once." }

if ($manifest.schema_version -ne 2 -or $manifest.corpus_id -cne $gold.corpus_id) { Stop-Verify "hash manifest schema or corpus_id differs from the corpus." }
$hashSpecs = @(
  @{ Label = "gold"; Path = $GoldPath; Expected = $manifest.gold_sha256 },
  @{ Label = "blinded"; Path = $BlindedPath; Expected = $manifest.blinded_sha256 },
  @{ Label = "observations"; Path = $ObservationsPath; Expected = $manifest.observations_sha256 },
  @{ Label = "evidence contract"; Path = $EvidenceContractPath; Expected = $manifest.evidence_contract_sha256 }
)
foreach ($hashSpec in $hashSpecs) { Assert-Sha256 (Get-FileSha256 $hashSpec.Path) (Require-NonBlankString $hashSpec.Expected "manifest hash") $hashSpec.Label }
if ([int]$manifest.ordered_record_count -ne $orderedKeys.Count -or [int]$manifest.scoreable_record_count -ne $scoreableByKey.Count -or [int]$manifest.quarantined_record_count -ne ($orderedKeys.Count - $scoreableByKey.Count)) {
  Stop-Verify "manifest record counts differ from verified evidence decisions."
}

$blindedHash = Get-FileSha256 $BlindedPath
if ($SubmissionPath) {
  $submission = Read-JsonDocument $SubmissionPath "benchmark submission"
  Assert-NoScorerFieldsInSubmission $submission "benchmark submission"
  Assert-ExactObjectShape $submission @("corpus_id", "blinded_sha256", "status", "records") "benchmark submission"
  $submissionCorpusId = Require-NonBlankString (Require-Property $submission "corpus_id" "benchmark submission") "benchmark submission.corpus_id"
  if ($submissionCorpusId -cne $gold.corpus_id) { Stop-Verify "benchmark submission corpus_id differs from the corpus." }
  $submissionBlindHash = Require-NonBlankString (Require-Property $submission "blinded_sha256" "benchmark submission") "benchmark submission.blinded_sha256"
  if ($submissionBlindHash.ToUpperInvariant() -cne $blindedHash) { Stop-Verify "benchmark submission uses a stale or wrong blinded_sha256." }
  $status = Require-NonBlankString (Require-Property $submission "status" "benchmark submission") "benchmark submission.status"
  if ($status -notin @("success", "partial", "no_match")) { Stop-Verify "benchmark submission.status must be success, partial, or no_match." }
  [void](Require-Property $submission "records" "benchmark submission")
  $submissionRecords = $submission.PSObject.Properties["records"].Value
  if ($submissionRecords -isnot [System.Array]) { Stop-Verify "benchmark submission.records must be a JSON array." }
  $submittedRecords = @($submissionRecords)
  $seenSubmissionKeys = @{}
  $exactCount = 0
  $submittedScoreable = 0
  $submittedQuarantined = 0
  foreach ($record in $submittedRecords) {
    Assert-ExactObjectShape $record @("record_key", "selected_ids", "body_only_preflight_rationale") "benchmark submission record"
    $recordKey = Require-NonBlankString (Require-Property $record "record_key" "benchmark submission record") "benchmark submission record_key"
    if ($seenSubmissionKeys.ContainsKey($recordKey) -or -not $blindByKey.ContainsKey($recordKey)) { Stop-Verify "benchmark submission repeats or references unknown record_key '$recordKey'." }
    $seenSubmissionKeys[$recordKey] = $true
    [void](Require-Property $record "selected_ids" "benchmark submission record")
    $selectedIdsValue = $record.PSObject.Properties["selected_ids"].Value
    if ($selectedIdsValue -isnot [System.Array]) { Stop-Verify "benchmark submission '$recordKey' selected_ids must be a JSON array." }
    $selectedIds = @($selectedIdsValue)
    if ($selectedIds.Count -eq 0) { Stop-Verify "benchmark submission '$recordKey' selected_ids must not be empty." }
    $normalizedIds = @()
    foreach ($id in $selectedIds) {
      $normalizedId = Require-NonBlankString $id "benchmark submission selected_ids"
      if ($normalizedId -notmatch "^[0-9]+$") { Stop-Verify "benchmark submission contains nonnumeric ID '$normalizedId'." }
      $normalizedIds += $normalizedId
    }
    [void](Require-NonBlankString (Require-Property $record "body_only_preflight_rationale" "benchmark submission record") "benchmark submission body_only_preflight_rationale")
    if ($scoreableByKey.ContainsKey($recordKey)) {
      $submittedScoreable++
      if (Test-ExactIdSet $normalizedIds @($scoreableByKey[$recordKey].expected_body_exact_ids)) { $exactCount++ }
    } else {
      $submittedQuarantined++
    }
  }
  $nonExactCount = $submittedScoreable - $exactCount
  $unsubmittedScoreable = $scoreableByKey.Count - $submittedScoreable
  if ($status -eq "success" -and ($exactCount -ne $scoreableByKey.Count -or $nonExactCount -ne 0)) {
    Stop-Verify "benchmark submission claims success but exactly matched $exactCount of $($scoreableByKey.Count) scoreable records; non_exact=$nonExactCount unsubmitted=$unsubmittedScoreable."
  }
  if ($status -eq "no_match" -and $seenSubmissionKeys.Count -ne 0) { Stop-Verify "benchmark submission claims no_match but includes selected records." }
  $submissionVerdict = if ($status -eq "success") { "CORPUS_MATCH" } else { "CORPUS_NON_MATCH" }
  Write-Output "TASK8_SCORE: verdict=$submissionVerdict status=$status exact=$exactCount/$($scoreableByKey.Count) submitted_scoreable=$submittedScoreable submitted_quarantined=$submittedQuarantined non_exact=$nonExactCount unsubmitted_scoreable=$unsubmittedScoreable quarantined=$($orderedKeys.Count - $scoreableByKey.Count)"
}

$base = "TASK8_VERIFY: PASS corpus_id=$($gold.corpus_id) ordered_records=$($orderedKeys.Count) scoreable=$($scoreableByKey.Count) quarantined=$($orderedKeys.Count - $scoreableByKey.Count) evidence_contract=v2 origin_evidence=direct blinded_sha256=$blindedHash"
if ($SubmissionPath) {
  Write-Output "$base truth_scope=dated-characterization independent_body_oracle=false submission_verdict=$submissionVerdict"
} else {
  Write-Output "$base truth_scope=dated-characterization independent_body_oracle=false"
}
