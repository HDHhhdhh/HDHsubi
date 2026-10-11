. (Join-Path $PSScriptRoot "search_attempt_contract.ps1")
. (Join-Path $PSScriptRoot "body_comparison_contract.ps1")
. (Join-Path $PSScriptRoot 'read_contract_json.ps1')

# Bump this when validation semantics change; the context itself stays call-local.
$CONTRACT_VERSION = '2026-10-11.2'

function Get-MathSecrStateCacheKey {
  param([string]$ArtifactSha256, [string]$Phase)
  return $ArtifactSha256.ToUpperInvariant() + '|' + $Phase + '|' + $CONTRACT_VERSION
}

function Set-MathSecrCachedStateResult {
  param($Context, [string]$ArtifactSha256, $Snapshot, [string]$Phase, $StateResult)
  if ($null -eq $Context -or $ArtifactSha256 -notmatch '^[a-fA-F0-9]{64}$') { return }
  # Only completed validations are reusable at another recursion depth.
  if ($StateResult.State -cne 'REPORT' -or $StateResult.Status -cnotin @('완료', '부분 완료')) { return }
  $height = 0
  $appendProperty = $Snapshot.PSObject.Properties['editAppendReceipt']
  if ($null -ne $appendProperty) {
    $priorReceipt = Get-MathSecrStatePropertyValue $appendProperty.Value 'priorSessionArtifact'
    $priorHash = Get-MathSecrStatePropertyValue $priorReceipt 'sha256'
    if ($priorHash -isnot [string] -or $priorHash -notmatch '^[a-fA-F0-9]{64}$') { return }
    $priorKey = Get-MathSecrStateCacheKey -ArtifactSha256 $priorHash -Phase AfterReload
    if (-not $Context.StateCache.ContainsKey($priorKey)) { return }
    $height = $Context.StateCache[$priorKey].AppendHeight + 1
  }
  $key = Get-MathSecrStateCacheKey -ArtifactSha256 $ArtifactSha256 -Phase $Phase
  $Context.StateCache[$key] = [pscustomobject]@{ StateResult = $StateResult; AppendHeight = $height }
}

function Get-MathSecrCachedStateResult {
  param($Context, [string]$ArtifactSha256, [string]$Phase, [int]$AppendDepth)
  if ($null -eq $Context -or $ArtifactSha256 -notmatch '^[a-fA-F0-9]{64}$') { return $null }
  $key = Get-MathSecrStateCacheKey -ArtifactSha256 $ArtifactSha256 -Phase $Phase
  if (-not $Context.StateCache.ContainsKey($key)) { return $null }
  $entry = $Context.StateCache[$key]
  # A cached successful short chain must not bypass the original 64-append limit.
  # A miss deliberately runs the original validator so its error propagation stays intact.
  if ($entry.AppendHeight -gt 0 -and ($AppendDepth -lt 0 -or $AppendDepth + $entry.AppendHeight -gt 64)) { return $null }
  return $entry.StateResult
}

function Test-MathSecrObjectEquals {
  param($Left, $Right)
  if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
  if ($Left -is [string] -or $Right -is [string]) {
    return $Left -is [string] -and $Right -is [string] -and [string]::Equals($Left, $Right, [StringComparison]::Ordinal)
  }
  if ($Left -is [bool] -or $Right -is [bool]) {
    return $Left -is [bool] -and $Right -is [bool] -and $Left -eq $Right
  }
  if ((Test-IsStrictInteger $Left) -and (Test-IsStrictInteger $Right)) {
    # JSON serializes integer widths identically. Contract parsing can produce Int64.
    return [decimal]$Left -eq [decimal]$Right
  }
  $leftArray = $Left -is [array] -or $Left -is [Collections.IList]
  $rightArray = $Right -is [array] -or $Right -is [Collections.IList]
  if ($leftArray -or $rightArray) {
    if (-not $leftArray -or -not $rightArray -or $Left.Count -ne $Right.Count) { return $false }
    for ($i = 0; $i -lt $Left.Count; $i++) {
      if (-not (Test-MathSecrObjectEquals $Left[$i] $Right[$i])) { return $false }
    }
    return $true
  }
  $leftObject = $Left -is [pscustomobject] -or $Left -is [Collections.IDictionary]
  $rightObject = $Right -is [pscustomobject] -or $Right -is [Collections.IDictionary]
  if ($leftObject -or $rightObject) {
    if (-not $leftObject -or -not $rightObject) { return $false }
    $leftNames = @(if ($Left -is [Collections.IDictionary]) { foreach ($key in $Left.Keys) { $key } } else { foreach ($property in $Left.PSObject.Properties) { $property.Name } })
    $rightNames = @(if ($Right -is [Collections.IDictionary]) { foreach ($key in $Right.Keys) { $key } } else { foreach ($property in $Right.PSObject.Properties) { $property.Name } })
    if ($leftNames.Count -ne $rightNames.Count) { return $false }
    for ($i = 0; $i -lt $leftNames.Count; $i++) {
      if (-not [string]::Equals([string]$leftNames[$i], [string]$rightNames[$i], [StringComparison]::Ordinal)) { return $false }
      if ($Left -is [Collections.IDictionary]) { $leftValue = $Left[$leftNames[$i]] } else { $leftValue = $Left.PSObject.Properties[$leftNames[$i]].Value }
      if ($Right -is [Collections.IDictionary]) { $rightValue = $Right[$rightNames[$i]] } else { $rightValue = $Right.PSObject.Properties[$rightNames[$i]].Value }
      if (-not (Test-MathSecrObjectEquals $leftValue $rightValue)) { return $false }
    }
    return $true
  }
  # Uncommon scalar forms (floating point, decimal, DateTime) retain the exact
  # old JSON representation, including 1 versus 1.0, without serializing objects.
  return (ConvertTo-Json -InputObject $Left -Depth 100 -Compress) -ceq (ConvertTo-Json -InputObject $Right -Depth 100 -Compress)
}

function ConvertTo-StringArray {
  param($Value)

  if ($null -eq $Value) {
    return @()
  }
  return @($Value | ForEach-Object { [string]$_ })
}

function Test-OrderedIdsEqual {
  param($Expected, $Actual)

  $expectedIds = @(ConvertTo-StringArray $Expected)
  $actualIds = @(ConvertTo-StringArray $Actual)
  if ($expectedIds.Count -ne $actualIds.Count) {
    return $false
  }
  for ($index = 0; $index -lt $expectedIds.Count; $index++) {
    if ($expectedIds[$index] -cne $actualIds[$index]) {
      return $false
    }
  }
  return $true
}

function Test-HasDuplicateIds {
  param($Value)

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($id in @(ConvertTo-StringArray $Value)) {
    if (-not $seen.Add($id)) {
      return $true
    }
  }
  return $false
}

function Test-IsCanonicalReportToken {
  param($Value)

  # IDs and occurrence keys are opaque report tokens. They must be nonblank
  # strings with canonical edge whitespace; the exact report sentinel `없음`,
  # commas, and CR/LF are reserved so comma-delimited report text remains
  # lossless. Other internal whitespace (including TAB/NBSP) and case are
  # preserved verbatim and compared ordinally.
  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  if ($Value -ceq "없음" -or $Value -cne $Value.Trim() -or $Value -match '^[ \t\u00A0]|[ \t\u00A0]$') {
    return $false
  }
  return -not [regex]::IsMatch($Value, '[,\r\n]')
}

function Test-IsCanonicalOccurrenceKey {
  param($Value)

  return Test-IsCanonicalReportToken $Value
}

function Test-IsCanonicalId {
  param($Value)

  return Test-IsCanonicalReportToken $Value
}

function Test-IsStrictUniqueOccurrenceKeyArray {
  param(
    $Value,
    [int]$MinimumCount = 0
  )

  if ($Value -isnot [System.Array] -or @($Value).Count -lt $MinimumCount) {
    return $false
  }

  # Occurrence keys are opaque source-position identities. Preserve case and
  # internal whitespace semantics rather than applying the chip/scope
  # normalizers; edge whitespace is noncanonical and therefore rejected.
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($key in $Value) {
    if (-not (Test-IsCanonicalOccurrenceKey $key) -or -not $seen.Add($key)) {
      return $false
    }
  }
  return $true
}

function Test-MathSecrStateOptionalOccurrenceKeyArray {
  param(
    $Object,
    [string]$PropertyName
  )

  if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
    return $false
  }
  $property = $Object.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    return $true
  }
  return Test-IsStrictUniqueOccurrenceKeyArray $property.Value
}

function Get-MathSecrStateOptionalStringArray {
  param(
    $Object,
    [string]$PropertyName
  )

  if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
    return $null
  }
  $property = $Object.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    return $null
  }
  # Do not coerce occurrence keys: the strict validator must reject numeric
  # or scalar snapshots instead of silently turning them into strings.
  return $property.Value
}

function Test-MathSecrStateOccurrenceBundleAbsentOrEmpty {
  param(
    $Object,
    [string]$PropertyName
  )

  $value = Get-MathSecrStateOptionalStringArray $Object $PropertyName
  return $null -eq $value -or ($value -is [System.Array] -and @($value).Count -eq 0)
}

function Test-MathSecrStateOccurrenceBundleMatches {
  param(
    $Object,
    [string]$PropertyName,
    $ExpectedOccurrenceKeys
  )

  $value = Get-MathSecrStateOptionalStringArray $Object $PropertyName
  return ((Test-IsStrictUniqueOccurrenceKeyArray $value) -and
    (Test-OrderedIdsEqual $ExpectedOccurrenceKeys $value))
}

function Test-MathSecrStateDuplicateOccurrenceProof {
  param(
    $Snapshot,
    $ExpectedOccurrenceKeys,
    [string]$Phase = "AfterReload",
    $SelectedOccurrenceKeys
  )

  $proofProperty = $Snapshot.PSObject.Properties['occurrenceProof']
  if ($null -eq $proofProperty -or -not (Test-HasRequiredProperties $proofProperty.Value @(
    "DuplicateAddControlVerified", "DuplicateAddControlKind", "DuplicateAddControlReceipt", "OrderedBundleVerified"
  ))) {
    return $false
  }

  $proof = $proofProperty.Value
  if (
    -not (Test-IsStrictBoolean $proof.DuplicateAddControlVerified) -or
    -not $proof.DuplicateAddControlVerified -or
    $proof.DuplicateAddControlKind -isnot [string] -or
    $proof.DuplicateAddControlKind -cne "duplicate/add" -or
    -not (Test-IsNonblankString $proof.DuplicateAddControlReceipt) -or
    -not (Test-IsStrictBoolean $proof.OrderedBundleVerified) -or
    -not $proof.OrderedBundleVerified
  ) {
    return $false
  }

  $selectedOccurrenceKeys = if ($PSBoundParameters.ContainsKey('SelectedOccurrenceKeys')) { $SelectedOccurrenceKeys } else { Get-MathSecrStateOptionalStringArray $Snapshot "selectionBeforeNextOccurrenceKeys" }
  if ($Phase -ceq "AfterReload") {
    $draftOccurrenceKeys = Get-MathSecrStateOptionalStringArray (Get-MathSecrStatePropertyValue $Snapshot 'edit') "draftOccurrenceKeys"
    $persistedOccurrenceKeys = Get-MathSecrStateOptionalStringArray (Get-MathSecrStatePropertyValue $Snapshot 'persistence') "occurrenceKeys"
    $bundles = @($selectedOccurrenceKeys, $draftOccurrenceKeys, $persistedOccurrenceKeys)
  } else {
    # Preserve the selected bundle as one array rather than unrolling it.
    $bundles = ,$selectedOccurrenceKeys
  }
  foreach ($actualOccurrenceKeys in $bundles) {
    if (
      -not (Test-IsStrictUniqueOccurrenceKeyArray $actualOccurrenceKeys) -or
      -not (Test-OrderedIdsEqual $ExpectedOccurrenceKeys $actualOccurrenceKeys)
    ) {
      return $false
    }
  }
  return $true
}

function Test-IsStrictBoolean {
  param($Value)

  return $Value -is [bool]
}

function Test-IsStrictIdArray {
  param($Value)

  if ($Value -isnot [System.Array]) {
    return $false
  }
  foreach ($id in $Value) {
    if (-not (Test-IsCanonicalId $id)) {
      return $false
    }
  }
  return $true
}

function ConvertTo-MathSecrStateNormalizedScope {
  param([string]$Value)

  $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
  $normalized = [regex]::Replace($normalized, '\s+', ' ')
  $normalized = [regex]::Replace($normalized, '\s*>\s*', '>')
  return $normalized.ToLowerInvariant()
}

function ConvertTo-MathSecrStateNormalizedChip {
  param([string]$Value)

  $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
  $normalized = [regex]::Replace($normalized, '\s+', ' ')
  return $normalized.ToLowerInvariant()
}

function Test-IsStrictUniqueNonblankStringArray {
  param(
    $Value,
    [int]$MinimumCount = 0
  )

  if ($Value -isnot [System.Array] -or @($Value).Count -lt $MinimumCount) {
    return $false
  }

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($item in $Value) {
    if ($item -isnot [string]) {
      return $false
    }
    $normalizedItem = ConvertTo-MathSecrStateNormalizedChip $item
    if ([string]::IsNullOrWhiteSpace($normalizedItem) -or -not $seen.Add($normalizedItem)) {
      return $false
    }
  }
  return $true
}

function Test-IsNonblankString {
  param($Value)

  return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-IsStrictInteger {
  param($Value)

  # JSON numbers are materialized as Int64 by ConvertFrom-Json.  Keep the
  # contract integer-only while accepting the other integral CLR types a
  # caller can provide directly; bool, floating point, decimal, and strings
  # are deliberately rejected.
  if ($null -eq $Value -or $Value -is [bool]) {
    return $false
  }
  return $Value -is [sbyte] -or
    $Value -is [byte] -or
    $Value -is [int16] -or
    $Value -is [uint16] -or
    $Value -is [int32] -or
    $Value -is [uint32] -or
    $Value -is [int64] -or
    $Value -is [uint64]
}

function Resolve-MathSecrStateArtifactPath {
  param(
    [string]$ProjectRoot,
    $RelativePath
  )

  if ($RelativePath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$RelativePath)) {
    return $null
  }
  $normalized = ([string]$RelativePath).Replace('/', '\')
  if (
    $normalized -cne $normalized.Trim() -or
    [System.IO.Path]::IsPathRooted($normalized) -or
    $normalized -match '^[A-Za-z]:'
  ) {
    return $null
  }
  $segments = @($normalized -split '\\+' | Where-Object { $_ -ne '' })
  if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0) {
    return $null
  }

  try {
    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootFull $normalized))
  } catch {
    return $null
  }
  if (-not $fullPath.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }
  $currentPath = $rootFull
  foreach ($segment in $segments) {
    $currentPath = [System.IO.Path]::Combine($currentPath, [string]$segment)
    if (Test-Path -LiteralPath $currentPath) {
      $item = Get-Item -LiteralPath $currentPath -Force
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $null
      }
    }
  }
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    return $null
  }
  if (@('.png', '.jpg', '.jpeg', '.webp') -cnotcontains [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()) {
    return $null
  }
  return $fullPath
}

