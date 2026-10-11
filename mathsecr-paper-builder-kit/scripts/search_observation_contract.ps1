# Freshness heuristic for independently captured read-only DOM observations.
# It does not establish backend causality, body exactness, or complete lazy coverage.
. (Join-Path $PSScriptRoot 'surface_contract.ps1')

function Test-MathSecrObservationObject {
  param($Value, [string[]]$Fields)
  if ($Value -isnot [pscustomobject]) { return $false }
  $names = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
  if ($names.Count -ne $Fields.Count) { return $false }
  foreach ($field in $Fields) { if ($names -cnotcontains $field) { return $false } }
  return $true
}

function Test-MathSecrObservationText {
  param($Value)
  return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value) -and
    $Value -ceq $Value.Trim() -and -not [regex]::IsMatch($Value, '[\r\n]')
}

function Test-MathSecrObservationToken {
  param($Value)
  return (Test-MathSecrObservationText $Value) -and $Value -cne '없음' -and $Value.IndexOf(',') -lt 0
}

function Test-MathSecrObservationInteger {
  param($Value)
  return ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
    $Value -is [uint16] -or $Value -is [uint32]) -and $Value -ge 0 -and $Value -le 9007199254740991
}

function Test-MathSecrObservationNumber {
  param($Value)
  return ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal] -or
    (Test-MathSecrObservationInteger $Value)) -and $Value -ge 0 -and
    -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value)
}

