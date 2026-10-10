Set-StrictMode -Version Latest

function Assert-MathSecrDbInferenceObjectShape {
  param(
    $Value,
    [string[]]$RequiredProperties,
    [string]$Path,
    [string[]]$OptionalProperties = @()
  )

  if ($Value -isnot [pscustomobject]) {
    throw "$Path must be a JSON object."
  }

  $required = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($propertyName in $RequiredProperties) {
    [void]$required.Add($propertyName)
  }
  foreach ($propertyName in $OptionalProperties) {
    [void]$required.Add($propertyName)
  }

  $actual = @($Value.PSObject.Properties.Name)
  foreach ($propertyName in $RequiredProperties) {
    if ($actual -cnotcontains $propertyName) {
      throw "$Path.$propertyName is required."
    }
  }
  foreach ($propertyName in $actual) {
    if (-not $required.Contains($propertyName)) {
      throw "$Path.$propertyName is not allowed."
    }
  }
}

function Assert-MathSecrDbInferenceString {
  param($Value, [string]$Path)

  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
    throw "$Path must be a non-empty string."
  }
}

function Assert-MathSecrDbInferenceBoolean {
  param($Value, [string]$Path)

  if ($Value -isnot [bool]) {
    throw "$Path must be a Boolean."
  }
}

function Assert-MathSecrDbInferenceArray {
  param($Value, [string]$Path, [bool]$AllowEmpty = $true)

  if ($Value -isnot [System.Array]) {
    throw "$Path must be an array."
  }
  if (-not $AllowEmpty -and @($Value).Count -eq 0) {
    throw "$Path must not be empty."
  }
}

function Assert-MathSecrDbInferenceReceiptString {
  param($Value, [string]$Path)

  if ($Value -isnot [string]) {
    throw "$Path must be a string."
  }
}

function Assert-MathSecrDbInferenceSearchPhase {
  param(
    [pscustomobject]$Phase,
    [string]$Path,
    [bool]$IncludeReadOnly,
    [bool]$IncludeSelectedScope
  )

  $requiredProperties = [System.Collections.Generic.List[string]]::new()
  if ($IncludeReadOnly) {
    $requiredProperties.Add("readOnly")
  }
  if ($IncludeSelectedScope) {
    $requiredProperties.Add("selectedScope")
  }
  foreach ($propertyName in @( "chips", "submitted", "freshResultVerified", "resultSignature" )) {
    $requiredProperties.Add($propertyName)
  }
  Assert-MathSecrDbInferenceObjectShape $Phase @($requiredProperties) $Path

  if ($IncludeReadOnly) {
    Assert-MathSecrDbInferenceBoolean $Phase.readOnly "$Path.readOnly"
  }
  if ($IncludeSelectedScope) {
    Assert-MathSecrDbInferenceReceiptString $Phase.selectedScope "$Path.selectedScope"
  }
  Assert-MathSecrDbInferenceArray $Phase.chips "$Path.chips"
  Assert-MathSecrDbInferenceBoolean $Phase.submitted "$Path.submitted"
  Assert-MathSecrDbInferenceBoolean $Phase.freshResultVerified "$Path.freshResultVerified"
  Assert-MathSecrDbInferenceReceiptString $Phase.resultSignature "$Path.resultSignature"

  $normalizedChips = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  for ($chipIndex = 0; $chipIndex -lt @($Phase.chips).Count; $chipIndex++) {
    $chip = @($Phase.chips)[$chipIndex]
    Assert-MathSecrDbInferenceString $chip "$Path.chips[$chipIndex]"
    $normalizedChip = ConvertTo-MathSecrNormalizedChip ([string]$chip)
    if (-not $normalizedChips.Add($normalizedChip)) {
      throw "$Path.chips must be unique after normalization."
    }
  }

  if ($Phase.freshResultVerified -and -not $Phase.submitted) {
    throw "$Path.freshResultVerified requires submitted=true."
  }

  if ($Phase.submitted) {
    if ($normalizedChips.Count -lt 2) {
      throw "$Path.chips must contain at least two unique non-empty strings when submitted=true."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Phase.resultSignature)) {
      throw "$Path.resultSignature must be non-empty when submitted=true."
    }
    if ($IncludeSelectedScope -and [string]::IsNullOrWhiteSpace([string]$Phase.selectedScope)) {
      throw "$Path.selectedScope must be non-empty when submitted=true."
    }
  } else {
    if (@($Phase.chips).Count -ne 0) {
      throw "$Path.chips must be empty when submitted=false."
    }
    if ([string]$Phase.resultSignature -cne "") {
      throw "$Path.resultSignature must be empty when submitted=false."
    }
    if ($IncludeSelectedScope -and [string]$Phase.selectedScope -cne "") {
      throw "$Path.selectedScope must be empty when submitted=false."
    }
  }
}