function Test-MathSecrSourceAnomalyReceipt {
  param(
    $Receipt,
    $Target,
    [string]$ProjectRoot,
    [System.Collections.Generic.HashSet[string]]$InspectedIds,
    $Context = $null
  )

  if ($null -eq $Receipt -or $Receipt -isnot [pscustomobject]) {
    return $false
  }

  $requiredProperties = @(
    "truthScope",
    "sourceProblemNumber",
    "occurrenceKey",
    "candidateId",
    "sourceRenderArtifact",
    "sourceRenderSha256",
    "candidateRenderArtifact",
    "candidateRenderSha256",
    "sourceRenderScale",
    "candidateRenderScale",
    "conflictClass",
    "comparisonState",
    "metadataOverrideUsed"
  )
  if (@($Receipt.PSObject.Properties).Count -ne $requiredProperties.Count) {
    return $false
  }
  foreach ($propertyName in $requiredProperties) {
    if ($null -eq $Receipt.PSObject.Properties[$propertyName]) {
      return $false
    }
  }

  $sourceHash = $Receipt.sourceRenderSha256
  $candidateHash = $Receipt.candidateRenderSha256
  $targetNumberProperty = $Target.PSObject.Properties['number']
  $targetOccurrenceProperty = $Target.PSObject.Properties['occurrenceKey']
  if ($null -eq $targetNumberProperty) {
    return $false
  }
  $targetNumber = [string]$targetNumberProperty.Value
  $targetOccurrence = if ($null -ne $targetOccurrenceProperty) {
    $targetOccurrenceProperty.Value
  } else {
    $targetNumber
  }
  $sourceArtifact = Resolve-MathSecrStateArtifactPath $ProjectRoot $Receipt.sourceRenderArtifact
  $candidateArtifact = Resolve-MathSecrStateArtifactPath $ProjectRoot $Receipt.candidateRenderArtifact
  $allowedConflictClasses = @(
    "glyph-ambiguity",
    "operator-ambiguity",
    "source-transcription-conflict"
  )
  if (
    $Receipt.truthScope -isnot [string] -or
    $Receipt.truthScope -cne "offline-contract" -or
    $Receipt.sourceProblemNumber -isnot [string] -or
    $Receipt.sourceProblemNumber -cne $targetNumber -or
    -not (Test-IsCanonicalOccurrenceKey $Receipt.occurrenceKey) -or
    $Receipt.occurrenceKey -cne $targetOccurrence -or
    -not (Test-IsCanonicalId $Receipt.candidateId) -or
    $null -eq $InspectedIds -or
    -not $InspectedIds.Contains([string]$Receipt.candidateId) -or
    $null -eq $sourceArtifact -or
    $null -eq $candidateArtifact -or
    [string]::Equals($sourceArtifact, $candidateArtifact, [System.StringComparison]::OrdinalIgnoreCase) -or
    $sourceHash -isnot [string] -or
    $sourceHash -cnotmatch '\A[0-9A-Fa-f]{64}\z' -or
    $candidateHash -isnot [string] -or
    $candidateHash -cnotmatch '\A[0-9A-Fa-f]{64}\z' -or
    [string]::Equals($sourceHash, $candidateHash, [System.StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-IsStrictInteger $Receipt.sourceRenderScale) -or
    [int64]$Receipt.sourceRenderScale -lt 2 -or
    -not (Test-IsStrictInteger $Receipt.candidateRenderScale) -or
    [int64]$Receipt.candidateRenderScale -lt 2 -or
    $Receipt.conflictClass -isnot [string] -or
    $allowedConflictClasses -cnotcontains $Receipt.conflictClass -or
    $Receipt.comparisonState -isnot [string] -or
    $Receipt.comparisonState -cne "unresolved" -or
    -not (Test-IsStrictBoolean $Receipt.metadataOverrideUsed) -or
    $Receipt.metadataOverrideUsed
  ) {
    return $false
  }

  $Context = Enter-MathSecrValidationContext -Context $Context -ProjectRoot $ProjectRoot
  try {
  try {
    $actualSourceHash = (Get-MathSecrValidationArtifact -Path $sourceArtifact -ExpectedSha256 $sourceHash -Context $Context).Sha256.ToUpperInvariant()
    $actualCandidateHash = (Get-MathSecrValidationArtifact -Path $candidateArtifact -ExpectedSha256 $candidateHash -Context $Context).Sha256.ToUpperInvariant()
  } catch {
    return $false
  }
  if (
    $sourceHash.ToUpperInvariant() -cne $actualSourceHash -or
    $candidateHash.ToUpperInvariant() -cne $actualCandidateHash
  ) {
    return $false
  }

  # This validates a raw, recomputable observation shape only. It never proves
  # exactness, mismatch, live product behavior, or external ground truth.
  return $true
  } finally { Exit-MathSecrValidationContext -Context $Context }
}

function Get-MathSecrMetadataProperty {
  param(
    $Object,
    [string]$PropertyName
  )

  if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
    return [pscustomobject]@{ Present = $false; Value = $null }
  }
  $property = $Object.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    return [pscustomobject]@{ Present = $false; Value = $null }
  }
  return [pscustomobject]@{ Present = $true; Value = $property.Value }
}

function Get-MathSecrMetadataYearRange {
  param($Bucket)

  if ($null -eq $Bucket -or $Bucket -isnot [pscustomobject]) {
    return $null
  }
  $start = Get-MathSecrMetadataProperty $Bucket "yearStart"
  $end = Get-MathSecrMetadataProperty $Bucket "yearEnd"
  if ($start.Present -and $end.Present) {
    if (-not (Test-IsStrictInteger $start.Value) -or -not (Test-IsStrictInteger $end.Value)) {
      return $null
    }
    return [pscustomobject]@{ Start = [int64]$start.Value; End = [int64]$end.Value }
  }

  # A single-year bucket is represented compactly by `year`; accepting it
  # keeps the receipt readable while retaining the same closed interval
  # semantics.  A bucket cannot mix a compact year with a partial range.
  $year = Get-MathSecrMetadataProperty $Bucket "year"
  if ($year.Present -and -not $start.Present -and -not $end.Present -and (Test-IsStrictInteger $year.Value)) {
    return [pscustomobject]@{ Start = [int64]$year.Value; End = [int64]$year.Value }
  }
  return $null
}

function Test-MathSecrMetadataRescueReceipt {
  param(
    $Target,
    [bool]$RequireCompleteCoverage,
    [string]$ProjectRoot,
    $Context = $null
  )

  $receiptProperty = $Target.PSObject.Properties['metadataRescue']
  if ($null -eq $receiptProperty -or $receiptProperty.Value -isnot [pscustomobject]) {
    return [pscustomobject]@{ Present = $false; Valid = $false }
  }
  $receipt = $receiptProperty.Value

  # The printed metadata is the source of truth for this rescue search.  Do
  # not normalize it: a mismatched source/subject must be visible as a bad
  # receipt rather than silently becoming a different search.
  foreach ($propertyName in @("sourceFamily", "subject", "yearStart", "yearEnd", "status", "textChips", "formulaChips", "buckets")) {
    if ($null -eq $receipt.PSObject.Properties[$propertyName]) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
  }

  $printedSourceProperty = Get-MathSecrMetadataProperty $Target "printedSourceFamily"
  $printedSubjectProperty = Get-MathSecrMetadataProperty $Target "printedSubject"
  $printedYearProperty = Get-MathSecrMetadataProperty $Target "printedYear"
  if (-not $printedSourceProperty.Present -or -not $printedSubjectProperty.Present -or -not $printedYearProperty.Present) {
    return [pscustomobject]@{ Present = $true; Valid = $false }
  }
  $sourceFamily = [string]$printedSourceProperty.Value
  $subject = [string]$printedSubjectProperty.Value
  $printedYear = $printedYearProperty.Value
  if (
    -not (Test-IsNonblankString $printedSourceProperty.Value) -or
    -not (Test-IsNonblankString $printedSubjectProperty.Value) -or
    -not (Test-IsStrictInteger $printedYear) -or
    $receipt.sourceFamily -cne $sourceFamily -or
    $receipt.subject -cne $subject -or
    -not (Test-IsStrictInteger $receipt.yearStart) -or
    -not (Test-IsStrictInteger $receipt.yearEnd) -or
    [int64]$receipt.yearStart -ne ([int64]$printedYear - 1) -or
    [int64]$receipt.yearEnd -ne ([int64]$printedYear + 1)
  ) {
    return [pscustomobject]@{ Present = $true; Valid = $false }
  }

  # Optional month/grade refinement is safe only when it is derived from the
  # target's printed metadata.  An arbitrary partition can hide the target and
  # must never count as exhaustive miss evidence.
  $printedMonthProperty = Get-MathSecrMetadataProperty $Target "printedMonth"
  $printedGradeProperty = Get-MathSecrMetadataProperty $Target "printedGrade"
  $expectedPartitionParts = [System.Collections.Generic.List[string]]::new()
  if ($printedMonthProperty.Present) {
    if (-not (Test-IsNonblankString $printedMonthProperty.Value)) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
    $expectedPartitionParts.Add("month=$([string]$printedMonthProperty.Value)")
  }
  if ($printedGradeProperty.Present) {
    if (-not (Test-IsNonblankString $printedGradeProperty.Value)) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
    $expectedPartitionParts.Add("grade=$([string]$printedGradeProperty.Value)")
  }
  $expectedPartitionKey = if ($expectedPartitionParts.Count -gt 0) { $expectedPartitionParts -join ";" } else { $null }

  if (
    $receipt.status -isnot [string] -or
    $receipt.status -cnotin @( "exact", "missed", "source_anomaly" ) -or
    -not (Test-IsStrictUniqueNonblankStringArray $receipt.textChips 1) -or
    @($receipt.textChips).Count -ne 1 -or
    $receipt.formulaChips -isnot [System.Array] -or
    @($receipt.formulaChips).Count -ne 0 -or
    $receipt.buckets -isnot [System.Array] -or
    @($receipt.buckets).Count -eq 0
  ) {
    return [pscustomobject]@{ Present = $true; Valid = $false }
  }

  $sourceAnomalyReceiptProperty = $receipt.PSObject.Properties['sourceAnomalyReceipt']
  if ($receipt.status -cne "source_anomaly" -and $null -ne $sourceAnomalyReceiptProperty) {
    return [pscustomobject]@{ Present = $true; Valid = $false }
  }

  $windowStart = [int64]$printedYear - 1
  $windowEnd = [int64]$printedYear + 1
  $bucketRanges = [System.Collections.Generic.List[object]]::new()
  $bucketRangePartitions = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.HashSet[string]]]::new([System.StringComparer]::Ordinal)
  $allInspectedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($bucket in @($receipt.buckets)) {
    if ($bucket -isnot [pscustomobject]) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
    $requiredBucketProperties = [System.Collections.Generic.List[string]]::new()
    foreach ($propertyName in @("submitted", "freshResultVerified", "resultCount", "inspectedIds")) {
      $requiredBucketProperties.Add($propertyName)
    }
    if ($RequireCompleteCoverage) {
      foreach ($propertyName in @("endOfResultsVerified", "stableNoGrowthReads", "endReadSnapshots")) {
        $requiredBucketProperties.Add($propertyName)
      }
    }
    foreach ($propertyName in $requiredBucketProperties) {
      if ($null -eq $bucket.PSObject.Properties[$propertyName]) {
        return [pscustomobject]@{ Present = $true; Valid = $false }
      }
    }
    if (
      -not (Test-IsStrictBoolean $bucket.submitted) -or
      -not $bucket.submitted -or
      -not (Test-IsStrictBoolean $bucket.freshResultVerified) -or
      -not $bucket.freshResultVerified -or
      -not (Test-IsStrictInteger $bucket.resultCount) -or
      [int64]$bucket.resultCount -lt 0 -or
      [int64]$bucket.resultCount -gt 100 -or
      -not (Test-IsStrictIdArray $bucket.inspectedIds)
    ) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }

    $inspectedIds = @($bucket.inspectedIds | ForEach-Object { [string]$_ })
    $uniqueInspectedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($inspectedId in $inspectedIds) {
      if (-not $uniqueInspectedIds.Add($inspectedId)) {
        return [pscustomobject]@{ Present = $true; Valid = $false }
      }
      [void]$allInspectedIds.Add($inspectedId)
    }
    if ($uniqueInspectedIds.Count -gt [int64]$bucket.resultCount) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }

    if ($RequireCompleteCoverage) {
      if (
        -not (Test-IsStrictBoolean $bucket.endOfResultsVerified) -or
        -not (Test-IsStrictInteger $bucket.stableNoGrowthReads) -or
        $bucket.endReadSnapshots -isnot [System.Array] -or
        @($bucket.endReadSnapshots).Count -lt 3
      ) {
        return [pscustomobject]@{ Present = $true; Valid = $false }
      }

      $endReadSnapshots = @($bucket.endReadSnapshots)
      foreach ($endReadSnapshot in $endReadSnapshots) {
        if (
          $endReadSnapshot -isnot [System.Array] -or
          -not (Test-IsStrictIdArray $endReadSnapshot) -or
          (Test-HasDuplicateIds $endReadSnapshot) -or
          @($endReadSnapshot).Count -gt [int64]$bucket.resultCount
        ) {
          return [pscustomobject]@{ Present = $true; Valid = $false }
        }
      }

      $finalEndSnapshot = @($endReadSnapshots[-1])
      $stableNoGrowthReads = 0
      for ($snapshotIndex = $endReadSnapshots.Count - 1; $snapshotIndex -gt 0; $snapshotIndex--) {
        if (-not (Test-OrderedIdsEqual $endReadSnapshots[$snapshotIndex - 1] $endReadSnapshots[$snapshotIndex])) {
          break
        }
        $stableNoGrowthReads++
      }
      $computedEndOfResults =
        $uniqueInspectedIds.Count -eq [int64]$bucket.resultCount -and
        (Test-OrderedIdsEqual $inspectedIds $finalEndSnapshot) -and
        $stableNoGrowthReads -ge 2
      if (
        [int64]$bucket.stableNoGrowthReads -ne $stableNoGrowthReads -or
        $bucket.endOfResultsVerified -ne $computedEndOfResults -or
        -not $computedEndOfResults
      ) {
        return [pscustomobject]@{ Present = $true; Valid = $false }
      }
    }

    $range = Get-MathSecrMetadataYearRange $bucket
    if ($null -eq $range -or $range.Start -gt $range.End -or $range.Start -lt $windowStart -or $range.End -gt $windowEnd) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
    $rangeKey = "{0}:{1}" -f $range.Start, $range.End
    $partitionProperty = $bucket.PSObject.Properties['partitionKey']
    $partitionKey = if ($null -eq $partitionProperty) { "<unpartitioned>" } else { [string]$partitionProperty.Value }
    if (
      ($null -ne $partitionProperty -and (
        -not (Test-IsNonblankString $partitionProperty.Value) -or
        $partitionKey -ceq "<unpartitioned>" -or
        $null -eq $expectedPartitionKey -or
        $partitionKey -cne $expectedPartitionKey
      ))
    ) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
    if (-not $bucketRangePartitions.ContainsKey($rangeKey)) {
      $bucketRangePartitions[$rangeKey] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    }
    if (-not $bucketRangePartitions[$rangeKey].Add($partitionKey)) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
    $bucketRanges.Add($range)
  }

  foreach ($rangePartitions in $bucketRangePartitions.Values) {
    if ($rangePartitions.Count -gt 1 -and $rangePartitions.Contains("<unpartitioned>")) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
  }

  if ($receipt.status -ceq "source_anomaly") {
    if (
      $null -eq $sourceAnomalyReceiptProperty -or
      -not (Test-MathSecrSourceAnomalyReceipt $sourceAnomalyReceiptProperty.Value $Target $ProjectRoot $allInspectedIds -Context $Context)
    ) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
  }

  if ($receipt.status -ceq "exact") {
    $selectedIdProperty = $Target.PSObject.Properties['selectedId']
    if ($null -eq $selectedIdProperty -or -not (Test-IsCanonicalId $selectedIdProperty.Value)) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
    $selectedId = [string]$selectedIdProperty.Value
    $selectedInspected = $false
    foreach ($bucket in @($receipt.buckets)) {
      foreach ($inspectedId in @($bucket.inspectedIds)) {
        if ([string]$inspectedId -ceq $selectedId) {
          $selectedInspected = $true
          break
        }
      }
      if ($selectedInspected) { break }
    }
    if (-not $selectedInspected) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
  } elseif (Test-MathSecrTargetHasSelectedIdClaim $Target) {
    # `missed` and `source_anomaly` receipts may record candidate IDs inside
    # their inspected buckets, but they must not masquerade as selections.
    return [pscustomobject]@{ Present = $true; Valid = $false }
  }

  if ($RequireCompleteCoverage) {
    $wholeWindowCovered = $false
    $singleYearCoverage = [System.Collections.Generic.HashSet[int64]]::new()
    $onlySingleYearBuckets = $true
    foreach ($range in $bucketRanges) {
      if ($range.Start -eq $windowStart -and $range.End -eq $windowEnd) {
        $wholeWindowCovered = $true
      }
      if ($range.Start -ne $range.End) {
        $onlySingleYearBuckets = $false
      } else {
        [void]$singleYearCoverage.Add([int64]$range.Start)
      }
    }
    $singleYearsCovered = $onlySingleYearBuckets -and $singleYearCoverage.Count -eq 3
    foreach ($year in @($windowStart, [int64]$printedYear, $windowEnd)) {
      if (-not $singleYearCoverage.Contains([int64]$year)) {
        $singleYearsCovered = $false
        break
      }
    }
    if (-not $wholeWindowCovered -and -not $singleYearsCovered) {
      return [pscustomobject]@{ Present = $true; Valid = $false }
    }
  }

  return [pscustomobject]@{ Present = $true; Valid = $true }
}