function Test-MathSecrObservationTimestamp {
  param($Value)
  if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$') { return $false }
  $parsed = [datetimeoffset]::MinValue
  return [datetimeoffset]::TryParseExact($Value, "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)
}

function Test-MathSecrObservationStringArray {
  param($Value, [switch]$Tokens)
  if ($Value -isnot [array]) { return $false }
  foreach ($entry in $Value) {
    if ($Tokens) { if (-not (Test-MathSecrObservationToken $entry)) { return $false } }
    elseif (-not (Test-MathSecrObservationText $entry)) { return $false }
  }
  return $true
}

function Test-MathSecrObservationCriteria {
  param($Value)
  if (-not (Test-MathSecrObservationObject $Value @('scopeMode', 'sourceChips', 'filterChips', 'chips'))) { return $false }
  if (-not (Test-MathSecrObservationText $Value.scopeMode) -or
      -not (Test-MathSecrObservationStringArray $Value.sourceChips) -or
      -not (Test-MathSecrObservationStringArray $Value.filterChips) -or $Value.chips -isnot [array]) { return $false }
  foreach ($chip in $Value.chips) {
    if (-not (Test-MathSecrObservationObject $chip @('kind', 'value')) -or
        @('text', 'formula') -cnotcontains $chip.kind -or -not (Test-MathSecrObservationText $chip.value)) { return $false }
  }
  return $true
}

function Get-MathSecrObservationCriteriaSignature {
  param($Value, [switch]$ScopeOnly)
  $ordered = [ordered]@{ scopeMode = $Value.scopeMode; sourceChips = @($Value.sourceChips); filterChips = @($Value.filterChips) }
  if (-not $ScopeOnly) { $ordered.chips = @($Value.chips | ForEach-Object { [ordered]@{ kind = $_.kind; value = $_.value } }) }
  return ConvertTo-Json -InputObject $ordered -Depth 12 -Compress
}

function Get-MathSecrObservationResultSignature {
  param($Value)
  return ConvertTo-Json -InputObject ([ordered]@{ count = $Value.count; orderedIds = @($Value.orderedIds) }) -Depth 8 -Compress
}

function Test-MathSecrObservationShape {
  param($Value)
  if (-not (Test-MathSecrObservationObject $Value @('schemaVersion','collectorVersion','adapterId','adapterEvidenceId','attemptId','submitId','readEvidenceId','raw'))) { return $false }
  if (-not (Test-MathSecrObservationInteger $Value.schemaVersion) -or @(1,2) -notcontains $Value.schemaVersion -or
      $Value.collectorVersion -cne ('mathsecr-search-observation-v' + $Value.schemaVersion)) { return $false }
  foreach ($field in @('adapterId','adapterEvidenceId','attemptId','readEvidenceId')) {
    if (-not (Test-MathSecrObservationToken $Value.$field)) { return $false }
  }
  if ($null -ne $Value.submitId -and -not (Test-MathSecrObservationToken $Value.submitId)) { return $false }
  $r = $Value.raw
  $clockFields = if ($Value.schemaVersion -eq 1) { @('timeOriginMs','monotonicMs') } else { @('clockSource','captureSource','wallClockMs') }
  if (-not (Test-MathSecrObservationObject $r (@('captureId','capturedAtUtc','url','title','criteria','scopeSelectionConfirmed','result') + $clockFields))) { return $false }
  if (-not (Test-MathSecrObservationToken $r.captureId) -or -not (Test-MathSecrObservationTimestamp $r.capturedAtUtc) -or
      -not (Test-MathSecrObservationText $r.url) -or -not (Test-MathSecrObservationText $r.title) -or
      -not (Test-MathSecrObservationCriteria $r.criteria) -or $r.scopeSelectionConfirmed -isnot [bool]) { return $false }
  if ($Value.schemaVersion -eq 1) {
    if (-not (Test-MathSecrObservationNumber $r.timeOriginMs) -or -not (Test-MathSecrObservationNumber $r.monotonicMs)) { return $false }
  } else {
    if ($r.clockSource -isnot [string] -or $r.captureSource -isnot [string] -or
        $r.clockSource -cne 'date-now' -or $r.captureSource -cne 'read-evidence-id' -or
        $r.captureId -cne $Value.readEvidenceId -or -not (Test-MathSecrObservationInteger $r.wallClockMs)) { return $false }
    $utc = [datetimeoffset]::Parse($r.capturedAtUtc, [cultureinfo]::InvariantCulture)
    if ($utc.ToUnixTimeMilliseconds() -ne $r.wallClockMs) { return $false }
  }
  $result = $r.result
  if (-not (Test-MathSecrObservationObject $result @('count','orderedIds','loading','observedSubmitId','observedCriteriaKey'))) { return $false }
  if (-not (Test-MathSecrObservationInteger $result.count) -or
      -not (Test-MathSecrObservationStringArray $result.orderedIds -Tokens) -or $result.loading -isnot [bool]) { return $false }
  foreach ($field in @('observedSubmitId','observedCriteriaKey')) {
    if ($null -ne $result.$field -and -not (Test-MathSecrObservationToken $result.$field)) { return $false }
  }
  return $true
}

function Test-MathSecrSearchObservation {
  [CmdletBinding()]
  param($Packet, $AttemptId, $Chips, $ResultCount, [string]$Surface = $null)
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $risks = New-Object 'System.Collections.Generic.List[string]'
  $projection = $null
  $required = 2
  $shape = $true
  if (-not (Test-MathSecrObservationObject $Packet @('schemaVersion','attemptId','submission','beforeSubmit','observations'))) { $shape = $false }
  if ($shape) {
    if (-not (Test-MathSecrObservationInteger $Packet.schemaVersion) -or $Packet.schemaVersion -ne 1 -or
        -not (Test-MathSecrObservationToken $Packet.attemptId) -or $Packet.observations -isnot [array] -or
        -not (Test-MathSecrObservationShape $Packet.beforeSubmit)) { $shape = $false }
    $s = $Packet.submission
    if (-not (Test-MathSecrObservationObject $s @('submitId','actionEvidenceId','action','surface','completedAtUtc','url','criteria','resultCriteriaKey'))) { $shape = $false }
    else {
      if (-not (Test-MathSecrObservationToken $s.submitId) -or -not (Test-MathSecrObservationToken $s.actionEvidenceId) -or
          $s.action -cne '검색하기' -or -not (Test-MathSecrSupportedSurface $s.surface) -or
          (-not [string]::IsNullOrEmpty($Surface) -and $s.surface -cne $Surface) -or
          -not (Test-MathSecrObservationTimestamp $s.completedAtUtc) -or -not (Test-MathSecrObservationText $s.url) -or
          -not (Test-MathSecrObservationCriteria $s.criteria) -or
          ($null -ne $s.resultCriteriaKey -and -not (Test-MathSecrObservationToken $s.resultCriteriaKey))) { $shape = $false }
    }
    foreach ($observation in @($Packet.observations)) { if (-not (Test-MathSecrObservationShape $observation)) { $shape = $false } }
  }
  if (-not $shape) { $errors.Add('invalid observation packet schema or strict field type') }
  else {
    $s = $Packet.submission
    $baseline = $Packet.beforeSubmit
    $criteriaSignature = Get-MathSecrObservationCriteriaSignature $s.criteria
    $submitTime = [datetimeoffset]::Parse($s.completedAtUtc, [cultureinfo]::InvariantCulture)
    if ($null -ne $baseline.submitId) { $errors.Add('beforeSubmit must not carry a submit binding') }
    if ([datetimeoffset]::Parse($baseline.raw.capturedAtUtc) -gt $submitTime) { $errors.Add('beforeSubmit was captured after submission') }
    if ((Get-MathSecrObservationCriteriaSignature $baseline.raw.criteria -ScopeOnly) -cne
        (Get-MathSecrObservationCriteriaSignature $s.criteria -ScopeOnly)) { $risks.Add('scope-or-filter-change') }
    if ((Get-MathSecrObservationCriteriaSignature $baseline.raw.criteria) -cne $criteriaSignature) {
      # The baseline is the final criteria read immediately before clicking search.
      # Scope changes still require three reads; query drift here has no trustworthy submit binding.
      if ((ConvertTo-Json -InputObject @($baseline.raw.criteria.chips) -Compress) -cne
          (ConvertTo-Json -InputObject @($s.criteria.chips) -Compress)) { $errors.Add('submission criteria do not match pre-submit committed chips') }
    }
    if ($PSBoundParameters.ContainsKey('AttemptId') -and
        (-not (Test-MathSecrObservationToken $AttemptId) -or $AttemptId -cne $Packet.attemptId)) { $errors.Add('attemptId binding mismatch') }
    if ($PSBoundParameters.ContainsKey('Chips')) {
      if (-not (Test-MathSecrObservationStringArray $Chips) -or
          (ConvertTo-Json -InputObject @($Chips) -Compress) -cne
          (ConvertTo-Json -InputObject @($s.criteria.chips | ForEach-Object { $_.value }) -Compress)) { $errors.Add('ordered chip binding mismatch') }
    }
    if ($PSBoundParameters.ContainsKey('ResultCount') -and -not (Test-MathSecrObservationInteger $ResultCount)) { $errors.Add('expected ResultCount must be a strict integer') }
    $seenCaptures = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenReads = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenRaw = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenClocks = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $previousMono = -1.0
    $previousTime = [datetimeoffset]::MinValue
    $all = @($baseline) + @($Packet.observations)
    foreach ($observation in $all) {
      $r = $observation.raw
      $rawJson = ConvertTo-Json -InputObject $r -Depth 20 -Compress
      if (-not $seenCaptures.Add($r.captureId) -or -not $seenReads.Add($observation.readEvidenceId) -or
          -not $seenRaw.Add($rawJson)) { $errors.Add('replayed capture/read/raw evidence identity') }
      if ($observation.readEvidenceId -ceq $s.actionEvidenceId) { $errors.Add('action evidence cannot be reused as read evidence') }
      if ($observation.attemptId -cne $Packet.attemptId -or $r.url -cne $s.url -or $r.title -cne $baseline.raw.title -or
          $observation.adapterId -cne $baseline.adapterId -or $observation.adapterEvidenceId -cne $baseline.adapterEvidenceId) { $errors.Add('URL/title/adapter/attempt binding drift') }
      $time = [datetimeoffset]::Parse($r.capturedAtUtc, [cultureinfo]::InvariantCulture)
      if ($observation.schemaVersion -ne $baseline.schemaVersion) { $errors.Add('capture clock profile drift') }
      elseif ($observation.schemaVersion -eq 1) {
        $clockKey = [string]$r.timeOriginMs + '|' + [string]$r.monotonicMs
        if (-not $seenClocks.Add($clockKey)) { $errors.Add('replayed capture/read/raw evidence identity') }
        if ($r.timeOriginMs -ne $baseline.raw.timeOriginMs -or $r.monotonicMs -le $previousMono) { $errors.Add('capture clock or ordering drift') }
        $previousMono = $r.monotonicMs
      }
      # Date is a wall clock: distinct actual tool reads may share a millisecond.
      # Receipt identities establish detectable independence; clock regression blocks.
      if ($time -lt $previousTime) { $errors.Add('capture clock or ordering drift') }
      $previousTime = $time
      $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
      foreach ($id in $r.result.orderedIds) { if (-not $ids.Add($id)) { $errors.Add('duplicate visible result ID') } }
      if ($r.result.orderedIds.Count -gt $r.result.count) { $errors.Add('visible ID count exceeds reported result count') }
    }
    foreach ($observation in $Packet.observations) {
      $r = $observation.raw
      if ($observation.submitId -cne $s.submitId -or [datetimeoffset]::Parse($r.capturedAtUtc) -lt $submitTime) { $errors.Add('pre-submit read or wrong submit identity') }
      if ((Get-MathSecrObservationCriteriaSignature $r.criteria) -cne $criteriaSignature) { $errors.Add('post-submit criteria drift') }
      if (-not $r.scopeSelectionConfirmed) { $errors.Add('selected scope control not confirmed') }
      if ($r.criteria.sourceChips.Count -eq 0 -and $r.criteria.scopeMode -cne '전체 DB') { $errors.Add('empty source scope is not verified whole DB') }
      if ($r.result.count -eq 0) { if (-not $risks.Contains('zero-result')) { $risks.Add('zero-result') } }
      if ($r.result.count -ne $r.result.orderedIds.Count) { if (-not $risks.Contains('count-card-mismatch')) { $risks.Add('count-card-mismatch') } }
      if ($null -ne $r.result.observedSubmitId -and $r.result.observedSubmitId -cne $s.submitId) { $errors.Add('observed result submit identity is stale') }
      if ($null -ne $r.result.observedCriteriaKey -and ($null -eq $s.resultCriteriaKey -or $r.result.observedCriteriaKey -cne $s.resultCriteriaKey)) { $errors.Add('observed result criteria identity is stale') }
    }
    if ($risks.Count -gt 0) { $required = 3 }
    if ($Packet.observations.Count -lt $required) { $errors.Add("insufficient independent post-submit reads: require $required") }
    else {
      $tail = @($Packet.observations | Select-Object -Last $required)
      $last = $tail[$tail.Count - 1]
      $signature = Get-MathSecrObservationResultSignature $last.raw.result
      foreach ($observation in $tail) {
        if ($observation.raw.result.loading -or (Get-MathSecrObservationResultSignature $observation.raw.result) -cne $signature) { $errors.Add('post-submit stable result signature not reached') }
      }
      if ($last.raw.result.count -gt 0 -and $last.raw.result.orderedIds.Count -eq 0) { $errors.Add('nonzero result has no visible candidate identity') }
      if ($PSBoundParameters.ContainsKey('ResultCount') -and $ResultCount -ne $last.raw.result.count) { $errors.Add('result count binding mismatch') }
      $projection = [pscustomobject][ordered]@{
        AttemptId = $Packet.attemptId; SubmitId = $s.submitId; Url = $last.raw.url; Title = $last.raw.title
        ScopeMode = $last.raw.criteria.scopeMode; SourceChips = @($last.raw.criteria.sourceChips)
        FilterChips = @($last.raw.criteria.filterChips); OrderedChips = @($last.raw.criteria.chips | ForEach-Object { $_.value })
        ResultCount = $last.raw.result.count; OrderedVisibleIds = @($last.raw.result.orderedIds)
        ReadEvidenceIds = @($tail | ForEach-Object { $_.readEvidenceId }); CaptureIds = @($tail | ForEach-Object { $_.raw.captureId })
        RequiredReadCount = $required; RiskReasons = @($risks.ToArray()); FreshResultVerified = ($errors.Count -eq 0)
        TruthScope = 'offline-contract'; BackendCausalityVerified = $false; BodyExactVerified = $false; CompleteCoverageVerified = $false
      }
      if ($last.schemaVersion -eq 2) {
        $projection | Add-Member -NotePropertyName ClockSource -NotePropertyValue 'date-now'
        $projection | Add-Member -NotePropertyName CaptureSource -NotePropertyValue 'read-evidence-id'
        $projection | Add-Member -NotePropertyName MonotonicClockVerified -NotePropertyValue $false
        $projection | Add-Member -NotePropertyName DocumentClockContinuityVerified -NotePropertyValue $false
      }
    }
  }
  return [pscustomobject][ordered]@{
    SchemaValid = $shape; FreshResultVerified = ($shape -and $errors.Count -eq 0)
    RequiredReadCount = $required; Status = $(if ($shape -and $errors.Count -eq 0) { 'fresh-result-observed' } else { 'observation-pending' })
    Errors = @($errors.ToArray()); RiskReasons = @($risks.ToArray()); Projection = $projection
  }
}

function ConvertTo-MathSecrSearchObservationReportProjection {
  [CmdletBinding()]
  param($Packet, $AttemptId, $Chips, $ResultCount)
  $result = Test-MathSecrSearchObservation @PSBoundParameters
  if (-not $result.FreshResultVerified) { throw ('Observation projection blocked: ' + ($result.Errors -join '; ')) }
  return $result.Projection
}