function ConvertTo-MathSecrNormalizedScope {
  param([string]$Value)

  $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
  $normalized = [regex]::Replace($normalized, '\s+', ' ')
  $normalized = [regex]::Replace($normalized, '\s*>\s*', '>')
  return $normalized.ToLowerInvariant()
}

function ConvertTo-MathSecrNormalizedChip {
  param([string]$Value)

  $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
  $normalized = [regex]::Replace($normalized, '\s+', ' ')
  return $normalized.ToLowerInvariant()
}

function ConvertTo-MathSecrDisplayScope {
  param([string]$Value)

  $display = $Value.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
  return [regex]::Replace($display, '\s+', ' ')
}

function Resolve-MathSecrCanonicalScope {
  param([pscustomobject]$Cluster, [string]$EvidenceScope)

  $mappingProperty = $Cluster.PSObject.Properties["scopeMappings"]
  if ($null -eq $mappingProperty) {
    return ConvertTo-MathSecrDisplayScope $EvidenceScope
  }

  $evidenceKey = ConvertTo-MathSecrNormalizedScope $EvidenceScope
  $match = @($Cluster.scopeMappings | Where-Object {
    (ConvertTo-MathSecrNormalizedScope ([string]$_.evidenceScope)) -ceq $evidenceKey
  })
  if ($match.Count -eq 1) {
    return ConvertTo-MathSecrDisplayScope ([string]$match[0].canonicalScope)
  }
  return ConvertTo-MathSecrDisplayScope $EvidenceScope
}

function ConvertTo-MathSecrProblemKey {
  param([string]$Value)

  $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
  $normalized = [regex]::Replace($normalized, '\s+', ' ')
  if ($normalized -cmatch '^(?:문제\s*)?(\d+)\s*(?:번)?$') {
    $withoutLeadingZeros = $Matches[1].TrimStart('0')
    return $(if ($withoutLeadingZeros.Length -eq 0) { '0' } else { $withoutLeadingZeros })
  }
  return $normalized.ToLowerInvariant()
}

function Test-MathSecrDistinctProblemCount {
  param([object[]]$Rows)

  $problemNumbers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($row in @($Rows)) {
    [void]$problemNumbers.Add((ConvertTo-MathSecrProblemKey ([string]$row.problemNumber)))
  }
  return $problemNumbers.Count
}

function Test-MathSecrDbInferenceFreshSearchPhase {
  param([pscustomobject]$Phase)

  return [bool](
    $Phase.submitted -and
    $Phase.freshResultVerified -and
    @($Phase.chips).Count -ge 2 -and
    -not [string]::IsNullOrWhiteSpace([string]$Phase.resultSignature)
  )
}

function Test-MathSecrDbInferenceScopeIdentity {
  param([string]$Actual, [string]$Expected)

  if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) {
    return $false
  }
  return (ConvertTo-MathSecrNormalizedScope $Actual) -ceq (ConvertTo-MathSecrNormalizedScope $Expected)
}

