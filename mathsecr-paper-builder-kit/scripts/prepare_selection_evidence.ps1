[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InputPath,
  [Parameter(Mandatory = $true)][string]$OutPath,
  [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'state_machine.ps1')
. (Join-Path $PSScriptRoot 'read_contract_json.ps1')

# Assembly only: judgments, timestamps, identities and raw observations must
# already exist. The existing contracts remain the sole selection validators.
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { throw 'ProjectRoot must exist.' }
function Resolve-PreparationJsonPath {
  param([string]$Path, [switch]$Output)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path -cne $Path.Trim()) { throw 'A canonical JSON path is required.' }
  $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $ProjectRoot $Path }))
  $prefix = $ProjectRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetExtension($full).ToLowerInvariant() -cne '.json') { throw 'JSON paths must be inside ProjectRoot.' }
  $relative = $full.Substring($prefix.Length)
  if ($relative.Contains(':')) { throw 'Alternate data streams are not supported.' }
  $cursor = $ProjectRoot
  foreach ($segment in $relative.Split([char[]]@('\', '/'))) {
    $cursor = Join-Path $cursor $segment
    if (Test-Path -LiteralPath $cursor) {
      if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Reparse points are not supported.'
      }
    }
  }
  if ($Output) {
    if (Test-Path -LiteralPath $full) { throw 'OutPath already exists; choose a new output path.' }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $full) -PathType Container)) { throw 'OutPath parent must exist.' }
  } elseif (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'Input JSON is missing.' }
  return $full
}
function Get-PreparationHash {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
$inputFull = Resolve-PreparationJsonPath $InputPath
$outputFull = Resolve-PreparationJsonPath $OutPath -Output
$inputHash = Get-PreparationHash $inputFull
$target = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $inputFull -Raw -Encoding UTF8)
if (-not (Test-MathSecrSearchRequiredProperties $target @('number','occurrenceKey','selectedId','searchAttemptReceipt','bodyComparisonReceipt')) -or
    -not (Test-IsCanonicalId $target.number) -or -not (Test-IsCanonicalOccurrenceKey $target.occurrenceKey) -or
    -not (Test-IsCanonicalId $target.selectedId)) { throw 'A canonical target and its actual search/body inputs are required.' }
$body = $target.bodyComparisonReceipt
if (-not (Test-MathSecrSearchRequiredProperties $body @('sourceRenderArtifact','candidateRenderArtifact','searchAttemptId'))) {
  throw 'Actual source/candidate artifact paths and the compared attempt are required.'
}
$identities = @{}
foreach ($side in @('source','candidate')) {
  $relative = $body."${side}RenderArtifact"
  if ($relative -is [string] -and $relative.Contains(':')) { throw 'Alternate data streams are not supported.' }
  $full = Resolve-MathSecrStateArtifactPath $ProjectRoot $relative
  if ($null -eq $full) { throw "Invalid or missing $side render artifact." }
  $hash = Get-PreparationHash $full
  $property = $body.PSObject.Properties["${side}RenderSha256"]
  if ($null -ne $property -and ($property.Value -isnot [string] -or
      -not [string]::Equals($property.Value, $hash, [StringComparison]::OrdinalIgnoreCase))) {
    throw "Supplied $side render hash does not match its bytes."
  }
  $body | Add-Member -NotePropertyName "${side}RenderSha256" -NotePropertyValue $hash -Force
  $identities[$side] = [pscustomobject]@{ path=$full; sha256=$hash }
}
$sourceProperty = $target.PSObject.Properties['sourceBodyArtifact']
if ($null -ne $sourceProperty -and (
    -not (Test-MathSecrSearchRequiredProperties $sourceProperty.Value @('path','sha256')) -or
    $sourceProperty.Value.path -isnot [string] -or $sourceProperty.Value.path -cne $body.sourceRenderArtifact -or
    $sourceProperty.Value.sha256 -isnot [string] -or
    -not [string]::Equals($sourceProperty.Value.sha256, $identities.source.sha256, [StringComparison]::OrdinalIgnoreCase))) {
  throw 'Existing source artifact binding conflicts with the input render.'
}
$target | Add-Member -NotePropertyName sourceBodyArtifact -NotePropertyValue ([pscustomobject]@{
  path=$body.sourceRenderArtifact; sha256=$identities.source.sha256
}) -Force