function Test-HasRequiredProperties {
  param($Value, [string[]]$Names)

  if ($Value -isnot [pscustomobject]) {
    return $false
  }
  $actualNames = @($Value.PSObject.Properties.Name)
  foreach ($name in $Names) {
    if ($actualNames -cnotcontains $name) {
      return $false
    }
  }
  return $true
}

function Get-MathSecrStateInferenceCandidate {
  param($ResultRow)

  if (-not (Test-HasRequiredProperties $ResultRow @( "InferredScope", "InferredCollection" ))) {
    return $null
  }
  $hasScope = $null -ne $ResultRow.InferredScope
  $hasCollection = $null -ne $ResultRow.InferredCollection
  if ($hasScope -eq $hasCollection) {
    return $null
  }
  $candidateValue = if ($hasScope) { $ResultRow.InferredScope } else { $ResultRow.InferredCollection }
  if (-not (Test-IsNonblankString $candidateValue)) {
    return $null
  }
  return [pscustomobject]@{
    Kind = if ($hasScope) { "scope" } else { "collection" }
    Value = [string]$candidateValue
  }
}

function Test-MathSecrStateCanonicalOfficialCollection {
  param($Value)

  if (-not (Test-IsNonblankString $Value)) {
    return $false
  }
  return (ConvertTo-MathSecrStateNormalizedScope ([string]$Value)) -ceq
    (ConvertTo-MathSecrStateNormalizedScope "교육청, 평가원")
}

function Test-MathSecrStateBlankProbeReceipt {
  param(
    $BlankProbe,
    [bool]$RequireSubmittedProbe
  )

  if (-not (Test-HasRequiredProperties $BlankProbe @(
    "ReadOnly", "Chips", "Submitted", "FreshResultVerified", "ResultSignature", "FreshSearchReceiptReady"
  ))) {
    return $false
  }
  if (
    -not (Test-IsStrictBoolean $BlankProbe.ReadOnly) -or
    -not (Test-IsStrictBoolean $BlankProbe.Submitted) -or
    -not (Test-IsStrictBoolean $BlankProbe.FreshResultVerified) -or
    -not (Test-IsStrictBoolean $BlankProbe.FreshSearchReceiptReady) -or
    $BlankProbe.ResultSignature -isnot [string]
  ) {
    return $false
  }

  $isIdle = (
    -not $BlankProbe.Submitted -and
    -not $BlankProbe.FreshResultVerified -and
    -not $BlankProbe.FreshSearchReceiptReady -and
    @($BlankProbe.Chips).Count -eq 0 -and
    $BlankProbe.ResultSignature -ceq ""
  )
  # Printed-metadata inference carries an explicitly idle, non-read-only probe
  # receipt. A read-only=true receipt is evidence that a probe was attempted and
  # must satisfy the full submitted/fresh contract even if its reason is forged.
  if (-not $RequireSubmittedProbe -and $isIdle -and -not $BlankProbe.ReadOnly) {
    return $true
  }

  if (
    -not $BlankProbe.ReadOnly -or
    -not $BlankProbe.Submitted -or
    -not $BlankProbe.FreshResultVerified -or
    -not (Test-IsStrictUniqueNonblankStringArray $BlankProbe.Chips 2) -or
    -not (Test-IsNonblankString $BlankProbe.ResultSignature)
  ) {
    return $false
  }

  # The derived phase-ready flag is part of the resolver receipt. Recompute it
  # from the receipt fields so a direct snapshot cannot forge readiness.
  return $BlankProbe.FreshSearchReceiptReady
}

function Test-MathSecrStateScopeIdentity {
  param($Actual, $Expected)

  if (-not (Test-IsNonblankString $Actual) -or -not (Test-IsNonblankString $Expected)) {
    return $false
  }
  return (ConvertTo-MathSecrStateNormalizedScope ([string]$Actual)) -ceq (ConvertTo-MathSecrStateNormalizedScope ([string]$Expected))
}

function Test-MathSecrTargetHasSelectedIdClaim {
  param($Target)
  if ($Target -isnot [pscustomobject]) { return $false }
  $property = $Target.PSObject.Properties['selectedId']
  return $null -ne $property -and -not (
    $null -eq $property.Value -or ($property.Value -is [string] -and $property.Value -ceq '')
  )
}

function Test-MathSecrTargetRowState {
  param($Target)

  $errors = [System.Collections.Generic.List[string]]::new()
  if ($Target -isnot [pscustomobject]) {
    return [pscustomobject]@{ Valid = $false; Resolution = $null; Errors = @('target-row-object-required') }
  }
  foreach ($field in @('initial', 'candidateRecovery', 'wholeDb')) {
    $property = $Target.PSObject.Properties[$field]
    if ($null -eq $property) { continue }
    $allowed = if ($field -ceq 'initial') {
      @('exact', 'missed', 'no_exact', 'not-started', 'pending')
    } else {
      @('exact', 'missed', 'pending')
    }
    if ($property.Value -isnot [string] -or $property.Value -cnotin $allowed) {
      $errors.Add("target-row-state:$field")
    }
  }
  if ($errors.Count -gt 0) {
    return [pscustomobject]@{ Valid = $false; Resolution = $null; Errors = @($errors) }
  }
  $resolution = Get-TargetResolution $Target
  if ($resolution -cnotlike '*selected' -and (Test-MathSecrTargetHasSelectedIdClaim $Target)) {
    $errors.Add('unselected-row-carries-selected-id')
  }
  return [pscustomobject]@{ Valid = $errors.Count -eq 0; Resolution = $resolution; Errors = @($errors) }
}

function Get-TargetResolution {
  param([pscustomobject]$Target)

  $initialProperty = $Target.PSObject.Properties['initial']
  $initial = if ($null -ne $initialProperty) { $initialProperty.Value } else { $null }
  $candidateRecoveryProperty = $Target.PSObject.Properties['candidateRecovery']
  $candidateRecovery = if ($null -ne $candidateRecoveryProperty) { $candidateRecoveryProperty.Value } else { $null }
  $wholeDbProperty = $Target.PSObject.Properties['wholeDb']
  $wholeDb = if ($null -ne $wholeDbProperty) { $wholeDbProperty.Value } else { $null }

  if ($null -eq $initialProperty -or $initial -ceq "not-started") {
    return "not_started"
  }

  $hasPrintedMetadata = $candidateRecovery -eq "missed" -and
    @("printedSourceFamily", "printedSubject", "printedYear" | Where-Object {
      $null -ne $Target.PSObject.Properties[$_]
    }).Count -gt 0
  if ($hasPrintedMetadata) {
    $metadataRescueProperty = $Target.PSObject.Properties['metadataRescue']
    if ($null -eq $metadataRescueProperty -or $metadataRescueProperty.Value -isnot [pscustomobject]) {
      return "metadata_pending"
    }
    $metadataStatusProperty = $metadataRescueProperty.Value.PSObject.Properties['status']
    if ($null -eq $metadataStatusProperty -or $metadataStatusProperty.Value -isnot [string]) {
      return "metadata_pending"
    }
    if ($metadataStatusProperty.Value -ceq "exact") {
      return "metadata_selected"
    }
    if ($metadataStatusProperty.Value -ceq "source_anomaly") {
      # A visually unresolved source/candidate glyph conflict is reportable but
      # never selectable.  It is not a search miss, so a broader whole-DB query
      # cannot resolve the source evidence conflict.
      return "metadata_anomaly"
    }
    if ($metadataStatusProperty.Value -ceq "missed") {
      # Metadata rescue is an added recall gate, not a replacement for the
      # existing bounded whole-DB retry.  Only an exact metadata result may
      # bypass whole DB; an exhausted metadata miss must continue through it.
      if ($wholeDb -eq "exact") {
        return "whole_selected"
      }
      if ($wholeDb -eq "missed") {
        return "missed"
      }
      return "whole_pending"
    }
    return "metadata_pending"
  }

  if ($initial -eq "exact") {
    return "initial_selected"
  }
  if ($candidateRecovery -eq "pending") {
    return "candidate_pending"
  }
  if ($candidateRecovery -eq "exact") {
    return "candidate_selected"
  }
  if ($candidateRecovery -ne "missed") {
    return "candidate_pending"
  }
  if ($wholeDb -eq "exact") {
    return "whole_selected"
  }
  if ($wholeDb -eq "missed") {
    return "missed"
  }
  return "whole_pending"
}

function Get-MathSecrStateProjectedOccurrenceKeys {
  param(
    $RootSnapshot,
    $BundleObject,
    [string]$PropertyName
  )

  $raw = Get-MathSecrStateOptionalStringArray $BundleObject $PropertyName
  if (-not (Test-IsStrictUniqueOccurrenceKeyArray $raw)) {
    return @()
  }

  $targetsProperty = if ($null -ne $RootSnapshot -and $RootSnapshot -is [pscustomobject]) {
    $RootSnapshot.PSObject.Properties['targets']
  } else {
    $null
  }
  if ($null -eq $targetsProperty -or $targetsProperty.Value -isnot [System.Array]) {
    return @()
  }

  $expected = [System.Collections.Generic.List[string]]::new()
  foreach ($target in @($targetsProperty.Value)) {
    if ($target -isnot [pscustomobject]) {
      return @()
    }
    $rowState = Test-MathSecrTargetRowState $target
    if (-not $rowState.Valid) {
      return @()
    }
    $resolution = $rowState.Resolution
    if ($resolution -notlike "*selected") {
      continue
    }
    $numberProperty = $target.PSObject.Properties['number']
    if ($null -eq $numberProperty) {
      return @()
    }
    $targetNumber = [string]$numberProperty.Value
    $occurrenceProperty = $target.PSObject.Properties['occurrenceKey']
    $key = if ($null -ne $occurrenceProperty) { $occurrenceProperty.Value } else { $targetNumber }
    if (-not (Test-IsCanonicalOccurrenceKey $key)) {
      return @()
    }
    $expected.Add([string]$key)
  }

  if (-not (Test-OrderedIdsEqual $expected $raw)) {
    return @()
  }
  return @($raw)
}

function Get-MathSecrStatePropertyValue {
  param($Object, [string]$PropertyName)
  if ($null -eq $Object -or $Object -isnot [pscustomobject]) { return $null }
  $property = $Object.PSObject.Properties[$PropertyName]
  if ($null -eq $property) { return $null }
  # Arrays must not collapse to scalars through pipeline enumeration.
  return ,$property.Value
}

function Set-MathSecrStateUnresolvedReason {
  param($Derived, $Target, [string]$Reason)
  $number = [string]$Target.number
  for ($index = $Derived.UnresolvedReasons.Count - 1; $index -ge 0; $index--) {
    if ($Derived.UnresolvedReasons[$index].SourceProblemNumber -ceq $number) {
      if ($Reason) { $Derived.UnresolvedReasons[$index].Reason = $Reason } else { $Derived.UnresolvedReasons.RemoveAt($index) }
      return
    }
  }
  if ($Reason) {
    $keyProperty = $Target.PSObject.Properties['occurrenceKey']
    $Derived.UnresolvedReasons.Add([pscustomobject]@{
      SourceProblemNumber = $number
      OccurrenceKey = if ($null -ne $keyProperty) { $keyProperty.Value } else { $number }
      Reason = $Reason
    })
  }
}