function New-MathSecrDbInferenceReceiptResult {
  param(
    [pscustomobject]$Receipts,
    $InferredScope,
    $InferredCollection,
    [string]$Status
  )

  $candidateScope = if ($null -ne $InferredScope) { [string]$InferredScope } elseif ($null -ne $InferredCollection) { [string]$InferredCollection } else { $null }
  $scopeIdentityMatches = $Status -ceq "inferred" -and (Test-MathSecrDbInferenceScopeIdentity ([string]$Receipts.scopeLock.selectedScope) $candidateScope)
  $scopeLockReady = [bool](
    $scopeIdentityMatches -and
    $Receipts.scopeLock.selectorSearchCleared -and
    $Receipts.scopeLock.scopeReceiptVerified
  )
  $scopedIdentityMatches = $Status -ceq "inferred" -and (Test-MathSecrDbInferenceScopeIdentity ([string]$Receipts.scopedSearch.selectedScope) $candidateScope)
  $freshSearchReady = [bool](
    $scopeLockReady -and
    $scopedIdentityMatches -and
    (Test-MathSecrDbInferenceFreshSearchPhase $Receipts.scopedSearch)
  )

  return [pscustomobject]@{
    BlankProbe = [pscustomobject]@{
      ReadOnly = $Receipts.blankProbe.readOnly
      Chips = @($Receipts.blankProbe.chips)
      Submitted = $Receipts.blankProbe.submitted
      FreshResultVerified = $Receipts.blankProbe.freshResultVerified
      ResultSignature = $Receipts.blankProbe.resultSignature
      FreshSearchReceiptReady = (Test-MathSecrDbInferenceFreshSearchPhase $Receipts.blankProbe)
    }
    ScopeLock = [pscustomobject]@{
      SelectorSearchCleared = $Receipts.scopeLock.selectorSearchCleared
      ScopeReceiptVerified = $Receipts.scopeLock.scopeReceiptVerified
      SelectedScope = $Receipts.scopeLock.selectedScope
      ScopeIdentityMatches = [bool]$scopeIdentityMatches
    }
    ScopedSearch = [pscustomobject]@{
      SelectedScope = $Receipts.scopedSearch.selectedScope
      Chips = @($Receipts.scopedSearch.chips)
      Submitted = $Receipts.scopedSearch.submitted
      FreshResultVerified = $Receipts.scopedSearch.freshResultVerified
      ResultSignature = $Receipts.scopedSearch.resultSignature
      ScopeIdentityMatches = [bool]$scopedIdentityMatches
    }
    ScopeLockReady = $scopeLockReady
    FreshSearchReceiptReady = $freshSearchReady
  }
}

function New-MathSecrDbInferenceClusterResult {
  param(
    [pscustomobject]$Cluster,
    [string]$Status,
    $InferredScope,
    $InferredCollection,
    $ScopeType,
    [string]$Confidence,
    [string]$Reason
  )

  return [pscustomobject]@{
    ClusterId = $Cluster.clusterId
    Status = $Status
    InferredScope = $InferredScope
    InferredCollection = $InferredCollection
    ScopeType = $ScopeType
    Confidence = $Confidence
    Reason = $Reason
    Receipts = New-MathSecrDbInferenceReceiptResult $Cluster.receipts $InferredScope $InferredCollection $Status
  }
}

