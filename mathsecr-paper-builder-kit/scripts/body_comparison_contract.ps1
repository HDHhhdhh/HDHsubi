# Loaded by state_machine.ps1; reuse its canonical identity and artifact helpers.
# Receipt integrity is not an independent mathematical or visual oracle.
function Test-MathSecrSelectedSearchReceipt {
  param($Target, [string]$Resolution)
  $invalid = [pscustomobject]@{ Valid = $false; AttemptId = ''; InspectedIds = @(); Projection = $null }
  $bodyProperty = $Target.PSObject.Properties['bodyComparisonReceipt']
  if ($null -eq $bodyProperty -or
      -not (Test-MathSecrSearchRequiredProperties $bodyProperty.Value @('searchAttemptId'))) { return $invalid }
  $attemptId = $bodyProperty.Value.searchAttemptId
  if (-not (Test-IsCanonicalId $attemptId)) { return $invalid }
  $keyProperty = $Target.PSObject.Properties['occurrenceKey']
  $key = if ($null -ne $keyProperty) { $keyProperty.Value } else { [string]$Target.number }
  $observationReceipt = $null
  $inspectedIds = @()
  if ($Resolution -ceq 'metadata_selected') {
    if ($attemptId -cne 'metadata-rescue') { return $invalid }
    foreach ($bucket in @($Target.metadataRescue.buckets)) {
      if (@($bucket.inspectedIds) -ccontains $Target.selectedId) {
        $observationProperty = $bucket.PSObject.Properties['observationReceipt']
        if ($null -eq $observationProperty) { continue }
        $observation = Test-MathSecrSearchObservation -Packet $observationProperty.Value `
          -AttemptId $attemptId -Chips @($Target.metadataRescue.textChips) -ResultCount $bucket.resultCount
        if ($observation.FreshResultVerified -and
            @($observationProperty.Value.submission.criteria.chips | Where-Object { $_.kind -cne 'text' }).Count -eq 0) {
          $observationReceipt = $observationProperty.Value
          $inspectedIds = @($bucket.inspectedIds)
          break
        }
      }
    }
  } else {
    $searchProperty = $Target.PSObject.Properties['searchAttemptReceipt']
    if ($null -eq $searchProperty -or $searchProperty.Value -isnot [pscustomobject]) { return $invalid }
    $packet = $searchProperty.Value
    $search = Test-MathSecrSearchAttemptContract $packet
    if ($search.Status -cne 'exact-found' -or $null -eq $search.TargetBinding -or
        $search.TargetBinding.SourceProblemNumber -cne [string]$Target.number -or
        $search.TargetBinding.OccurrenceKey -cne $key -or
        @($search.ExactMatchIds) -cnotcontains $Target.selectedId) { return $invalid }
    $attempts = @($packet.attempts | Where-Object { $_.attemptId -ceq $attemptId })
    if ($attempts.Count -ne 1) { return $invalid }
    $attempt = $attempts[0]
    $expectedScope = switch ($Resolution) {
      'initial_selected' { 'initial-scope' }; 'candidate_selected' { 'candidate-recovery' }; 'whole_selected' { 'whole-db' }
    }
    if (-not $attempt.exactFound -or $attempt.scope -cne $expectedScope -or
        -not (Test-MathSecrSearchRequiredProperties $attempt @('inspectedIds', 'exactMatchIds', 'observationReceipt')) -or
        @($attempt.exactMatchIds) -cnotcontains $Target.selectedId -or
        @($attempt.inspectedIds) -cnotcontains $Target.selectedId) { return $invalid }
    $observation = Test-MathSecrSearchObservation -Packet $attempt.observationReceipt `
      -AttemptId $attemptId -Chips @($attempt.chips | ForEach-Object { $_.value }) -ResultCount $attempt.resultCount
    if (-not $observation.FreshResultVerified) { return $invalid }
    $observationReceipt = $attempt.observationReceipt
    $inspectedIds = @($attempt.inspectedIds)
  }
  if ($null -eq $observationReceipt) { return $invalid }
  # Offline DOM tests exercise collection, but cannot be used as live paper
  # selection receipts. The actual read must remain on a MathSecr paper route.
  $paperUri = $null
  if ($observationReceipt.submission.surface -cne 'aside-repl' -or
      -not [Uri]::TryCreate($observationReceipt.submission.url, [UriKind]::Absolute, [ref]$paperUri) -or
      $paperUri.Scheme -cne 'https' -or
      @('www.mathsecr.com', 'mathsecr.com') -cnotcontains $paperUri.Host -or
      $paperUri.AbsolutePath -cnotmatch '^/mypaper/[^/]+/?$') { return $invalid }
  $visibleIds = @($observation.Projection.OrderedVisibleIds)
  if ($visibleIds -cnotcontains $Target.selectedId) { return $invalid }
  return [pscustomobject]@{ Valid = $true; AttemptId = $attemptId; InspectedIds = $inspectedIds; Projection = $observation.Projection }
}

function Test-MathSecrBodyComparisonReceipt {
  param($Receipt, $Target, [string]$ProjectRoot, [string[]]$InspectedIds, [string]$AttemptId, $Context = $null)
  $contextEntered = $false
  try {

  $errors = [System.Collections.Generic.List[string]]::new()
  if (-not (Test-MathSecrSearchRequiredProperties $Receipt @(
    'sourceProblemNumber', 'occurrenceKey', 'candidateId', 'searchAttemptId',
    'policyVersion', 'verdict', 'sourceRenderArtifact', 'sourceRenderSha256',
    'candidateRenderArtifact', 'candidateRenderSha256', 'sourceRenderScale',
    'candidateRenderScale', 'comparison', 'comparedBy', 'comparedAtUtc', 'unresolvedGlyphs'
  ))) { return [pscustomobject]@{ Valid = $false; Errors = @('body-receipt-required') } }

  $keyProperty = $Target.PSObject.Properties['occurrenceKey']
  $key = if ($null -ne $keyProperty) { $keyProperty.Value } else { [string]$Target.number }
  if (
    $Receipt.sourceProblemNumber -isnot [string] -or $Receipt.sourceProblemNumber -cne [string]$Target.number -or
    -not (Test-IsCanonicalOccurrenceKey $Receipt.occurrenceKey) -or $Receipt.occurrenceKey -cne $key -or
    -not (Test-IsCanonicalId $Receipt.candidateId) -or $Receipt.candidateId -cne $Target.selectedId -or
    @($InspectedIds) -cnotcontains $Receipt.candidateId -or
    -not (Test-IsCanonicalId $Receipt.searchAttemptId) -or $Receipt.searchAttemptId -cne $AttemptId
  ) { $errors.Add('body-target-candidate-attempt-binding') }
  if (
    $Receipt.policyVersion -isnot [string] -or $Receipt.policyVersion -cne 'body-only-v1' -or
    $Receipt.verdict -isnot [string] -or $Receipt.verdict -cne 'exact' -or
    $Receipt.unresolvedGlyphs -isnot [bool] -or $Receipt.unresolvedGlyphs -or
    -not (Test-MathSecrSearchNonblankString $Receipt.comparedBy)
  ) { $errors.Add('body-verdict-policy-or-unresolved') }
  $comparedAt = [DateTimeOffset]::MinValue
  if ($Receipt.comparedAtUtc -isnot [string] -or $Receipt.comparedAtUtc -cnotmatch 'Z$' -or
      -not [DateTimeOffset]::TryParse([string]$Receipt.comparedAtUtc, [ref]$comparedAt)) {
    $errors.Add('body-comparison-time')
  }
  $components = @('bodyText', 'conditions', 'formulas', 'figures', 'pointLabels', 'requiredValue', 'internalStatements')
  if (-not (Test-MathSecrSearchRequiredProperties $Receipt.comparison $components)) {
    $errors.Add('body-component-comparison-required')
  } else {
    foreach ($component in $components) {
      $value = $Receipt.comparison.$component
      if ($value -isnot [string] -or $value -cnotin @('match', 'not-present') -or
          ($component -cin @('bodyText', 'requiredValue') -and $value -cne 'match')) {
        $errors.Add("body-component:$component")
      }
    }
  }

  $source = Resolve-MathSecrStateArtifactPath $ProjectRoot $Receipt.sourceRenderArtifact
  $candidate = Resolve-MathSecrStateArtifactPath $ProjectRoot $Receipt.candidateRenderArtifact
  if ($null -ne $source -or $null -ne $candidate) {
    $Context = Enter-MathSecrValidationContext -Context $Context -ProjectRoot $ProjectRoot
    $contextEntered = $true
  }
  $sourceBindingProperty = $Target.PSObject.Properties['sourceBodyArtifact']
  $sourceBinding = if ($null -ne $sourceBindingProperty) { $sourceBindingProperty.Value } else { $null }
  if (-not (Test-MathSecrSearchRequiredProperties $sourceBinding @('path', 'sha256'))) {
    $errors.Add('body-source-artifact-binding-required')
  } elseif ($sourceBinding.path -isnot [string] -or $sourceBinding.sha256 -isnot [string] -or
      $sourceBinding.path -cne $Receipt.sourceRenderArtifact -or
      -not [string]::Equals($sourceBinding.sha256, [string]$Receipt.sourceRenderSha256, [StringComparison]::OrdinalIgnoreCase)) {
    $errors.Add('body-source-artifact-binding')
  }
  foreach ($side in @('source', 'candidate')) {
    $hash = $Receipt."${side}RenderSha256"
    $path = if ($side -ceq 'source') { $source } else { $candidate }
    $scale = $Receipt."${side}RenderScale"
    if ($null -eq $path -or $hash -isnot [string] -or $hash -cnotmatch '\A[0-9a-fA-F]{64}\z' -or
        -not (Test-IsStrictInteger $scale) -or [int64]$scale -lt 1) {
      $errors.Add("body-artifact-shape:$side")
    } else {
      try {
        [void](Get-MathSecrValidationArtifact -Path $path -ExpectedSha256 $hash -Context $Context)
      } catch {
        if ($_.Exception.Data['MathSecrArtifactError'] -ceq 'hash') { $errors.Add("body-artifact-hash:$side") }
        else { $errors.Add("body-artifact-unreadable:$side") }
      }
    }
  }
  if ($null -ne $source -and $null -ne $candidate -and
      [string]::Equals($source, $candidate, [StringComparison]::OrdinalIgnoreCase)) {
    $errors.Add('body-source-candidate-path-reused')
  }
  return [pscustomobject]@{ Valid = $errors.Count -eq 0; Errors = @($errors) }
  } finally { if ($contextEntered) { Exit-MathSecrValidationContext -Context $Context } }
}