function Test-MathSecrBeforeNextUnusedPackets {
  param($Snapshot)
  foreach ($packetName in @('edit', 'persistence')) {
    $property = $Snapshot.PSObject.Properties[$packetName]
    if ($null -eq $property) { continue }
    $packet = $property.Value
    if ($packet -isnot [pscustomobject]) { return $false }
    $arrayNames = if ($packetName -ceq 'edit') { @('draftIds', 'oldIds', 'draftOccurrenceKeys') } else { @('ids', 'occurrenceKeys') }
    foreach ($name in $arrayNames) {
      $arrayProperty = $packet.PSObject.Properties[$name]
      if ($null -eq $arrayProperty) { continue }
      if (-not (Test-IsStrictIdArray $arrayProperty.Value) -or @($arrayProperty.Value).Count -gt 0) { return $false }
    }
    $reloadProperty = $packet.PSObject.Properties['freshReloadVerified']
    if ($null -ne $reloadProperty -and (-not (Test-IsStrictBoolean $reloadProperty.Value) -or $reloadProperty.Value)) { return $false }
    $recoveryProperty = $packet.PSObject.Properties['recovery']
    if ($null -ne $recoveryProperty -and $recoveryProperty.Value -cne 'not_needed') { return $false }
  }
  return $true
}

function Read-MathSecrEditAppendArtifact {
  param($Receipt, [string]$ProjectRoot, $Context = $null)
  if (-not (Test-HasRequiredProperties $Receipt @('path','sha256')) -or
      $Receipt.path -isnot [string] -or $Receipt.path -cne $Receipt.path.Trim() -or
      [IO.Path]::IsPathRooted($Receipt.path) -or $Receipt.path.Contains(':') -or
      $Receipt.sha256 -isnot [string] -or $Receipt.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'edit-append-artifact-binding'
  }
  $segments=@($Receipt.path -split '[\\/]+')
  if (@($segments | Where-Object { $_ -cin @('','.','..') }).Count -gt 0) { throw 'edit-append-artifact-path' }
  $root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
  $full=[IO.Path]::GetFullPath((Join-Path $root $Receipt.path))
  if (-not $full.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $full -PathType Leaf) -or [IO.Path]::GetExtension($full).ToLowerInvariant() -cne '.json') { throw 'edit-append-artifact-path' }
  $cursor=$ProjectRoot
  foreach($segment in $segments) {
    $cursor=Join-Path $cursor $segment
    if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'edit-append-artifact-reparse' }
  }
  $Context = Enter-MathSecrValidationContext -Context $Context -ProjectRoot $ProjectRoot
  try {
  # The legacy 'edit-append-artifact-changed' code cannot occur with a single
  # byte read: parsing and hashing now consume the same immutable byte buffer.
  try {
    return (Get-MathSecrValidationArtifact -Path $full -ExpectedSha256 $Receipt.sha256 -Context $Context -Parse).Value
  } catch {
    if ($_.Exception.Data['MathSecrArtifactError'] -ceq 'hash') { throw 'edit-append-artifact-hash' }
    throw
  }
  } finally { Exit-MathSecrValidationContext -Context $Context }
}

function Get-MathSecrAppendSnapshotTypeFingerprint {
  param($Snapshot)
  if (-not ('MathSecr.AppendSnapshotTypeFingerprint' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Numerics;
using System.Text;
namespace MathSecr {
    public static class AppendSnapshotTypeFingerprint {
        private const PSMemberTypes ExtendedProperties = PSMemberTypes.NoteProperty |
            PSMemberTypes.AliasProperty | PSMemberTypes.ScriptProperty | PSMemberTypes.CodeProperty;

        public static string Get(PSObject snapshot) {
            var pending = new Stack<object>();
            var depths = new Stack<int>();
            var seen = new HashSet<object>(ReferenceEqualityComparer.Instance);
            var fingerprint = new StringBuilder();
            pending.Push(snapshot);
            depths.Push(0);
            while (pending.Count > 0) {
                object node = pending.Pop();
                int depth = depths.Pop();
                // ConvertTo-Json's depth limit must not hide deeper mutable data.
                if (depth > 100) return null;
                if (node == null) { fingerprint.Append("null;"); continue; }
                PSObject wrapped = PSObject.AsPSObject(node);
                object value = wrapped.BaseObject;
                Type type = value.GetType();
                fingerprint.Append(type.AssemblyQualifiedName).Append(';');
                if (type.IsPrimitive || type.IsEnum || value is string || value is decimal ||
                    value is DateTime || value is DateTimeOffset || value is Guid || value is BigInteger) {
                    if (wrapped.Properties.Match("*", ExtendedProperties).Count > 0) return null;
                    continue;
                }
                // PSCustomObject BaseObject can be a shared sentinel. Its wrapper
                // owns the properties and is the identity needed for cycle checks.
                object identity = value is PSCustomObject ? (object)wrapped : value;
                if (!seen.Add(identity)) return null;
                if (value is Array array) {
                    if (array.Rank != 1 || array.GetLowerBound(0) != 0 ||
                        wrapped.Properties.Match("*", ExtendedProperties).Count > 0) return null;
                    fingerprint.Append(array.Length).Append(':');
                    for (int index = array.Length - 1; index >= 0; index--) {
                        pending.Push(array.GetValue(index));
                        depths.Push(depth + 1);
                    }
                } else if (value is PSCustomObject) {
                    var properties = new List<PSPropertyInfo>(wrapped.Properties);
                    fingerprint.Append(properties.Count).Append(':');
                    foreach (PSPropertyInfo property in properties) {
                        if (property.MemberType != PSMemberTypes.NoteProperty) return null;
                        fingerprint.Append(property.Name.Length).Append(':').Append(property.Name);
                    }
                    for (int index = properties.Count - 1; index >= 0; index--) {
                        pending.Push(properties[index].Value);
                        depths.Push(depth + 1);
                    }
                } else {
                    // Opaque objects, computed properties, and repeated references
                    // fall back to validation instead of hiding data in the cache.
                    return null;
                }
            }
            return fingerprint.ToString();
        }
    }
}
'@
  }
  return [MathSecr.AppendSnapshotTypeFingerprint]::Get($Snapshot)
}

function Test-MathSecrEditAppendReceipt {
  param($Snapshot, $ExpectedIds, $ExpectedKeys, [string]$ProjectRoot, [int]$Depth, $Context = $null)
  if ($null -eq $Context -or $Context.ActiveDepth -le 0 -or $null -eq $Snapshot -or $Depth -ge 64) {
    return Invoke-MathSecrEditAppendReceiptValidation @PSBoundParameters
  }

  # Keep the original validator's early guards and error conversion authoritative
  # if an input cannot be serialized for the optional successful-result cache.
  try {
    $snapshotJson = ConvertTo-Json -InputObject $Snapshot -Depth 100 -Compress -ErrorAction Stop
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
      $snapshotDigest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($snapshotJson))).Replace('-', '')
    } finally { $sha.Dispose() }
    # JSON erases some CLR distinctions (integer/enum and string/char).
    # Preserve every data node's type as a separate cache condition.
    $snapshotTypes = Get-MathSecrAppendSnapshotTypeFingerprint -Snapshot $Snapshot
  } catch {
    [void]$Context.AppendReceiptCache.Remove($Snapshot)
    return Invoke-MathSecrEditAppendReceiptValidation @PSBoundParameters
  }
  if ($null -eq $snapshotTypes) {
    [void]$Context.AppendReceiptCache.Remove($Snapshot)
    return Invoke-MathSecrEditAppendReceiptValidation @PSBoundParameters
  }

  $entries = $null
  if ($Context.AppendReceiptCache.TryGetValue($Snapshot, [ref]$entries)) {
    # Discard stale entries before looking for a match. Restoring a mutated
    # snapshot must run validation again instead of reviving an older success.
    for ($index = $entries.Count - 1; $index -ge 0; $index--) {
      if ($entries[$index].SnapshotDigest -cne $snapshotDigest -or
          $entries[$index].SnapshotTypes -cne $snapshotTypes) { $entries.RemoveAt($index) }
    }
    foreach ($entry in $entries) {
      if ($entry.ProjectRoot -ceq $ProjectRoot -and $entry.Depth -eq $Depth -and
          (Test-OrderedIdsEqual $entry.ExpectedIds $ExpectedIds) -and
          (Test-OrderedIdsEqual $entry.ExpectedKeys $ExpectedKeys)) {
        return $entry.Result
      }
    }
  }

  $result = Invoke-MathSecrEditAppendReceiptValidation @PSBoundParameters
  if ($result.Valid -eq $true) {
    if ($null -eq $entries) {
      $entries = [Collections.Generic.List[object]]::new()
      $Context.AppendReceiptCache.Add($Snapshot, $entries)
    }
    $entries.Add([pscustomobject]@{
      ProjectRoot = $ProjectRoot
      Depth = $Depth
      ExpectedIds = [string[]]@(ConvertTo-StringArray $ExpectedIds)
      ExpectedKeys = [string[]]@(ConvertTo-StringArray $ExpectedKeys)
      SnapshotDigest = $snapshotDigest
      SnapshotTypes = $snapshotTypes
      Result = $result
    })
  }
  return $result
}