$packet = $target.searchAttemptReceipt
if (-not (Test-MathSecrSearchRequiredProperties $packet @('attempts')) -or $packet.attempts -isnot [array]) {
  throw 'The existing search-attempt packet is required.'
}
foreach ($attempt in $packet.attempts) {
  if (-not (Test-MathSecrSearchRequiredProperties $attempt @('attemptId','chips','resultCount','freshResultVerified','observationReceipt')) -or
      $attempt.freshResultVerified -isnot [bool] -or $attempt.chips -isnot [array] -or
      @($attempt.chips | Where-Object { -not (Test-MathSecrSearchRequiredProperties $_ @('value')) }).Count -gt 0) {
    throw 'Each attempt must supply typed capture inputs and a Boolean freshness cache.'
  }
  $observed = Test-MathSecrSearchObservation -Packet $attempt.observationReceipt -AttemptId $attempt.attemptId `
    -Chips @($attempt.chips | ForEach-Object { $_.value }) -ResultCount $attempt.resultCount
  if (-not $observed.FreshResultVerified) { throw "Search observation rejected: $($attempt.attemptId)." }
  # Recompute only this cache, never the raw captures or exact/inspection claims.
  $attempt.freshResultVerified = $observed.FreshResultVerified
}
$derived = Test-MathSecrSearchAttemptContract $packet
if (-not $derived.SchemaValid) { throw "Search schema rejected: $($derived.Errors -join '; ')." }
foreach ($pair in @(@('commonChips','CommonChips'),@('exactMatchIds','ExactMatchIds'),
    @('literalOnlyLadderCompleted','LiteralOnlyLadderCompleted'),@('resetBackoffPerformed','ResetBackoffPerformed'),
    @('candidateRecoveryCompleted','CandidateRecoveryCompleted'),@('completeCoverageVerified','CompleteCoverageVerified'))) {
  $packet.($pair[0]) = $derived.($pair[1])
}
$search = Test-MathSecrSearchAttemptContract $packet
if ($search.Status -cne 'exact-found' -or @($search.Errors).Count -ne 0) { throw "Search contract rejected: $($search.Errors -join '; ')." }
$winning = @($packet.attempts | Where-Object { $_.attemptId -ceq $body.searchAttemptId })
if ($winning.Count -ne 1) { throw 'The comparison must identify exactly one existing attempt.' }
$resolution = switch ($winning[0].scope) {
  'initial-scope' { 'initial_selected' }; 'candidate-recovery' { 'candidate_selected' }; 'whole-db' { 'whole_selected' }
  default { throw 'Only ordinary text-search selection packets are supported.' }
}
$resolutionProperty = $target.PSObject.Properties['resolution']
if ($null -ne $resolutionProperty -and ($resolutionProperty.Value -isnot [string] -or $resolutionProperty.Value -cne $resolution)) {
  throw 'Existing target resolution conflicts with the winning attempt.'
}
$target | Add-Member -NotePropertyName resolution -NotePropertyValue $resolution -Force
# Validate the serialized wire representation before any output file is created.
$json = ConvertTo-Json -InputObject $target -Depth 80
$target = ConvertFrom-MathSecrContractJson $json
$selected = Test-MathSecrSelectedSearchReceipt -Target $target -Resolution $resolution
if (-not $selected.Valid) { throw 'Selected search target/candidate/attempt binding rejected.' }
$bodyCheck = Test-MathSecrBodyComparisonReceipt -Receipt $target.bodyComparisonReceipt -Target $target `
  -ProjectRoot $ProjectRoot -InspectedIds $selected.InspectedIds -AttemptId $selected.AttemptId
if (-not $bodyCheck.Valid) { throw "Body comparison rejected: $($bodyCheck.Errors -join '; ')." }
$target | Add-Member -NotePropertyName preparation -NotePropertyValue ([pscustomobject]@{
  helperVersion='selection-evidence-preparation-v1'; inputSha256=$inputHash
  truthScope='receipt-structure-and-artifact-identity-only'; searchObservation=$selected.Projection
}) -Force
$json = ConvertTo-Json -InputObject $target -Depth 80
foreach ($side in @('source','candidate')) {
  if ((Get-PreparationHash $identities[$side].path) -cne $identities[$side].sha256) { throw 'Render bytes changed during preparation.' }
}
if ((Get-PreparationHash $inputFull) -cne $inputHash) { throw 'Input JSON changed during preparation.' }
$outputFull = Resolve-PreparationJsonPath $OutPath -Output
$stream = [IO.File]::Open($outputFull, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + [Environment]::NewLine)
  $stream.Write($bytes, 0, $bytes.Length)
} finally { $stream.Dispose() }
[pscustomobject]@{ path=$outputFull; sourceProblemNumber=$target.number; candidateId=$target.selectedId; resolution=$resolution; validation='passed' }