function Assert-MathSecrDbInferenceCluster {
  param([pscustomobject]$Cluster, [int]$Index)

  $clusterPath = "input.clusters[$Index]"
  Assert-MathSecrDbInferenceObjectShape $Cluster @(
    "clusterId",
    "collectionComplete",
    "printedMetadata",
    "probeHits",
    "receipts"
  ) $clusterPath @( "scopeMappings" )
  Assert-MathSecrDbInferenceString $Cluster.clusterId "$clusterPath.clusterId"
  Assert-MathSecrDbInferenceBoolean $Cluster.collectionComplete "$clusterPath.collectionComplete"
  Assert-MathSecrDbInferenceArray $Cluster.printedMetadata "$clusterPath.printedMetadata"
  Assert-MathSecrDbInferenceArray $Cluster.probeHits "$clusterPath.probeHits"

  if ($null -ne $Cluster.PSObject.Properties["scopeMappings"]) {
    Assert-MathSecrDbInferenceArray $Cluster.scopeMappings "$clusterPath.scopeMappings"
    $mappingKeys = @{}
    for ($mappingIndex = 0; $mappingIndex -lt @($Cluster.scopeMappings).Count; $mappingIndex++) {
      $mapping = @($Cluster.scopeMappings)[$mappingIndex]
      $mappingPath = "$clusterPath.scopeMappings[$mappingIndex]"
      Assert-MathSecrDbInferenceObjectShape $mapping @( "evidenceScope", "canonicalScope" ) $mappingPath
      Assert-MathSecrDbInferenceString $mapping.evidenceScope "$mappingPath.evidenceScope"
      Assert-MathSecrDbInferenceString $mapping.canonicalScope "$mappingPath.canonicalScope"
      $mappingKey = ConvertTo-MathSecrNormalizedScope ([string]$mapping.evidenceScope)
      $canonicalKey = ConvertTo-MathSecrNormalizedScope ([string]$mapping.canonicalScope)
      if ($mappingKeys.ContainsKey($mappingKey)) {
        throw "$mappingPath.evidenceScope must be unique after normalization."
      }
      $mappingKeys[$mappingKey] = $canonicalKey
    }
  }

  for ($metadataIndex = 0; $metadataIndex -lt @($Cluster.printedMetadata).Count; $metadataIndex++) {
    $metadata = @($Cluster.printedMetadata)[$metadataIndex]
    $metadataPath = "$clusterPath.printedMetadata[$metadataIndex]"
    Assert-MathSecrDbInferenceObjectShape $metadata @(
      "problemNumber",
      "sourceType",
      "scope",
      "scopeKind",
      "exact"
    ) $metadataPath
    Assert-MathSecrDbInferenceString $metadata.problemNumber "$metadataPath.problemNumber"
    Assert-MathSecrDbInferenceString $metadata.sourceType "$metadataPath.sourceType"
    if ($metadata.sourceType -cnotin @( "textbook", "education", "evaluation", "other" )) {
      throw "$metadataPath.sourceType must be textbook, education, evaluation, or other."
    }
    Assert-MathSecrDbInferenceString $metadata.scope "$metadataPath.scope"
    Assert-MathSecrDbInferenceString $metadata.scopeKind "$metadataPath.scopeKind"
    if ($metadata.scopeKind -cnotin @( "leaf", "collection", "folder", "unit" )) {
      throw "$metadataPath.scopeKind must be leaf, collection, folder, or unit."
    }
    Assert-MathSecrDbInferenceBoolean $metadata.exact "$metadataPath.exact"
  }

  for ($probeIndex = 0; $probeIndex -lt @($Cluster.probeHits).Count; $probeIndex++) {
    $probe = @($Cluster.probeHits)[$probeIndex]
    $probePath = "$clusterPath.probeHits[$probeIndex]"
    Assert-MathSecrDbInferenceObjectShape $probe @(
      "problemNumber",
      "bodyExact",
      "readOnly",
      "scope",
      "scopeKind"
    ) $probePath
    Assert-MathSecrDbInferenceString $probe.problemNumber "$probePath.problemNumber"
    Assert-MathSecrDbInferenceBoolean $probe.bodyExact "$probePath.bodyExact"
    Assert-MathSecrDbInferenceBoolean $probe.readOnly "$probePath.readOnly"
    Assert-MathSecrDbInferenceString $probe.scope "$probePath.scope"
    Assert-MathSecrDbInferenceString $probe.scopeKind "$probePath.scopeKind"
    if ($probe.scopeKind -cnotin @( "leaf", "collection", "folder", "unit" )) {
      throw "$probePath.scopeKind must be leaf, collection, folder, or unit."
    }
  }

  Assert-MathSecrDbInferenceObjectShape $Cluster.receipts @(
    "blankProbe",
    "scopeLock",
    "scopedSearch"
  ) "$clusterPath.receipts"

  Assert-MathSecrDbInferenceSearchPhase $Cluster.receipts.blankProbe "$clusterPath.receipts.blankProbe" $true $false

  Assert-MathSecrDbInferenceObjectShape $Cluster.receipts.scopeLock @(
    "selectorSearchCleared",
    "scopeReceiptVerified",
    "selectedScope"
  ) "$clusterPath.receipts.scopeLock"
  Assert-MathSecrDbInferenceBoolean $Cluster.receipts.scopeLock.selectorSearchCleared "$clusterPath.receipts.scopeLock.selectorSearchCleared"
  Assert-MathSecrDbInferenceBoolean $Cluster.receipts.scopeLock.scopeReceiptVerified "$clusterPath.receipts.scopeLock.scopeReceiptVerified"
  Assert-MathSecrDbInferenceReceiptString $Cluster.receipts.scopeLock.selectedScope "$clusterPath.receipts.scopeLock.selectedScope"
  if ($Cluster.receipts.scopeLock.scopeReceiptVerified) {
    if ([string]::IsNullOrWhiteSpace([string]$Cluster.receipts.scopeLock.selectedScope)) {
      throw "$clusterPath.receipts.scopeLock.selectedScope must be non-empty when scopeReceiptVerified=true."
    }
  } elseif ([string]$Cluster.receipts.scopeLock.selectedScope -cne "") {
    throw "$clusterPath.receipts.scopeLock.selectedScope must be empty when scopeReceiptVerified=false."
  }

  Assert-MathSecrDbInferenceSearchPhase $Cluster.receipts.scopedSearch "$clusterPath.receipts.scopedSearch" $false $true
}