function Invoke-MathSecrEditAppendReceiptValidation {
  param($Snapshot, $ExpectedIds, $ExpectedKeys, [string]$ProjectRoot, [int]$Depth, $Context = $null)
  $contextEntered = $false
  try {
  try {
    if ($Depth -ge 64) { throw 'edit-append-history-depth' }
    $receipt=$Snapshot.editAppendReceipt
    if (-not (Test-HasRequiredProperties $receipt @('schemaVersion','appendId','surface','priorSessionArtifact','beforeObservationArtifact','deltaTargets','addActionArtifact','confirmActionArtifact','draftObservationArtifact')) -or
        -not (Test-IsStrictInteger $receipt.schemaVersion) -or $receipt.schemaVersion -ne 1 -or
        -not (Test-IsCanonicalId $receipt.appendId) -or $receipt.surface -isnot [string] -or $receipt.surface -cne 'aside-repl' -or
        $receipt.deltaTargets -isnot [array] -or $receipt.deltaTargets.Count -eq 0) { throw 'edit-append-schema' }
    $Context = Enter-MathSecrValidationContext -Context $Context -ProjectRoot $ProjectRoot
    $contextEntered = $true
    $prior=Read-MathSecrEditAppendArtifact $receipt.priorSessionArtifact $ProjectRoot -Context $Context
    if (-not (Test-HasRequiredProperties $prior @('schemaVersion','sessionId','paper','sourceTargets','sourceRosterArtifact','snapshot')) -or
        -not (Test-IsStrictInteger $prior.schemaVersion) -or $prior.schemaVersion -ne 1 -or
        -not (Test-HasRequiredProperties $prior.paper @('url')) -or $prior.paper.url -isnot [string] -or
        $prior.snapshot -isnot [pscustomobject] -or $prior.snapshot.targets -isnot [array] -or
        $prior.snapshot.targets.Count -ne $Snapshot.targets.Count) { throw 'edit-append-prior-session' }
    $priorState = Get-MathSecrCachedStateResult -Context $Context -ArtifactSha256 $receipt.priorSessionArtifact.sha256 -Phase AfterReload -AppendDepth ($Depth+1)
    if ($null -eq $priorState) {
      $priorState = Invoke-MathSecrStateMachine -Snapshot $prior.snapshot -ProjectRoot $ProjectRoot -Phase AfterReload -AppendDepth ($Depth+1) -Context $Context
      Set-MathSecrCachedStateResult -Context $Context -ArtifactSha256 $receipt.priorSessionArtifact.sha256 -Snapshot $prior.snapshot -Phase AfterReload -StateResult $priorState
    }
    if ($priorState.State -cne 'REPORT' -or $priorState.Status -cnotin @('완료','부분 완료') -or $priorState.PersistedCount -lt 1) { throw 'edit-append-prior-state' }
    if (-not (Test-IsStrictIdArray $Snapshot.selectionBeforeNextIds) -or
        -not (Test-MathSecrStateOptionalOccurrenceKeyArray $Snapshot 'selectionBeforeNextOccurrenceKeys') -or
        -not (Test-MathSecrStateOptionalOccurrenceKeyArray $prior.snapshot 'selectionBeforeNextOccurrenceKeys') -or
        -not (Test-OrderedIdsEqual $prior.snapshot.selectionBeforeNextIds $Snapshot.selectionBeforeNextIds) -or
        -not (Test-IsStrictBoolean $Snapshot.nextClicked) -or -not $Snapshot.nextClicked -or
        -not (Test-IsStrictBoolean $prior.snapshot.nextClicked) -or -not $prior.snapshot.nextClicked -or
        -not (Test-OrderedIdsEqual (Get-MathSecrStateOptionalStringArray $prior.snapshot 'selectionBeforeNextOccurrenceKeys') (Get-MathSecrStateOptionalStringArray $Snapshot 'selectionBeforeNextOccurrenceKeys'))) { throw 'edit-append-first-next-rewritten' }
    $priorTargetsByNumber = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $targetsByKey = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($target in $prior.snapshot.targets) {
      if (-not $priorTargetsByNumber.ContainsKey([string]$target.number)) { $priorTargetsByNumber.Add([string]$target.number, $target) }
    }
    foreach ($target in $Snapshot.targets) {
      if (-not $targetsByKey.ContainsKey([string]$target.occurrenceKey)) { $targetsByKey.Add([string]$target.occurrenceKey, $target) }
    }
    $priorKeys = @($priorState.SelectedSourceNumbers | ForEach-Object { $priorTargetsByNumber[[string]$_].occurrenceKey })
    $priorIndexes = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $priorKeys.Count; $i++) {
      if (-not $priorIndexes.ContainsKey([string]$priorKeys[$i])) { $priorIndexes.Add([string]$priorKeys[$i], $i) }
    }
    $expectedKeySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $ExpectedKeys) { [void]$expectedKeySet.Add([string]$key) }
    $deltaIds=[Collections.Generic.List[string]]::new();$deltaKeys=[Collections.Generic.List[string]]::new()
    for($i=0;$i -lt $Snapshot.targets.Count;$i++) {
      $old=$prior.snapshot.targets[$i];$current=$Snapshot.targets[$i]
      if ($old.number -cne $current.number -or $old.occurrenceKey -cne $current.occurrenceKey -or
          -not (Test-HasRequiredProperties $old.sourceBodyArtifact @('path','sha256')) -or
          -not (Test-HasRequiredProperties $current.sourceBodyArtifact @('path','sha256')) -or
          $old.sourceBodyArtifact.path -isnot [string] -or $current.sourceBodyArtifact.path -isnot [string] -or
          $old.sourceBodyArtifact.path -cne $current.sourceBodyArtifact.path -or
          $old.sourceBodyArtifact.sha256 -isnot [string] -or $current.sourceBodyArtifact.sha256 -isnot [string] -or
          -not [string]::Equals($old.sourceBodyArtifact.sha256,$current.sourceBodyArtifact.sha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'edit-append-roster-changed' }
      if ($priorIndexes.ContainsKey([string]$current.occurrenceKey)) {
        if (-not (Test-MathSecrObjectEquals $old $current)) { throw 'edit-append-prior-selection-changed' }
      } elseif ($expectedKeySet.Contains([string]$current.occurrenceKey)) {
        $deltaKeys.Add($current.occurrenceKey);$deltaIds.Add($current.selectedId)
      }
    }
    if ($deltaIds.Count -ne $receipt.deltaTargets.Count -or @($ExpectedIds).Count -ne ($priorState.PersistedCount+$deltaIds.Count)) { throw 'edit-append-delta-coverage' }
    for($i=0;$i -lt $deltaIds.Count;$i++) {
      $row=$receipt.deltaTargets[$i];$target=$targetsByKey[$deltaKeys[$i]]
      if (-not (Test-HasRequiredProperties $row @('sourceProblemNumber','occurrenceKey','problemId')) -or
          $row.sourceProblemNumber -isnot [string] -or $row.sourceProblemNumber -cne $target.number -or
          -not (Test-IsCanonicalOccurrenceKey $row.occurrenceKey) -or $row.occurrenceKey -cne $deltaKeys[$i] -or
          -not (Test-IsCanonicalId $row.problemId) -or $row.problemId -cne $deltaIds[$i]) { throw 'edit-append-delta-target-binding' }
    }
    # Derive the whole bundle from the two independently bound sets, in source
    # order. The historical FirstNext selection remains a separate observation.
    $combinedIds=[Collections.Generic.List[string]]::new();$combinedKeys=[Collections.Generic.List[string]]::new()
    $deltaIndexes = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $deltaKeys.Count; $i++) {
      if (-not $deltaIndexes.ContainsKey($deltaKeys[$i])) { $deltaIndexes.Add($deltaKeys[$i], $i) }
    }
    foreach($target in $Snapshot.targets) {
      $key = [string]$target.occurrenceKey
      if($priorIndexes.ContainsKey($key)){$combinedIds.Add($priorState.PersistedIds[$priorIndexes[$key]]);$combinedKeys.Add($key)}
      elseif($deltaIndexes.ContainsKey($key)){$combinedIds.Add($deltaIds[$deltaIndexes[$key]]);$combinedKeys.Add($key)}
    }
    if (-not (Test-OrderedIdsEqual $ExpectedIds $combinedIds) -or -not (Test-OrderedIdsEqual $ExpectedKeys $combinedKeys)) { throw 'edit-append-combined-order' }
    $before=Read-MathSecrEditAppendArtifact $receipt.beforeObservationArtifact $ProjectRoot -Context $Context
    $add=Read-MathSecrEditAppendArtifact $receipt.addActionArtifact $ProjectRoot -Context $Context
    $confirm=Read-MathSecrEditAppendArtifact $receipt.confirmActionArtifact $ProjectRoot -Context $Context
    $draft=Read-MathSecrEditAppendArtifact $receipt.draftObservationArtifact $ProjectRoot -Context $Context
    if (-not (Test-HasRequiredProperties $before @('capturedAtUtc','url','priorEditIds','modalSelectedIds','action')) -or
        -not (Test-MathSecrObservationTimestamp $before.capturedAtUtc) -or $before.url -isnot [string] -or $before.url -cne $prior.paper.url -or
        $before.action -isnot [string] -or $before.action -cne '추가' -or
        -not (Test-IsStrictIdArray $before.priorEditIds) -or -not (Test-IsStrictIdArray $before.modalSelectedIds) -or
        -not (Test-OrderedIdsEqual $priorState.PersistedIds $before.priorEditIds) -or -not (Test-OrderedIdsEqual $deltaIds $before.modalSelectedIds)) { throw 'edit-append-before-bundle' }
    foreach($entry in @(@{value=$add;name='추가'},@{value=$confirm;name='확인'})) {
      $action=$entry.value
      if (-not (Test-HasRequiredProperties $action @('actionId','surface','startedAtUtc','completedAtUtc','timingBasis','url','controlName','action','evidenceArtifact','executionBinding')) -or
          -not (Test-IsCanonicalId $action.actionId) -or $action.surface -isnot [string] -or $action.surface -cne 'aside-repl' -or
          -not (Test-MathSecrObservationTimestamp $action.startedAtUtc) -or -not (Test-MathSecrObservationTimestamp $action.completedAtUtc) -or
          $action.timingBasis -isnot [string] -or $action.timingBasis -cnotin @('observation-window','recorded-execution') -or $action.url -isnot [string] -or $action.url -cne $prior.paper.url -or
          $action.controlName -isnot [string] -or $action.controlName -cne $entry.name -or $action.action -isnot [string] -or $action.action -cne 'click') { throw 'edit-append-action-evidence' }
      $execution=Read-MathSecrEditAppendArtifact $action.evidenceArtifact $ProjectRoot -Context $Context
      $binding=$action.executionBinding
      if (-not (Test-HasRequiredProperties $execution @('schemaVersion','records')) -or
          -not (Test-IsStrictInteger $execution.schemaVersion) -or $execution.schemaVersion -ne 1 -or $execution.records -isnot [array] -or
          -not (Test-HasRequiredProperties $binding @('commandRecordKey','resultRecordKey','completionMarker')) -or
          -not (Test-IsCanonicalId $binding.commandRecordKey) -or -not (Test-IsCanonicalId $binding.resultRecordKey) -or $binding.commandRecordKey -ceq $binding.resultRecordKey -or
          $binding.completionMarker -isnot [string] -or $binding.completionMarker -notmatch '^[A-Za-z0-9_]{1,128}:$') { throw 'edit-append-execution-schema' }
      $commandRecords=@($execution.records | Where-Object {(Get-MathSecrStatePropertyValue $_ 'key') -ceq $binding.commandRecordKey})
      $resultRecords=@($execution.records | Where-Object {(Get-MathSecrStatePropertyValue $_ 'key') -ceq $binding.resultRecordKey})
      if ($commandRecords.Count -ne 1 -or $resultRecords.Count -ne 1) { throw 'edit-append-execution-record-binding' }
      $commandValue=Get-MathSecrStatePropertyValue $commandRecords[0] 'value'
      $resultValue=Get-MathSecrStatePropertyValue $resultRecords[0] 'value'
      $commandText=if($commandValue -is [string]){$commandValue}else{Get-MathSecrStatePropertyValue $commandValue 'output'}
      $resultText=if($resultValue -is [string]){$resultValue}else{Get-MathSecrStatePropertyValue $resultValue 'output'}
      if ($commandText -isnot [string] -or -not $commandText.Contains('.click(') -or -not $commandText.Contains($action.controlName) -or
          $resultText -isnot [string] -or -not $resultText.Contains($binding.completionMarker)) { throw 'edit-append-execution-content-binding' }
    }
    if ($add.actionId -ceq $confirm.actionId) { throw 'edit-append-reused-action' }
    if ($add.timingBasis -ceq 'observation-window') {
      if (-not (Test-HasRequiredProperties $add @('afterObservationArtifact'))) { throw 'edit-append-action-window' }
      $addAfter=Read-MathSecrEditAppendArtifact $add.afterObservationArtifact $ProjectRoot -Context $Context
      if (-not (Test-HasRequiredProperties $addAfter @('capturedAtUtc','url','draftIds')) -or
          -not (Test-MathSecrObservationTimestamp $addAfter.capturedAtUtc) -or $addAfter.url -isnot [string] -or $addAfter.url -cne $prior.paper.url -or
          -not (Test-IsStrictIdArray $addAfter.draftIds) -or -not (Test-OrderedIdsEqual $combinedIds $addAfter.draftIds) -or
          $add.startedAtUtc -cne $before.capturedAtUtc -or $add.completedAtUtc -cne $addAfter.capturedAtUtc) { throw 'edit-append-action-window' }
    } else {
      if (-not (Test-HasRequiredProperties $add @('afterObservationArtifact'))) { throw 'edit-append-add-observation' }
      $addAfter=Read-MathSecrEditAppendArtifact $add.afterObservationArtifact $ProjectRoot -Context $Context
      if (-not (Test-HasRequiredProperties $addAfter @('schemaVersion','surface','controlName','action','startedAtUtc','completedAtUtc','capturedAtUtc','url','draftIds')) -or
          -not (Test-IsStrictInteger $addAfter.schemaVersion) -or $addAfter.schemaVersion -ne 1 -or
          $addAfter.surface -isnot [string] -or $addAfter.surface -cne 'aside-repl' -or $addAfter.controlName -isnot [string] -or $addAfter.controlName -cne '추가' -or
          $addAfter.action -isnot [string] -or $addAfter.action -cne 'click' -or
          $addAfter.startedAtUtc -isnot [string] -or $addAfter.startedAtUtc -cne $add.startedAtUtc -or
          $addAfter.completedAtUtc -isnot [string] -or $addAfter.completedAtUtc -cne $add.completedAtUtc -or
          -not (Test-MathSecrObservationTimestamp $addAfter.capturedAtUtc) -or $addAfter.url -isnot [string] -or $addAfter.url -cne $prior.paper.url -or
          -not (Test-IsStrictIdArray $addAfter.draftIds) -or -not (Test-OrderedIdsEqual $combinedIds $addAfter.draftIds)) { throw 'edit-append-add-action-binding' }
    }
    if ($confirm.timingBasis -cne 'recorded-execution') { throw 'edit-append-confirm-timing' }
    if (-not (Test-HasRequiredProperties $confirm @('beforeObservationArtifact','afterObservationArtifact'))) { throw 'edit-append-confirm-observations' }
    $confirmBefore=Read-MathSecrEditAppendArtifact $confirm.beforeObservationArtifact $ProjectRoot -Context $Context
    $confirmAfter=Read-MathSecrEditAppendArtifact $confirm.afterObservationArtifact $ProjectRoot -Context $Context
    foreach($observed in @($confirmBefore,$confirmAfter)) {
      if (-not (Test-HasRequiredProperties $observed @('capturedAtUtc','url','draftIds','controlName','surface')) -or
          -not (Test-MathSecrObservationTimestamp $observed.capturedAtUtc) -or $observed.url -isnot [string] -or $observed.url -cne $prior.paper.url -or
          $observed.surface -isnot [string] -or $observed.surface -cne 'aside-repl' -or $observed.controlName -isnot [string] -or $observed.controlName -cne '확인' -or
          -not (Test-IsStrictIdArray $observed.draftIds) -or -not (Test-OrderedIdsEqual $combinedIds $observed.draftIds)) { throw 'edit-append-confirm-observations' }
    }
    if (-not (Test-HasRequiredProperties $confirmAfter @('schemaVersion','action','startedAtUtc','completedAtUtc')) -or
        -not (Test-IsStrictInteger $confirmAfter.schemaVersion) -or $confirmAfter.schemaVersion -ne 1 -or
        $confirmAfter.action -isnot [string] -or $confirmAfter.action -cne 'click' -or
        $confirmAfter.startedAtUtc -isnot [string] -or $confirmAfter.startedAtUtc -cne $confirm.startedAtUtc -or
        $confirmAfter.completedAtUtc -isnot [string] -or $confirmAfter.completedAtUtc -cne $confirm.completedAtUtc) { throw 'edit-append-confirm-action-binding' }
    if (-not (Test-HasRequiredProperties $draft @('capturedAtUtc','url','draftIds')) -or
        -not (Test-MathSecrObservationTimestamp $draft.capturedAtUtc) -or $draft.url -isnot [string] -or $draft.url -cne $prior.paper.url -or
        -not (Test-IsStrictIdArray $draft.draftIds) -or -not (Test-OrderedIdsEqual $combinedIds $draft.draftIds) -or
        -not (Test-OrderedIdsEqual $combinedIds $Snapshot.edit.draftIds)) { throw 'edit-append-draft-bundle' }
    $times=@($before.capturedAtUtc,$add.startedAtUtc,$add.completedAtUtc,$addAfter.capturedAtUtc,$confirmBefore.capturedAtUtc,$confirm.startedAtUtc,$confirm.completedAtUtc,$confirmAfter.capturedAtUtc,$draft.capturedAtUtc) | ForEach-Object {[DateTimeOffset]::Parse($_,[Globalization.CultureInfo]::InvariantCulture)}
    for($i=1;$i -lt $times.Count;$i++){if($times[$i] -lt $times[$i-1]){throw 'edit-append-action-order'}}
    return [pscustomobject]@{Valid=$true;SelectedIds=@($combinedIds);SelectedOccurrenceKeys=@($combinedKeys);PriorSession=$prior;PaperUrl=$prior.paper.url;DraftCapturedAtUtc=$draft.capturedAtUtc;AppendId=$receipt.appendId;Errors=@()}
  } catch { return [pscustomobject]@{Valid=$false;Errors=@($_.Exception.Message)} }
  } finally { if ($contextEntered) { Exit-MathSecrValidationContext -Context $Context } }
}

