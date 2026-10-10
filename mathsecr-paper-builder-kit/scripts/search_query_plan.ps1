[CmdletBinding()]
param([string]$InputPath, [string]$OutPath)

# Query preparation validates supplied transcriptions, not PDF truth or live UI state.
# Lexical/provenance policy remains owned by search_attempt_contract.ps1.
. (Join-Path $PSScriptRoot 'search_attempt_contract.ps1')

function Get-MathSecrQueryTextHash {
  param([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($Text)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
  } finally { $sha.Dispose() }
}

function Test-MathSecrQueryObjectShape {
  param($Value, [string[]]$Names)
  if (-not (Test-MathSecrSearchRequiredProperties $Value $Names)) { return $false }
  $actual = @($Value.PSObject.Properties.Name)
  if ($actual.Count -ne $Names.Count) { return $false }
  foreach ($name in $actual) { if ($Names -cnotcontains $name) { return $false } }
  return $true
}

function Get-MathSecrQueryLiteralSpan {
  param([string]$Text, [string]$Value)
  # NFKC only: never remove whitespace, translate symbols, stem, or infer words.
  # A literal stem such as '직선' in '직선과' remains a contiguous source substring.
  $normalizedText = $Text.Normalize([System.Text.NormalizationForm]::FormKC)
  $normalizedValue = $Value.Normalize([System.Text.NormalizationForm]::FormKC)
  $start = $normalizedText.IndexOf($normalizedValue, [System.StringComparison]::Ordinal)
  if ($start -lt 0) { return $null }
  return [pscustomobject][ordered]@{
    normalization = 'NFKC'; offsetUnit = 'utf16-code-unit'
    start = $start; length = $normalizedValue.Length
    text = $normalizedText.Substring($start, $normalizedValue.Length)
  }
}

function New-MathSecrSearchQueryTargetPlan {
  param($InputTarget, [int]$SourceOrder)
  $errors = [System.Collections.Generic.List[string]]::new()
  $chips = [System.Collections.Generic.List[object]]::new()
  $metadata = [System.Collections.Generic.List[object]]::new()
  $binding = $null
  $bodyHash = $null
  $hints = $null
  if (-not (Test-MathSecrQueryObjectShape $InputTarget @(
    'sourceProblemNumber', 'occurrenceKey', 'sourceBodyText', 'proposedChips', 'recoveryHints'
  ))) {
    $errors.Add('target-shape')
  } else {
    if (-not (Test-MathSecrSearchCanonicalToken $InputTarget.sourceProblemNumber) -or
        -not (Test-MathSecrSearchCanonicalToken $InputTarget.occurrenceKey)) {
      $errors.Add('target-binding')
    } else {
      $binding = [pscustomobject][ordered]@{
        sourceProblemNumber = $InputTarget.sourceProblemNumber
        occurrenceKey = $InputTarget.occurrenceKey
      }
    }
    $bodyValid = $InputTarget.sourceBodyText -is [string] -and
      -not [string]::IsNullOrWhiteSpace($InputTarget.sourceBodyText)
    if (-not $bodyValid) { $errors.Add('source-transcription-required') }
    else { $bodyHash = Get-MathSecrQueryTextHash $InputTarget.sourceBodyText }
    if ($InputTarget.proposedChips -isnot [System.Array] -or @($InputTarget.proposedChips).Count -ne 2) {
      $errors.Add('exactly-two-proposed-chips-required')
    } else {
      $seenChips = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
      foreach ($chip in @($InputTarget.proposedChips)) {
        if (-not (Test-MathSecrQueryObjectShape $chip @('value', 'provenance')) -or
            $chip.provenance -isnot [string] -or $chip.provenance -cne 'literal-body' -or
            -not (Test-MathSecrSearchSingleBodyWord $chip.value)) {
          $errors.Add('invalid-literal-body-word'); continue
        }
        if (-not $seenChips.Add((ConvertTo-MathSecrSearchNormalizedChip $chip.value))) {
          $errors.Add('normalized-duplicate-chip'); continue
        }
        if (-not $bodyValid) { continue }
        $span = Get-MathSecrQueryLiteralSpan $InputTarget.sourceBodyText $chip.value
        if ($null -eq $span) { $errors.Add("chip-not-literal-in-transcription:$($chip.value)"); continue }
        $chips.Add([pscustomobject][ordered]@{
          value = $chip.value; provenance = 'literal-body'
          evidenceReceipt = "query-plan:transcription-sha256=$bodyHash;nfkc-utf16-span=$($span.start):$($span.length)"
          sourceSpan = $span
        })
      }
    }
    $inputHints = $InputTarget.recoveryHints
    if (-not (Test-MathSecrQueryObjectShape $inputHints @('printedMetadata', 'candidateIds', 'sourcePaperSelectors'))) {
      $errors.Add('recovery-hints-shape')
    } else {
      if (-not (Test-MathSecrSearchStrictStringArray $inputHints.candidateIds $true)) {
        $errors.Add('invalid-candidate-id-hints')
      }
      if (-not (Test-MathSecrSearchStrictStringArray $inputHints.sourcePaperSelectors)) {
        $errors.Add('invalid-source-selector-hints')
      }
      if ($inputHints.printedMetadata -isnot [System.Array]) {
        $errors.Add('printed-metadata-array-required')
      } else {
        $seenMetadata = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($item in @($inputHints.printedMetadata)) {
          if (-not (Test-MathSecrQueryObjectShape $item @('value', 'sourceText')) -or
              -not (Test-MathSecrSearchNonblankString $item.value) -or
              $item.sourceText -isnot [string] -or [string]::IsNullOrWhiteSpace($item.sourceText)) {
            $errors.Add('printed-metadata-transcription-required'); continue
          }
          if (-not $seenMetadata.Add((ConvertTo-MathSecrSearchNormalizedChip $item.value))) {
            $errors.Add('normalized-duplicate-metadata-hint'); continue
          }
          $span = Get-MathSecrQueryLiteralSpan $item.sourceText $item.value
          if ($null -eq $span) { $errors.Add('metadata-not-literal-in-transcription'); continue }
          $metadata.Add([pscustomobject][ordered]@{
            value = $item.value; provenance = 'literal-printed-metadata'
            transcriptionSha256 = Get-MathSecrQueryTextHash $item.sourceText
            sourceSpan = $span
          })
        }
      }
      $hints = [pscustomobject][ordered]@{
        authority = 'hint-only'; printedMetadata = @($metadata)
        candidateIds = @($inputHints.candidateIds); sourcePaperSelectors = @($inputHints.sourcePaperSelectors)
      }
    }
  }
  return [pscustomobject][ordered]@{
    sourceOrder = $SourceOrder; targetBinding = $binding; inputTarget = $InputTarget
    transcriptionSha256 = $bodyHash
    initialChips = @(if ($errors.Count -eq 0) { @($chips) })
    recoveryHints = $hints; requiresLiveScopeAndFreshness = $true
    status = if ($errors.Count -eq 0) { 'ready' } else { 'blocked' }
    errors = @($errors)
  }
}

function New-MathSecrSearchQueryPlan {
  [CmdletBinding()]
  param([AllowNull()]$InputDocument)
  $errors = [System.Collections.Generic.List[string]]::new()
  $targets = [System.Collections.Generic.List[object]]::new()
  if (-not (Test-MathSecrQueryObjectShape $InputDocument @('schemaVersion', 'targets')) -or
      -not (Test-MathSecrSearchStrictInteger $InputDocument.schemaVersion) -or
      $InputDocument.schemaVersion -ne 1 -or $InputDocument.targets -isnot [System.Array] -or
      @($InputDocument.targets).Count -eq 0) {
    $errors.Add('input-document-shape')
  } else {
    $occurrences = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $order = 0
    foreach ($inputTarget in @($InputDocument.targets)) {
      $order++
      $row = New-MathSecrSearchQueryTargetPlan $inputTarget $order
      if ($null -ne $row.targetBinding -and -not $occurrences.Add([string]$row.targetBinding.occurrenceKey)) {
        $row.status = 'blocked'; $row.initialChips = @()
        $row.errors = @($row.errors) + @('duplicate-occurrence-key')
      }
      foreach ($rowError in @($row.errors)) { $errors.Add("target[$order]:$rowError") }
      $targets.Add($row)
    }
  }
  return [pscustomobject][ordered]@{
    schemaVersion = 1; truthScope = 'transcription-query-preparation-only'
    status = if ($errors.Count -eq 0) { 'ready' } else { 'blocked' }
    sourceCount = $targets.Count
    readyTargetCount = @($targets | Where-Object { $_.status -ceq 'ready' }).Count
    targets = @($targets); errors = @($errors)
  }
}

function Test-MathSecrQueryValuesEqual {
  param($Left, $Right)
  if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
  if ($Left -is [System.Array]) {
    if ($Right -isnot [System.Array] -or $Left.Count -ne $Right.Count) { return $false }
    for ($index = 0; $index -lt $Left.Count; $index++) {
      if (-not (Test-MathSecrQueryValuesEqual $Left[$index] $Right[$index])) { return $false }
    }
    return $true
  }
  if ($Left -is [pscustomobject]) {
    $names = @($Left.PSObject.Properties.Name)
    if (-not (Test-MathSecrQueryObjectShape $Right $names)) { return $false }
    foreach ($name in $names) {
      if (-not (Test-MathSecrQueryValuesEqual $Left.$name $Right.$name)) { return $false }
    }
    return $true
  }
  if ($Left -is [string]) { return $Right -is [string] -and $Left -ceq $Right }
  if ($Left -is [bool]) { return $Right -is [bool] -and $Left -eq $Right }
  return (Test-MathSecrSearchStrictInteger $Left) -and (Test-MathSecrSearchStrictInteger $Right) -and $Left -eq $Right
}

function Test-MathSecrSearchQueryTargetPlan {
  [CmdletBinding()]
  param($PlanRow, $ExpectedTargetBinding, [int]$ExpectedSourceOrder = 0)
  $valid = (Test-MathSecrSearchRequiredProperties $PlanRow @('inputTarget', 'sourceOrder', 'targetBinding')) -and
    (Test-MathSecrSearchStrictInteger $PlanRow.sourceOrder) -and $PlanRow.sourceOrder -gt 0 -and
    $PlanRow.sourceOrder -le [int]::MaxValue -and
    (Test-MathSecrQueryObjectShape $ExpectedTargetBinding @('sourceProblemNumber', 'occurrenceKey')) -and
    (Test-MathSecrSearchCanonicalToken $ExpectedTargetBinding.sourceProblemNumber) -and
    (Test-MathSecrSearchCanonicalToken $ExpectedTargetBinding.occurrenceKey)
  if ($valid) {
    $derived = New-MathSecrSearchQueryTargetPlan $PlanRow.inputTarget ([int]$PlanRow.sourceOrder)
    $valid = $derived.status -ceq 'ready' -and (Test-MathSecrQueryValuesEqual $derived $PlanRow) -and
      (Test-MathSecrQueryValuesEqual $derived.targetBinding $ExpectedTargetBinding) -and
      ($ExpectedSourceOrder -eq 0 -or $ExpectedSourceOrder -eq $PlanRow.sourceOrder)
  }
  return [pscustomobject]@{
    Valid = [bool]$valid; Status = if ($valid) { 'ready' } else { 'blocked' }
    Errors = @(if (-not $valid) { 'prepared-query-target-invalid-or-binding-mismatch' })
    TruthScope = 'transcription-query-preparation-only'
  }
}

function Test-MathSecrSearchQueryPlan {
  [CmdletBinding()]
  param($Plan)
  $valid = (Test-MathSecrSearchRequiredProperties $Plan @('targets')) -and $Plan.targets -is [System.Array]
  if ($valid) {
    $inputTargets = @()
    foreach ($row in @($Plan.targets)) {
      if (-not (Test-MathSecrSearchRequiredProperties $row @('inputTarget'))) { $valid = $false; break }
      $inputTargets += $row.inputTarget
    }
    if ($valid) {
      $derived = New-MathSecrSearchQueryPlan ([pscustomobject]@{ schemaVersion = 1; targets = $inputTargets })
      $valid = $derived.status -ceq 'ready' -and (Test-MathSecrQueryValuesEqual $derived $Plan)
    }
  }
  return [pscustomobject]@{
    Valid = [bool]$valid; Status = if ($valid) { 'ready' } else { 'blocked' }
    Errors = @(if (-not $valid) { 'prepared-query-plan-invalid' })
    TruthScope = 'transcription-query-preparation-only'
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  try {
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Use -InputPath <source-query-input.json> [-OutPath <new-plan.json>].' }
    $document = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $plan = New-MathSecrSearchQueryPlan $document
    $json = $plan | ConvertTo-Json -Depth 30
    if (-not [string]::IsNullOrWhiteSpace($OutPath)) {
      if (Test-Path -LiteralPath $OutPath) { throw 'OutPath already exists; query preparation never overwrites an input or prior plan.' }
      [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutPath), $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Output $json
    if ($plan.status -cne 'ready') { exit 2 }
  } catch {
    Write-Error $_
    exit 2
  }
}