function Resolve-MathSecrDbInferenceCluster {
  param([pscustomobject]$Cluster)

  $mutatingProbeHits = @($Cluster.probeHits | Where-Object { -not $_.readOnly })
  $officialCollectionKey = ConvertTo-MathSecrNormalizedScope "교육청, 평가원"

  # A mutating probe row invalidates the whole cluster regardless of whether
  # evidence collection is complete, the blank probe was submitted, or printed
  # metadata would otherwise infer a source.
  if ($mutatingProbeHits.Count -gt 0) {
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "blank-probe-not-read-only"
  }

  # A leaf mapping may only resolve to a canonical selectable leaf. It must not
  # turn leaf evidence into the official collection candidate by relabeling the
  # mapping target as `교육청, 평가원`.
  $scopeMappingProperty = $Cluster.PSObject.Properties["scopeMappings"]
  if ($null -ne $scopeMappingProperty) {
    $scopeMappingToOfficialCollection = @($Cluster.scopeMappings | Where-Object {
      (ConvertTo-MathSecrNormalizedScope ([string]$_.canonicalScope)) -ceq $officialCollectionKey
    })
    if ($scopeMappingToOfficialCollection.Count -gt 0) {
      return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "leaf-scope-mapped-to-official-collection"
    }
  }

  if (-not $Cluster.collectionComplete) {
    return New-MathSecrDbInferenceClusterResult $Cluster "pending" $null $null $null "pending" "evidence-collection-pending"
  }

  $exactPrinted = @($Cluster.printedMetadata | Where-Object { $_.exact })
  $officialPrinted = @($exactPrinted | Where-Object { $_.sourceType -cin @( "education", "evaluation" ) })
  $textbookPrinted = @($exactPrinted | Where-Object { $_.sourceType -ceq "textbook" })
  $otherPrinted = @($exactPrinted | Where-Object { $_.sourceType -ceq "other" })
  $exactProbeHits = @($Cluster.probeHits | Where-Object { $_.bodyExact })

  # Once a blank-source probe was submitted, a false read-only receipt or any
  # mutating row blocks the whole cluster even if all probe hits were non-exact.
  # Direct printed metadata must not bypass this fail-closed boundary.
  if ($Cluster.receipts.blankProbe.submitted -and
      (-not $Cluster.receipts.blankProbe.readOnly -or @($Cluster.probeHits | Where-Object { -not $_.readOnly }).Count -gt 0)) {
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "blank-probe-not-read-only"
  }

  # A probe must remain read-only even when a non-exact row is the one that exposes
  # mutation. This gate intentionally runs before any direct metadata inference.
  if ($exactProbeHits.Count -gt 0) {
    if (-not $Cluster.receipts.blankProbe.readOnly -or @($Cluster.probeHits | Where-Object { -not $_.readOnly }).Count -gt 0) {
      return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "blank-probe-not-read-only"
    }
    if (-not (Test-MathSecrDbInferenceFreshSearchPhase $Cluster.receipts.blankProbe)) {
      return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "probe-search-receipt-required"
    }
  }

  if (@($officialPrinted | Where-Object { $_.scopeKind -cne "collection" }).Count -gt 0) {
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "official-scope-must-be-collection"
  }
  if (@($textbookPrinted | Where-Object { $_.scopeKind -cne "leaf" }).Count -gt 0) {
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "textbook-scope-must-be-leaf"
  }

  if ($otherPrinted.Count -gt 0) {
    $hasConflictingExactEvidence = ($officialPrinted.Count + $textbookPrinted.Count + $exactProbeHits.Count) -gt 0
    $reason = if ($hasConflictingExactEvidence) { "conflicting-exact-source-families" } else { "unsupported-exact-source-family" }
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" $reason
  }

  if ($officialPrinted.Count -gt 0 -and $textbookPrinted.Count -gt 0) {
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "mixed-printed-source-families"
  }

  $probeLeafHits = @($exactProbeHits | Where-Object { $_.scopeKind -ceq "leaf" })
  $probeCollectionHits = @($exactProbeHits | Where-Object { $_.scopeKind -ceq "collection" })
  $probeNonSelectableHits = @($exactProbeHits | Where-Object { $_.scopeKind -cin @( "folder", "unit" ) })
  if ($probeNonSelectableHits.Count -gt 0) {
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "non-leaf-probe-evidence"
  }

  # A metadata-free probe can also identify the canonical official collection.
  # Keep this branch deliberately narrow: all exact probe rows must be official
  # collection rows, they must normalize to the one selectable collection, and
  # three distinct problem numbers are required.  Leaf/collection mixtures and
  # unrecognized collection labels stay unresolved rather than being promoted
  # from a top-card plurality or a partial hit set.
  if ($officialPrinted.Count -eq 0 -and
      $textbookPrinted.Count -eq 0 -and
      $otherPrinted.Count -eq 0 -and
      @($Cluster.printedMetadata).Count -eq 0 -and
      $probeCollectionHits.Count -gt 0) {
    if ($probeLeafHits.Count -gt 0) {
      return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "mixed-leaf-collection-probe-evidence"
    }

    $probeCollectionGroups = @($probeCollectionHits | Group-Object { ConvertTo-MathSecrNormalizedScope ([string]$_.scope) })
    if ($probeCollectionGroups.Count -ne 1) {
      return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "conflicting-probe-collections"
    }

    if (([string]$probeCollectionGroups[0].Name) -cne $officialCollectionKey) {
      return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "unrecognized-probe-collection"
    }

    if ((Test-MathSecrDistinctProblemCount $probeCollectionHits) -ge 3) {
      return New-MathSecrDbInferenceClusterResult $Cluster "inferred" $null "교육청, 평가원" "collection" "high" "probe-three-official-collection-confirmed"
    }
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "probe-confirmation-required"
  }

  # Official collections and textbook leaves are different source families. A
  # body-exact probe is cross-checked even when printed metadata alone repeats.
  if (($officialPrinted.Count -gt 0 -and $probeLeafHits.Count -gt 0) -or
      ($textbookPrinted.Count -gt 0 -and $probeCollectionHits.Count -gt 0)) {
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "conflicting-exact-source-families"
  }

  if ($officialPrinted.Count -gt 0 -and $probeCollectionHits.Count -gt 0) {
    $officialCollectionKey = ConvertTo-MathSecrNormalizedScope "교육청, 평가원"
    if (@($probeCollectionHits | Where-Object { (ConvertTo-MathSecrNormalizedScope ([string]$_.scope)) -cne $officialCollectionKey }).Count -gt 0) {
      return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "conflicting-exact-collections"
    }
  }

  $textbookLeafGroups = @($textbookPrinted | Group-Object { ConvertTo-MathSecrNormalizedScope $_.scope })
  $probeLeafGroups = @($probeLeafHits | Group-Object { ConvertTo-MathSecrNormalizedScope $_.scope })
  $allLeafEvidence = @($textbookPrinted) + @($probeLeafHits)
  $allLeafGroups = @($allLeafEvidence | Group-Object { ConvertTo-MathSecrNormalizedScope $_.scope })
  if ($allLeafGroups.Count -gt 1) {
    $reason = if ($textbookLeafGroups.Count -gt 1 -and $probeLeafGroups.Count -le 1) {
      "conflicting-printed-leaves"
    } elseif ($probeLeafGroups.Count -gt 1 -and $textbookLeafGroups.Count -eq 0) {
      "conflicting-probe-leaves"
    } else {
      "conflicting-printed-probe-leaves"
    }
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" $reason
  }

  if ((Test-MathSecrDistinctProblemCount $officialPrinted) -ge 2) {
    return New-MathSecrDbInferenceClusterResult $Cluster "inferred" $null "교육청, 평가원" "collection" "high" "printed-official-repeat"
  }

  if ($textbookLeafGroups.Count -eq 1) {
    $textbookRows = @($textbookLeafGroups[0].Group)
    if ((Test-MathSecrDistinctProblemCount $textbookRows) -ge 2) {
      $displayScope = Resolve-MathSecrCanonicalScope $Cluster ([string]$textbookRows[0].scope)
      return New-MathSecrDbInferenceClusterResult $Cluster "inferred" $displayScope $null "leaf" "high" "printed-textbook-repeat"
    }
  }

  if ($exactProbeHits.Count -gt 0) {
    if ($probeCollectionHits.Count -gt 0) {
      return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "non-leaf-probe-evidence"
    }
    if ($probeLeafGroups.Count -eq 1) {
      $probeRows = @($probeLeafGroups[0].Group)
      if ((Test-MathSecrDistinctProblemCount $probeRows) -ge 3) {
        $displayScope = Resolve-MathSecrCanonicalScope $Cluster ([string]$probeRows[0].scope)
        return New-MathSecrDbInferenceClusterResult $Cluster "inferred" $displayScope $null "leaf" "high" "probe-three-body-exact-confirmed"
      }
      return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "probe-confirmation-required"
    }
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "non-leaf-probe-evidence"
  }

  if ($exactPrinted.Count -gt 0) {
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "printed-confirmation-required"
  }

  if (@($Cluster.printedMetadata).Count -gt 0 -or @($Cluster.probeHits).Count -gt 0) {
    return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "non-exact-only"
  }

  return New-MathSecrDbInferenceClusterResult $Cluster "unresolved" $null $null $null "none" "missing-evidence"
}