function New-StateResult {
  param([hashtable]$Contract)

  $snapshot = $Contract.Input
  $edit = Get-MathSecrStatePropertyValue $snapshot 'edit'
  $persistence = Get-MathSecrStatePropertyValue $snapshot 'persistence'
  $selectionIds = @(ConvertTo-StringArray (Get-MathSecrStatePropertyValue $snapshot 'selectionBeforeNextIds'))
  $draftIds = @(ConvertTo-StringArray (Get-MathSecrStatePropertyValue $edit 'draftIds'))
  $persistedIds = @(ConvertTo-StringArray (Get-MathSecrStatePropertyValue $persistence 'ids'))
  $selectionOccurrenceKeys = @(Get-MathSecrStateProjectedOccurrenceKeys $snapshot $snapshot "selectionBeforeNextOccurrenceKeys")
  $draftOccurrenceKeys = @(Get-MathSecrStateProjectedOccurrenceKeys $snapshot $edit "draftOccurrenceKeys")
  $persistedOccurrenceKeys = @(Get-MathSecrStateProjectedOccurrenceKeys $snapshot $persistence "occurrenceKeys")
  $derived = $Contract.Derived
  if ($null -ne $derived -and $null -ne $derived.PSObject.Properties['AppendSelectedIds']) {
    $selectionIds=@($derived.AppendSelectedIds)
    $selectionOccurrenceKeys=@($derived.AppendSelectedOccurrenceKeys)
  }
  $unresolvedReasons = if ($null -ne $derived) { @($derived.UnresolvedReasons) } else { @() }
  return [pscustomobject]@{
    Phase = if ($Contract.ContainsKey('Phase')) { $Contract.Phase } else { 'AfterReload' }
    State = $Contract.State
    Status = $Contract.Status
    Trace = @($Contract.Trace)
    SelectedIds = $selectionIds
    SelectionBeforeNextIds = @(ConvertTo-StringArray (Get-MathSecrStatePropertyValue $snapshot 'selectionBeforeNextIds'))
    SelectedCount = $selectionIds.Count
    DraftIds = $draftIds
    DraftCount = $draftIds.Count
    PersistedIds = $persistedIds
    PersistedCount = $persistedIds.Count
    SelectedOccurrenceKeys = $selectionOccurrenceKeys
    DraftOccurrenceKeys = $draftOccurrenceKeys
    PersistedOccurrenceKeys = $persistedOccurrenceKeys
    BlockedActions = @($Contract.BlockedActions)
    EvidenceErrors = if ($Contract.ContainsKey('EvidenceErrors')) { @($Contract.EvidenceErrors) } else { @() }
    SelectionEvidence = if ($Contract.ContainsKey('SelectionEvidence')) { @($Contract.SelectionEvidence) } elseif ($null -ne $derived) { @($derived.SelectionEvidence) } else { @() }
    SelectedSourceNumbers = if ($null -ne $derived) { @($derived.SelectedSourceNumbers) } else { @() }
    ClosedMissedSourceNumbers = if ($null -ne $derived) { @($derived.ClosedMissedSourceNumbers) } else { @() }
    UnresolvedSourceNumbers = @($unresolvedReasons | ForEach-Object { $_.SourceProblemNumber })
    UnresolvedReasons = $unresolvedReasons
    CanNextStep = $Contract.ContainsKey('CanNextStep') -and $Contract.CanNextStep -eq $true
    IssueClicked = if (Test-IsStrictBoolean (Get-MathSecrStatePropertyValue $snapshot 'issueClicked')) { $snapshot.issueClicked } else { $false }
  }
}