function Invoke-MathSecrDbInference {
  param([Parameter(Mandatory = $true)][pscustomobject]$InputObject)

  Assert-MathSecrDbInferenceObjectShape $InputObject @( "clusters" ) "input"
  Assert-MathSecrDbInferenceArray $InputObject.clusters "input.clusters" $false

  $clusterIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $results = [System.Collections.Generic.List[object]]::new()
  for ($clusterIndex = 0; $clusterIndex -lt @($InputObject.clusters).Count; $clusterIndex++) {
    $cluster = @($InputObject.clusters)[$clusterIndex]
    Assert-MathSecrDbInferenceCluster $cluster $clusterIndex
    if (-not $clusterIds.Add([string]$cluster.clusterId)) {
      throw "input.clusters[$clusterIndex].clusterId must be unique."
    }
    $results.Add((Resolve-MathSecrDbInferenceCluster $cluster))
  }

  $resultArray = @($results)
  $status = if (@($resultArray | Where-Object { $_.Status -ceq "pending" }).Count -gt 0) {
    "pending"
  } elseif (@($resultArray | Where-Object { $_.Status -cne "inferred" }).Count -gt 0) {
    "unresolved"
  } else {
    "inferred"
  }

  $singleResult = if ($resultArray.Count -eq 1) { $resultArray[0] } else { $null }
  $scopeLockReady = ($status -ceq "inferred") -and @($resultArray | Where-Object { -not $_.Receipts.ScopeLockReady }).Count -eq 0
  $freshSearchReceiptReady = $scopeLockReady -and @($resultArray | Where-Object { -not $_.Receipts.FreshSearchReceiptReady }).Count -eq 0
  return [pscustomobject]@{
    Status = $status
    InferredScope = if ($null -ne $singleResult) { $singleResult.InferredScope } else { $null }
    InferredCollection = if ($null -ne $singleResult) { $singleResult.InferredCollection } else { $null }
    Confidence = if ($null -ne $singleResult) { $singleResult.Confidence } else { "mixed" }
    Reason = if ($null -ne $singleResult) { $singleResult.Reason } else { "per-cluster-results" }
    ScopeLockReady = [bool]$scopeLockReady
    FreshSearchReceiptReady = [bool]$freshSearchReceiptReady
    Receipts = if ($null -ne $singleResult) { $singleResult.Receipts } else { $null }
    Results = $resultArray
  }
}