function Invoke-MathSecrStateMachine {
  param(
    [pscustomobject]$Snapshot,
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$Phase = "AfterReload",
    [int]$AppendDepth = 0,
    $Context = $null
  )
  $Context = Enter-MathSecrValidationContext -Context $Context -ProjectRoot $ProjectRoot
  try {

  $ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

  $trace = [System.Collections.Generic.List[string]]::new()
  $derived = [pscustomobject]@{
    SelectedSourceNumbers = [System.Collections.Generic.List[string]]::new()
    ClosedMissedSourceNumbers = [System.Collections.Generic.List[string]]::new()
    UnresolvedReasons = [System.Collections.Generic.List[object]]::new()
    SelectionEvidence = [System.Collections.Generic.List[object]]::new()
  }
  $trace.Add("PREPARE")
  if (-not (Test-HasRequiredProperties $Snapshot @('sourcePresent', 'issueClicked', 'asideRepl', 'cleanStateVerified', 'scope', 'targets', 'selectionBeforeNextIds', 'nextClicked'))) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'PREPARE'; Status = '차단'; Trace = @($trace); EvidenceErrors = @('snapshot-required-properties'); BlockedActions = @('next_step') }
  }
  $actionProperty = $Snapshot.PSObject.Properties['requestedAction']
  $partialSaveRequested = $null -ne $actionProperty -and $actionProperty.Value -ceq 'partial-save'
  if ($Phase -cnotin @('BeforeNext', 'AfterReload') -or
      ($null -ne $actionProperty -and -not $partialSaveRequested)) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'PREPARE'; Status = '차단'; Trace = @($trace); EvidenceErrors = @('unsupported-phase-or-action'); BlockedActions = @('next_step') }
  }
  if (-not (Test-IsStrictBoolean $Snapshot.issueClicked) -or $Snapshot.issueClicked) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "PREPARE"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
  }
  if (-not (Test-IsStrictBoolean $Snapshot.sourcePresent) -or -not $Snapshot.sourcePresent) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "PREPARE"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
  }

  $trace.Add("ASIDE_REPL_READY")
  if (
    -not (Test-IsStrictBoolean $Snapshot.asideRepl.available) -or
    -not (Test-IsStrictBoolean $Snapshot.asideRepl.paperVerified) -or
    -not (Test-IsStrictBoolean $Snapshot.asideRepl.nonAsideReplLiveManipulation) -or
    -not $Snapshot.asideRepl.available -or
    -not $Snapshot.asideRepl.paperVerified -or
    $Snapshot.asideRepl.nonAsideReplLiveManipulation
  ) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "ASIDE_REPL_READY"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
  }

  $trace.Add("CLEAN_STATE")
  if (-not (Test-IsStrictBoolean $Snapshot.cleanStateVerified) -or -not $Snapshot.cleanStateVerified) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "CLEAN_STATE"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
  }

  $dbInferenceRequired = $null -ne $Snapshot.PSObject.Properties['dbInference']
  $dbInferenceRows = @()
  if ($dbInferenceRequired) {
    $trace.Add("DB_INFERENCE")
    $dbInference = $Snapshot.dbInference
    if (
      -not (Test-HasRequiredProperties $dbInference @(
        "Status", "InferredScope", "InferredCollection", "Confidence", "Reason",
        "ScopeLockReady", "FreshSearchReceiptReady", "Receipts", "Results"
      )) -or
      $null -ne $dbInference.PSObject.Properties['required'] -or
      $null -ne $Snapshot.PSObject.Properties['searchReceipt'] -or
      $dbInference.Status -isnot [string] -or
      $dbInference.Status -cnotin @( "pending", "unresolved", "inferred" )
    ) {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "DB_INFERENCE"
        Status = "차단"
        Trace = @($trace)
        BlockedActions = @( "select_cards", "select_all", "next_step" )
      }
    }
    if ($dbInference.Status -ceq "pending") {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "DB_INFERENCE"
        Status = "db-inference-required"
        Trace = @($trace)
        BlockedActions = @( "select_cards", "select_all", "next_step" )
      }
    }
    if ($dbInference.Status -ceq "unresolved") {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "DB_INFERENCE"
        Status = "db-inference-unresolved"
        Trace = @($trace)
        BlockedActions = @( "select_cards", "select_all", "next_step" )
      }
    }
    if (
      -not (Test-IsStrictBoolean $dbInference.ScopeLockReady) -or
      -not (Test-IsStrictBoolean $dbInference.FreshSearchReceiptReady) -or
      $dbInference.Results -isnot [System.Array] -or
      @($dbInference.Results).Count -eq 0
    ) {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "DB_INFERENCE"
        Status = "차단"
        Trace = @($trace)
        BlockedActions = @( "select_cards", "select_all", "next_step" )
      }
    }

    $inferenceClusterIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($resultRow in @($dbInference.Results)) {
      if (
        -not (Test-HasRequiredProperties $resultRow @(
          "ClusterId", "Status", "InferredScope", "InferredCollection", "ScopeType",
          "Confidence", "Reason", "Receipts"
        )) -or
        -not (Test-IsNonblankString $resultRow.ClusterId) -or
        -not $inferenceClusterIds.Add([string]$resultRow.ClusterId) -or
        $resultRow.Status -isnot [string] -or
        $resultRow.Status -cne "inferred" -or
        -not (Test-HasRequiredProperties $resultRow.Receipts @(
          "BlankProbe", "ScopeLock", "ScopedSearch", "ScopeLockReady", "FreshSearchReceiptReady"
        ))
      ) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "DB_INFERENCE"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }
      $candidate = Get-MathSecrStateInferenceCandidate $resultRow
      if (
        $null -eq $candidate -or
        ($candidate.Kind -ceq "scope" -and (
          $resultRow.ScopeType -cne "leaf" -or
          (Test-MathSecrStateCanonicalOfficialCollection $candidate.Value)
        )) -or
        ($candidate.Kind -ceq "collection" -and (
          $resultRow.ScopeType -cne "collection" -or
          -not (Test-MathSecrStateCanonicalOfficialCollection $candidate.Value)
        ))
      ) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "DB_INFERENCE"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }

      $probeDerivedInference = $resultRow.Reason -is [string] -and
        $resultRow.Reason -clike "probe-*"
      if (-not (Test-MathSecrStateBlankProbeReceipt $resultRow.Receipts.BlankProbe $probeDerivedInference)) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "DB_INFERENCE"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }
      $dbInferenceRows += [pscustomobject]@{ Row = $resultRow; Candidate = $candidate }
    }

    if ($dbInferenceRows.Count -eq 1) {
      $topCandidate = Get-MathSecrStateInferenceCandidate $dbInference
      if (
        $null -eq $topCandidate -or
        $topCandidate.Kind -cne $dbInferenceRows[0].Candidate.Kind -or
        -not (Test-MathSecrStateScopeIdentity $topCandidate.Value $dbInferenceRows[0].Candidate.Value)
      ) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "DB_INFERENCE"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }
    } elseif ($null -ne $dbInference.InferredScope -or $null -ne $dbInference.InferredCollection) {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "DB_INFERENCE"
        Status = "차단"
        Trace = @($trace)
        BlockedActions = @( "select_cards", "select_all", "next_step" )
      }
    }
  }

  $trace.Add("SCOPE_LOCK")
  if (-not (Test-IsStrictBoolean $Snapshot.scope.verified) -or -not (Test-IsStrictBoolean $Snapshot.scope.unexpectedBroadResult)) {
    return New-StateResult @{
      Input = $Snapshot
      Derived = $derived
      Phase = $Phase
      State = "SCOPE_LOCK"
      Status = "차단"
      Trace = @($trace)
      BlockedActions = @( "select_cards", "select_all", "next_step" )
    }
  }
  if ($dbInferenceRequired) {
    $allScopeLocksReady = $true
    foreach ($inferenceRow in $dbInferenceRows) {
      $scopeLock = $inferenceRow.Row.Receipts.ScopeLock
      if (
        -not (Test-HasRequiredProperties $scopeLock @(
          "SelectorSearchCleared", "ScopeReceiptVerified", "SelectedScope", "ScopeIdentityMatches"
        )) -or
        -not (Test-IsStrictBoolean $scopeLock.SelectorSearchCleared) -or
        -not (Test-IsStrictBoolean $scopeLock.ScopeReceiptVerified) -or
        -not (Test-IsStrictBoolean $scopeLock.ScopeIdentityMatches) -or
        -not (Test-IsStrictBoolean $inferenceRow.Row.Receipts.ScopeLockReady) -or
        $scopeLock.SelectedScope -isnot [string]
      ) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "SCOPE_LOCK"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }

      $hasSelectedScope = Test-IsNonblankString $scopeLock.SelectedScope
      if (
        ($scopeLock.ScopeReceiptVerified -and -not $hasSelectedScope) -or
        (-not $scopeLock.ScopeReceiptVerified -and $scopeLock.SelectedScope -cne "") -or
        (-not $scopeLock.ScopeReceiptVerified -and $scopeLock.ScopeIdentityMatches)
      ) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "SCOPE_LOCK"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }

      $actualScopeIdentity = $scopeLock.ScopeReceiptVerified -and
        (Test-MathSecrStateScopeIdentity $scopeLock.SelectedScope $inferenceRow.Candidate.Value)
      if ($scopeLock.ScopeIdentityMatches -ne $actualScopeIdentity) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "SCOPE_LOCK"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }
      if ($scopeLock.ScopeReceiptVerified -and -not $actualScopeIdentity) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "SCOPE_LOCK"
          Status = "inferred-scope-identity-mismatch"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }

      $computedScopeLockReady = [bool](
        $scopeLock.SelectorSearchCleared -and
        $scopeLock.ScopeReceiptVerified -and
        $actualScopeIdentity
      )
      if ($inferenceRow.Row.Receipts.ScopeLockReady -ne $computedScopeLockReady) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "SCOPE_LOCK"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }
      if (-not $computedScopeLockReady) {
        $allScopeLocksReady = $false
      }
    }
    if ($dbInference.ScopeLockReady -ne $allScopeLocksReady) {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "SCOPE_LOCK"
        Status = "차단"
        Trace = @($trace)
        BlockedActions = @( "select_cards", "select_all", "next_step" )
      }
    }
    if (-not $allScopeLocksReady) {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "SCOPE_LOCK"
        Status = "inferred-scope-verification-required"
        Trace = @($trace)
        BlockedActions = @( "select_cards", "select_all", "next_step" )
      }
    }
  }
  if (-not $Snapshot.scope.verified -or $Snapshot.scope.unexpectedBroadResult) {
    return New-StateResult @{
      Input = $Snapshot
      Derived = $derived
      Phase = $Phase
      State = "SCOPE_LOCK"
      Status = "scope-recovery-required"
      Trace = @($trace)
      BlockedActions = @( "select_cards", "select_all", "next_step" )
    }
  }

  $trace.Add("INITIAL_SEARCH")
  if ($dbInferenceRequired) {
    $allFreshSearchReceiptsReady = $true
    foreach ($inferenceRow in $dbInferenceRows) {
      $scopedSearch = $inferenceRow.Row.Receipts.ScopedSearch
      if (
        -not (Test-HasRequiredProperties $scopedSearch @(
          "SelectedScope", "Chips", "Submitted", "FreshResultVerified", "ResultSignature", "ScopeIdentityMatches"
        )) -or
        -not (Test-IsStrictUniqueNonblankStringArray $scopedSearch.Chips 0) -or
        -not (Test-IsStrictBoolean $scopedSearch.Submitted) -or
        -not (Test-IsStrictBoolean $scopedSearch.FreshResultVerified) -or
        -not (Test-IsStrictBoolean $scopedSearch.ScopeIdentityMatches) -or
        -not (Test-IsStrictBoolean $inferenceRow.Row.Receipts.FreshSearchReceiptReady) -or
        $scopedSearch.ResultSignature -isnot [string] -or
        $scopedSearch.SelectedScope -isnot [string]
      ) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "INITIAL_SEARCH"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }

      if (-not $scopedSearch.Submitted) {
        if (
          $scopedSearch.FreshResultVerified -or
          @($scopedSearch.Chips).Count -ne 0 -or
          $scopedSearch.ResultSignature -cne "" -or
          $scopedSearch.SelectedScope -cne "" -or
          $scopedSearch.ScopeIdentityMatches -or
          $inferenceRow.Row.Receipts.FreshSearchReceiptReady
        ) {
          return New-StateResult @{
            Input = $Snapshot
            Derived = $derived
            Phase = $Phase
            State = "INITIAL_SEARCH"
            Status = "차단"
            Trace = @($trace)
            BlockedActions = @( "select_cards", "select_all", "next_step" )
          }
        }
        $allFreshSearchReceiptsReady = $false
        continue
      }

      if (
        -not (Test-IsStrictUniqueNonblankStringArray $scopedSearch.Chips 2) -or
        -not (Test-IsNonblankString $scopedSearch.ResultSignature) -or
        -not (Test-IsNonblankString $scopedSearch.SelectedScope)
      ) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "INITIAL_SEARCH"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }

      $actualScopedIdentity = Test-MathSecrStateScopeIdentity $scopedSearch.SelectedScope $inferenceRow.Candidate.Value
      if ($scopedSearch.ScopeIdentityMatches -ne $actualScopedIdentity) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "INITIAL_SEARCH"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }
      if (-not $actualScopedIdentity) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "INITIAL_SEARCH"
          Status = "search-scope-identity-mismatch"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }

      $computedFreshSearchReady = [bool]($scopedSearch.FreshResultVerified -and $actualScopedIdentity)
      if ($inferenceRow.Row.Receipts.FreshSearchReceiptReady -ne $computedFreshSearchReady) {
        return New-StateResult @{
          Input = $Snapshot
          Derived = $derived
          Phase = $Phase
          State = "INITIAL_SEARCH"
          Status = "차단"
          Trace = @($trace)
          BlockedActions = @( "select_cards", "select_all", "next_step" )
        }
      }
      if (-not $computedFreshSearchReady) {
        $allFreshSearchReceiptsReady = $false
      }
    }
    if ($dbInference.FreshSearchReceiptReady -ne $allFreshSearchReceiptsReady) {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "INITIAL_SEARCH"
        Status = "차단"
        Trace = @($trace)
        BlockedActions = @( "select_cards", "select_all", "next_step" )
      }
    }
    if (-not $allFreshSearchReceiptsReady) {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "INITIAL_SEARCH"
        Status = "search-receipt-required"
        Trace = @($trace)
        BlockedActions = @( "select_cards", "select_all", "next_step" )
      }
    }
  }
  if ($Snapshot.targets -isnot [System.Array] -or @($Snapshot.targets).Count -eq 0) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "INITIAL_SEARCH"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
  }

  $resolutions = @()
  $expectedSelectedIds = [System.Collections.Generic.List[string]]::new()
  $expectedSelectedOccurrenceKeys = [System.Collections.Generic.List[string]]::new()
  $selectedOccurrenceKeyProvided = [System.Collections.Generic.List[bool]]::new()
  $occurrenceKeySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $targetNumbers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $metadataRescuePreflightInvalid = $false
  foreach ($target in @($Snapshot.targets)) {
    if ($target -isnot [pscustomobject] -or $null -eq $target.PSObject.Properties['number']) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "INITIAL_SEARCH"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
    }
    $targetNumber = [string]$target.number
    if ([string]::IsNullOrWhiteSpace($targetNumber) -or -not $targetNumbers.Add($targetNumber)) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "INITIAL_SEARCH"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
    }

    $occurrenceKeyProperty = $target.PSObject.Properties['occurrenceKey']
    $hasOccurrenceKey = $null -ne $occurrenceKeyProperty
    $occurrenceKey = if ($hasOccurrenceKey) { $occurrenceKeyProperty.Value } else { $targetNumber }
    if (
      -not (Test-IsCanonicalOccurrenceKey $occurrenceKey) -or
      -not $occurrenceKeySet.Add([string]$occurrenceKey)
    ) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "INITIAL_SEARCH"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
    }
    $rowState = Test-MathSecrTargetRowState $target
    if (-not $rowState.Valid) {
      if ($rowState.Resolution -ceq 'metadata_anomaly' -and @($rowState.Errors) -ccontains 'unselected-row-carries-selected-id') {
        $trace.Add('CANDIDATE_RECOVERY')
        $trace.Add('METADATA_RESCUE')
        return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'METADATA_RESCUE'; Status = 'metadata-rescue-receipt-invalid'; Trace = @($trace); EvidenceErrors = @($rowState.Errors); BlockedActions = @() }
      }
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'INITIAL_SEARCH'; Status = '차단'; Trace = @($trace); EvidenceErrors = @($rowState.Errors); BlockedActions = @('next_step') }
    }
    $resolution = $rowState.Resolution
    $resolutions += [pscustomobject]@{ Target = $target; Resolution = $resolution }
    $unresolvedReason = switch ($resolution) {
      'not_started' { 'not-started' }
      'candidate_pending' { 'candidate-recovery-pending' }
      'metadata_pending' { 'metadata-rescue-required' }
      'metadata_anomaly' { 'source-anomaly-pending' }
      'whole_pending' { 'whole-db-retry-required' }
      'missed' { 'miss-closure-pending' }
      default { 'selection-evidence-required' }
    }
    Set-MathSecrStateUnresolvedReason $derived $target $unresolvedReason
    if ($resolution -ceq 'not_started' -and @(
      'candidateRecovery', 'wholeDb', 'searchAttemptReceipt', 'metadataRescue', 'bodyComparisonReceipt' |
        Where-Object { $null -ne $target.PSObject.Properties[$_] }
    ).Count -gt 0) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'INITIAL_SEARCH'; Status = '차단'; Trace = @($trace); EvidenceErrors = @('not-started-row-carries-execution-evidence'); BlockedActions = @('next_step') }
    }
    # An unresolved row may retain a raw search packet, but another target's
    # binding can never be treated as ordinary pending work.
    $searchProperty = $target.PSObject.Properties['searchAttemptReceipt']
    if ($null -ne $searchProperty -and $resolution -notlike '*selected') {
      $binding = Get-MathSecrStatePropertyValue $searchProperty.Value 'targetBinding'
      if (-not (Test-MathSecrSearchRequiredProperties $binding @('sourceProblemNumber', 'occurrenceKey')) -or
          $binding.sourceProblemNumber -isnot [string] -or $binding.sourceProblemNumber -cne $targetNumber -or
          -not (Test-IsCanonicalOccurrenceKey $binding.occurrenceKey) -or $binding.occurrenceKey -cne $occurrenceKey) {
        return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'CANDIDATE_RECOVERY'; Status = '차단'; Trace = @($trace); EvidenceErrors = @('search-target-binding'); BlockedActions = @('next_step') }
      }
    }
    if ($resolution -like "*selected") {
      $selectedIdProperty = $target.PSObject.Properties['selectedId']
      if ($resolution -eq "metadata_selected") {
        $metadataPreview = Test-MathSecrMetadataRescueReceipt $target $false $ProjectRoot -Context $Context
        if (-not $metadataPreview.Valid) {
          # Defer the result to the metadata gate below so malformed metadata
          # receipts report the dedicated contract status even when the
          # selectedId is absent or unsafe.
          $metadataRescuePreflightInvalid = $true
          continue
        }
      }
      if ($null -eq $selectedIdProperty -or -not (Test-IsCanonicalId $selectedIdProperty.Value)) {
        return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "INITIAL_SEARCH"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
      }
      $expectedSelectedIds.Add([string]$selectedIdProperty.Value)
      $expectedSelectedOccurrenceKeys.Add([string]$occurrenceKey)
      $selectedOccurrenceKeyProvided.Add($hasOccurrenceKey)
    }
  }

  # A selected snapshot either carries no occurrence bundles at all (the
  # ordinary ID-only path), or carries all three strict canonical bundles in
  # exactly the selected source-target order. This applies even when selected
  # IDs are unique; partial, ghost, reordered, scalar, or noncanonical bundles
  # are never accepted.
  $edit = Get-MathSecrStatePropertyValue $Snapshot 'edit'
  $persistence = Get-MathSecrStatePropertyValue $Snapshot 'persistence'
  $appendProperty=$Snapshot.PSObject.Properties['editAppendReceipt']
  $selectionBundleProperty='selectionBeforeNextOccurrenceKeys'
  $selectedIdsForGate=$Snapshot.selectionBeforeNextIds
  if ($null -ne $appendProperty) {
    if ($Phase -cne 'AfterReload' -or $AppendDepth -lt 0) {
      return New-StateResult @{Input=$Snapshot;Derived=$derived;Phase=$Phase;State='EDIT_APPEND_VERIFY';Status='차단';Trace=@($trace);EvidenceErrors=@('edit-append-after-reload-only');BlockedActions=@('next_step')}
    }
    $trace.Add('EDIT_APPEND_VERIFY')
    $append=Test-MathSecrEditAppendReceipt $Snapshot $expectedSelectedIds $expectedSelectedOccurrenceKeys $ProjectRoot $AppendDepth -Context $Context
    if (-not $append.Valid) {
      return New-StateResult @{Input=$Snapshot;Derived=$derived;Phase=$Phase;State='EDIT_APPEND_VERIFY';Status='차단';Trace=@($trace);EvidenceErrors=@($append.Errors);BlockedActions=@('next_step')}
    }
    $selectedIdsForGate=@($append.SelectedIds)
    $selectionBundleProperty='selectionAfterAppendOccurrenceKeys'
    $derived | Add-Member -NotePropertyName AppendSelectedIds -NotePropertyValue @($append.SelectedIds)
    $derived | Add-Member -NotePropertyName AppendSelectedOccurrenceKeys -NotePropertyValue @(Get-MathSecrStateOptionalStringArray $Snapshot $selectionBundleProperty)
  } elseif ($null -ne $Snapshot.PSObject.Properties['selectionAfterAppendOccurrenceKeys']) {
    return New-StateResult @{Input=$Snapshot;Derived=$derived;Phase=$Phase;State='EDIT_APPEND_VERIFY';Status='차단';Trace=@($trace);EvidenceErrors=@('edit-append-ghost-occurrence-bundle');BlockedActions=@('next_step')}
  }
  $allOccurrenceBundlesAbsentOrEmpty =
    (Test-MathSecrStateOccurrenceBundleAbsentOrEmpty $Snapshot $selectionBundleProperty) -and
    (Test-MathSecrStateOccurrenceBundleAbsentOrEmpty $edit "draftOccurrenceKeys") -and
    (Test-MathSecrStateOccurrenceBundleAbsentOrEmpty $persistence "occurrenceKeys")
  $allOccurrenceBundlesMatchExpected =
    (Test-MathSecrStateOccurrenceBundleMatches $Snapshot $selectionBundleProperty $expectedSelectedOccurrenceKeys)
  if ($Phase -ceq 'AfterReload') {
    $allOccurrenceBundlesMatchExpected = $allOccurrenceBundlesMatchExpected -and
      (Test-MathSecrStateOccurrenceBundleMatches $edit "draftOccurrenceKeys" $expectedSelectedOccurrenceKeys) -and
      (Test-MathSecrStateOccurrenceBundleMatches $persistence "occurrenceKeys" $expectedSelectedOccurrenceKeys)
  } else {
    $allOccurrenceBundlesMatchExpected = $allOccurrenceBundlesMatchExpected -and
      (Test-MathSecrStateOccurrenceBundleAbsentOrEmpty $edit "draftOccurrenceKeys") -and
      (Test-MathSecrStateOccurrenceBundleAbsentOrEmpty $persistence "occurrenceKeys")
  }
  if (
    $expectedSelectedIds.Count -gt 0 -and
    -not $allOccurrenceBundlesAbsentOrEmpty -and
    -not $allOccurrenceBundlesMatchExpected
  ) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "INITIAL_SEARCH"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
  }

  $duplicateSelectedIds = Test-HasDuplicateIds $expectedSelectedIds
  if ($duplicateSelectedIds) {
    $selectedIdCounts = [System.Collections.Generic.Dictionary[string,int]]::new([System.StringComparer]::Ordinal)
    foreach ($selectedId in $expectedSelectedIds) {
      if (-not $selectedIdCounts.ContainsKey($selectedId)) {
        $selectedIdCounts[$selectedId] = 0
      }
      $selectedIdCounts[$selectedId]++
    }
    for ($index = 0; $index -lt $expectedSelectedIds.Count; $index++) {
      $selectedId = $expectedSelectedIds[$index]
      if ($selectedIdCounts[$selectedId] -gt 1 -and -not $selectedOccurrenceKeyProvided[$index]) {
        return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "INITIAL_SEARCH"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
      }
    }
    if (-not (Test-MathSecrStateDuplicateOccurrenceProof $Snapshot $expectedSelectedOccurrenceKeys $Phase -SelectedOccurrenceKeys (Get-MathSecrStateOptionalStringArray $Snapshot $selectionBundleProperty))) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "INITIAL_SEARCH"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
    }
  }

  if ($metadataRescuePreflightInvalid) {
    $trace.Add('CANDIDATE_RECOVERY')
    $trace.Add('METADATA_RESCUE')
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'METADATA_RESCUE'; Status = 'metadata-rescue-receipt-invalid'; Trace = @($trace); BlockedActions = @() }
  }

  # Validate every selected receipt before unresolved rows can return early.
  # Metadata early exact uses its validated bucket without miss closure.
  $selectionEvidence = $derived.SelectionEvidence
  foreach ($selectedRow in @($resolutions | Where-Object { $_.Resolution -like '*selected' })) {
    $bodyProperty = $selectedRow.Target.PSObject.Properties['bodyComparisonReceipt']
    if ($null -eq $bodyProperty -or $bodyProperty.Value -isnot [pscustomobject]) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'INITIAL_SEARCH'; Status = 'body-comparison-receipt-invalid'; Trace = @($trace); EvidenceErrors = @('body-receipt-required'); BlockedActions = @('select_cards', 'select_all', 'next_step') }
    }
    $selectedSearch = Test-MathSecrSelectedSearchReceipt $selectedRow.Target $selectedRow.Resolution
    if (-not $selectedSearch.Valid) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'INITIAL_SEARCH'; Status = 'selected-search-receipt-invalid'; Trace = @($trace); BlockedActions = @('select_cards', 'select_all', 'next_step') }
    }
    $bodyComparison = Test-MathSecrBodyComparisonReceipt -Receipt $bodyProperty.Value -Target $selectedRow.Target `
      -ProjectRoot $ProjectRoot -InspectedIds $selectedSearch.InspectedIds -AttemptId $selectedSearch.AttemptId -Context $Context
    if (-not $bodyComparison.Valid) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'INITIAL_SEARCH'; Status = 'body-comparison-receipt-invalid'; Trace = @($trace); EvidenceErrors = $bodyComparison.Errors; BlockedActions = @('select_cards', 'select_all', 'next_step') }
    }
    $selectionEvidence.Add([pscustomobject]@{
      SourceProblemNumber = [string]$selectedRow.Target.number
      OccurrenceKey = $bodyProperty.Value.occurrenceKey
      CandidateId = $bodyProperty.Value.candidateId
      PolicyVersion = $bodyProperty.Value.policyVersion
      SourceRenderSha256 = $bodyProperty.Value.sourceRenderSha256
      CandidateRenderSha256 = $bodyProperty.Value.candidateRenderSha256
      SearchObservation = $selectedSearch.Projection
    })
    $derived.SelectedSourceNumbers.Add([string]$selectedRow.Target.number)
    Set-MathSecrStateUnresolvedReason $derived $selectedRow.Target ''
  }

  $partialSaveEligible = $partialSaveRequested -and $expectedSelectedIds.Count -gt 0 -and
    $selectionEvidence.Count -eq $expectedSelectedIds.Count

  $candidateWork = @($resolutions | Where-Object { $_.Resolution -ne "initial_selected" })
  if ($candidateWork.Count -gt 0) {
    $trace.Add("CANDIDATE_RECOVERY")
    if (-not $partialSaveEligible -and @($candidateWork | Where-Object { $_.Resolution -in @('candidate_pending', 'not_started') }).Count -gt 0) {
      if (-not (Test-IsStrictBoolean $Snapshot.nextClicked) -or $Snapshot.nextClicked) {
        return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "CANDIDATE_RECOVERY"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
      }
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "CANDIDATE_RECOVERY"; Status = "candidate-recovery-required"; Trace = @($trace); BlockedActions = @() }
    }
  }

  # Printed metadata is an evidence-backed rescue route for misses.  It is
  # deliberately opt-in so existing ID-only snapshots remain compatible, but
  # once a target carries any printed metadata marker the rescue receipt is a
  # mandatory gate before whole-DB retry or final miss reporting.
  $metadataRescueInvalid = $metadataRescuePreflightInvalid
  $metadataRescueTraceAdded = $false
  foreach ($resolutionRow in @($resolutions)) {
    $target = $resolutionRow.Target
    $candidateRecoveryProperty = $target.PSObject.Properties['candidateRecovery']
    $candidateRecovery = if ($null -ne $candidateRecoveryProperty) { $candidateRecoveryProperty.Value } else { $null }
    if ($candidateRecovery -cne "missed") {
      continue
    }

    $printedMetadataPropertyNames = @("printedSourceFamily", "printedSubject", "printedYear")
    $printedMetadataPresent = @($printedMetadataPropertyNames | Where-Object { $null -ne $target.PSObject.Properties[$_] }).Count -gt 0
    if (-not $printedMetadataPresent) {
      continue
    }

    if (-not $metadataRescueTraceAdded) {
      $trace.Add("METADATA_RESCUE")
      $metadataRescueTraceAdded = $true
    }
    $metadataReceiptProperty = $target.PSObject.Properties['metadataRescue']
    if ($null -eq $metadataReceiptProperty) {
      if ($partialSaveEligible) { continue }
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "METADATA_RESCUE"; Status = "metadata-rescue-required"; Trace = @($trace); BlockedActions = @() }
    }
    $metadataReceipt = $metadataReceiptProperty.Value
    $metadataStatusProperty = if ($metadataReceipt -is [pscustomobject]) { $metadataReceipt.PSObject.Properties['status'] } else { $null }
    $requireCompleteCoverage = $null -ne $metadataStatusProperty -and $metadataStatusProperty.Value -in @( "missed", "source_anomaly" )
    $metadataValidation = Test-MathSecrMetadataRescueReceipt $target $requireCompleteCoverage $ProjectRoot -Context $Context
    if (-not $metadataValidation.Valid) {
      $metadataRescueInvalid = $true
    }
  }
  if ($metadataRescueInvalid) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "METADATA_RESCUE"; Status = "metadata-rescue-receipt-invalid"; Trace = @($trace); BlockedActions = @() }
  }

  # A valid source-anomaly receipt proves only that the unresolved comparison
  # is bound to current artifacts, target occurrence, and an inspected
  # candidate. It does not turn that unresolved row into a miss or selection.
  # An explicit partial save may advance only the
  # separately validated selected subset while preserving this diagnosis.
  if (-not $partialSaveEligible -and @($resolutions | Where-Object { $_.Resolution -ceq "metadata_anomaly" }).Count -gt 0) {
    return New-StateResult @{
      Input = $Snapshot
      Derived = $derived
      Phase = $Phase
      State = "METADATA_RESCUE"
      Status = "source-anomaly-pending"
      Trace = @($trace)
      BlockedActions = @( "select_cards", "select_all", "next_step" )
    }
  }

  $wholeDbWork = @($resolutions | Where-Object { $_.Resolution -in @( "whole_selected", "whole_pending", "missed" ) })
  if ($wholeDbWork.Count -gt 0) {
    $trace.Add("WHOLE_DB_RETRY")
    if (-not $partialSaveEligible -and @($wholeDbWork | Where-Object { $_.Resolution -eq "whole_pending" }).Count -gt 0) {
      if (-not (Test-IsStrictBoolean $Snapshot.nextClicked) -or $Snapshot.nextClicked) {
        return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "WHOLE_DB_RETRY"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
      }
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "WHOLE_DB_RETRY"; Status = "whole-db-retry-required"; Trace = @($trace); BlockedActions = @() }
    }
    $wholeDbScopeProperty = $Snapshot.PSObject.Properties['wholeDbScopeVerified']
    $scopeNeeded = -not $partialSaveEligible -or @($wholeDbWork | Where-Object { $_.Resolution -cne 'whole_pending' }).Count -gt 0
    if ($scopeNeeded -and ($null -eq $wholeDbScopeProperty -or -not (Test-IsStrictBoolean $wholeDbScopeProperty.Value) -or -not $wholeDbScopeProperty.Value)) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "WHOLE_DB_RETRY"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
    }
  }

  # A bounded retry counter and a small result set do not prove absence. Every
  # target that is about to close as `missed` must carry the raw ordered search
  # attempts and recovery coverage; the dedicated validator recomputes all
  # aggregate claims from those receipts.
  foreach ($resolutionRow in @($resolutions | Where-Object { $_.Resolution -ceq "missed" })) {
    $searchAttemptReceiptProperty = $resolutionRow.Target.PSObject.Properties['searchAttemptReceipt']
    if ($null -eq $searchAttemptReceiptProperty -or $searchAttemptReceiptProperty.Value -isnot [pscustomobject]) {
      if ($partialSaveEligible) { continue }
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "CANDIDATE_RECOVERY"
        Status = "candidate-recovery-pending"
        Trace = @($trace)
        BlockedActions = @()
      }
    }
    $searchAttemptValidation = Test-MathSecrSearchAttemptContract $searchAttemptReceiptProperty.Value
    $targetNumber = [string]$resolutionRow.Target.number
    $occurrenceKeyProperty = $resolutionRow.Target.PSObject.Properties['occurrenceKey']
    $expectedOccurrenceKey = if ($null -ne $occurrenceKeyProperty) {
      [string]$occurrenceKeyProperty.Value
    } else {
      $targetNumber
    }
    if (
      $null -eq $searchAttemptValidation.TargetBinding -or
      -not [string]::Equals(
        [string]$searchAttemptValidation.TargetBinding.SourceProblemNumber,
        $targetNumber,
        [System.StringComparison]::Ordinal
      ) -or
      -not [string]::Equals(
        [string]$searchAttemptValidation.TargetBinding.OccurrenceKey,
        $expectedOccurrenceKey,
        [System.StringComparison]::Ordinal
      )
    ) {
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "CANDIDATE_RECOVERY"
        Status = "차단"
        Trace = @($trace)
        BlockedActions = @()
      }
    }
    if (-not $searchAttemptValidation.CanCloseMiss) {
      Set-MathSecrStateUnresolvedReason $derived $resolutionRow.Target $searchAttemptValidation.Status
      if ($partialSaveEligible) { continue }
      return New-StateResult @{
        Input = $Snapshot
        Derived = $derived
        Phase = $Phase
        State = "CANDIDATE_RECOVERY"
        Status = $searchAttemptValidation.Status
        Trace = @($trace)
        BlockedActions = @()
      }
    }
    $derived.ClosedMissedSourceNumbers.Add([string]$resolutionRow.Target.number)
    Set-MathSecrStateUnresolvedReason $derived $resolutionRow.Target ''
  }

  if ($expectedSelectedIds.Count -eq 0) {
    $zeroSelectionStateIsClean =
      (Test-IsStrictIdArray $Snapshot.selectionBeforeNextIds) -and
      @($Snapshot.selectionBeforeNextIds).Count -eq 0 -and
      (Test-IsStrictBoolean $Snapshot.nextClicked) -and
      -not $Snapshot.nextClicked -and
      $derived.UnresolvedReasons.Count -eq 0 -and
      $allOccurrenceBundlesAbsentOrEmpty
    if ($Phase -ceq 'BeforeNext') {
      $zeroSelectionStateIsClean = $zeroSelectionStateIsClean -and (Test-MathSecrBeforeNextUnusedPackets $Snapshot)
    } else {
      $zeroSelectionStateIsClean = $zeroSelectionStateIsClean -and
        (Test-HasRequiredProperties $edit @('draftIds', 'oldIds', 'recovery')) -and
        (Test-HasRequiredProperties $persistence @('ids', 'freshReloadVerified')) -and
        (Test-IsStrictIdArray $edit.draftIds) -and @($edit.draftIds).Count -eq 0 -and
        (Test-IsStrictIdArray $edit.oldIds) -and @($edit.oldIds).Count -eq 0 -and $edit.recovery -ceq 'not_needed' -and
        (Test-IsStrictIdArray $persistence.ids) -and @($persistence.ids).Count -eq 0 -and
        (Test-IsStrictBoolean $persistence.freshReloadVerified) -and -not $persistence.freshReloadVerified
    }
    if (-not $zeroSelectionStateIsClean) {
      $trace.Add("PRE_NEXT_GATE")
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "PRE_NEXT_GATE"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
    }
    $trace.Add("REPORT")
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "REPORT"; Status = "검색 완료/0선택"; Trace = @($trace); BlockedActions = @() }
  }

  $trace.Add("PRE_NEXT_GATE")
  $selectionOccurrenceKeys = Get-MathSecrStateOptionalStringArray $Snapshot $selectionBundleProperty
  if (
    -not (Test-IsStrictIdArray $selectedIdsForGate) -or
    -not (Test-IsStrictBoolean $Snapshot.nextClicked) -or
    (-not $duplicateSelectedIds -and (Test-HasDuplicateIds $selectedIdsForGate)) -or
    -not (Test-OrderedIdsEqual $expectedSelectedIds $selectedIdsForGate) -or
    ($duplicateSelectedIds -and (-not (Test-IsStrictUniqueOccurrenceKeyArray $selectionOccurrenceKeys) -or -not (Test-OrderedIdsEqual $expectedSelectedOccurrenceKeys $selectionOccurrenceKeys))) -or
    ($Phase -ceq 'AfterReload' -and -not $Snapshot.nextClicked) -or
    ($Phase -ceq 'BeforeNext' -and $Snapshot.nextClicked)
  ) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "PRE_NEXT_GATE"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
  }

  if ($Phase -ceq 'BeforeNext') {
    if (-not (Test-MathSecrBeforeNextUnusedPackets $Snapshot)) {
      return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'PRE_NEXT_GATE'; Status = '차단'; Trace = @($trace); EvidenceErrors = @('before-next-edit-reentry-unsupported'); BlockedActions = @('next_step') }
    }
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = 'PRE_NEXT_GATE'; Status = 'ready-for-next'; Trace = @($trace); CanNextStep = $true; BlockedActions = @() }
  }

  $trace.Add("EDIT_VERIFY")
  $draftOccurrenceKeys = Get-MathSecrStateOptionalStringArray $edit "draftOccurrenceKeys"
  if (
    -not (Test-HasRequiredProperties $edit @('draftIds', 'oldIds', 'recovery')) -or
    -not (Test-IsStrictIdArray $Snapshot.edit.draftIds) -or
    -not (Test-IsStrictIdArray $Snapshot.edit.oldIds) -or
    (-not $duplicateSelectedIds -and (Test-HasDuplicateIds $Snapshot.edit.draftIds)) -or
    @($Snapshot.edit.oldIds).Count -gt 0 -or
    $Snapshot.edit.recovery -notin @( "not_needed", "recovered", "succeeded" ) -or
    -not (Test-OrderedIdsEqual $expectedSelectedIds $Snapshot.edit.draftIds) -or
    ($duplicateSelectedIds -and (-not (Test-IsStrictUniqueOccurrenceKeyArray $draftOccurrenceKeys) -or -not (Test-OrderedIdsEqual $expectedSelectedOccurrenceKeys $draftOccurrenceKeys)))
  ) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "EDIT_VERIFY"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
  }

  $trace.Add("PERSIST_VERIFY")
  $persistedOccurrenceKeys = Get-MathSecrStateOptionalStringArray $persistence "occurrenceKeys"
  if (
    -not (Test-HasRequiredProperties $persistence @('ids', 'freshReloadVerified')) -or
    -not (Test-IsStrictIdArray $Snapshot.persistence.ids) -or
    -not (Test-IsStrictBoolean $Snapshot.persistence.freshReloadVerified) -or
    (-not $duplicateSelectedIds -and (Test-HasDuplicateIds $Snapshot.persistence.ids)) -or
    -not $Snapshot.persistence.freshReloadVerified -or
    -not (Test-OrderedIdsEqual $expectedSelectedIds $Snapshot.persistence.ids) -or
    ($duplicateSelectedIds -and (-not (Test-IsStrictUniqueOccurrenceKeyArray $persistedOccurrenceKeys) -or -not (Test-OrderedIdsEqual $expectedSelectedOccurrenceKeys $persistedOccurrenceKeys)))
  ) {
    return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "PERSIST_VERIFY"; Status = "차단"; Trace = @($trace); BlockedActions = @() }
  }

  $trace.Add("REPORT")
  $status = if ($expectedSelectedIds.Count -eq @($Snapshot.targets).Count) { "완료" } else { "부분 완료" }
  return New-StateResult @{ Input = $Snapshot; Derived = $derived; Phase = $Phase; State = "REPORT"; Status = $status; Trace = @($trace); SelectionEvidence = @($selectionEvidence); BlockedActions = @() }
  } finally { Exit-MathSecrValidationContext -Context $Context }
}
