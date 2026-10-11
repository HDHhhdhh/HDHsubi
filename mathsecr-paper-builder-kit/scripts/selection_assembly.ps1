# Assembly preserves supplied observations and judgments. Existing contracts own acceptance.
. (Join-Path $PSScriptRoot 'state_machine.ps1')
. (Join-Path $PSScriptRoot 'read_contract_json.ps1')

function Resolve-MathSecrAssemblyPath {
  param([string]$Path, [string]$ProjectRoot, [string]$Extension, [switch]$Output)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path -cne $Path.Trim()) { throw 'assembly-path-invalid' }
  $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'assembly-project-root-missing' }
  $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Path)) {$Path} else {Join-Path $root $Path}))
  $prefix = $root + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetExtension($full).ToLowerInvariant() -cne $Extension) { throw 'assembly-path-invalid' }
  $relative = $full.Substring($prefix.Length)
  if ($relative.Contains(':')) { throw 'assembly-path-invalid' }
  $cursor = $root
  foreach ($part in $relative.Split([char[]]@('\','/'))) {
    $cursor = Join-Path $cursor $part
    if ((Test-Path -LiteralPath $cursor) -and
        (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
      throw 'assembly-reparse-point'
    }
  }
  if ($Output) {
    if (Test-Path -LiteralPath $full) { throw 'assembly-output-exists' }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $full) -PathType Container)) { throw 'assembly-output-parent-missing' }
  } elseif (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'assembly-input-missing' }
  return $full
}

function Get-MathSecrAssemblyHash {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Copy-MathSecrAssemblyObject {
  param($Value)
  # A JSON root array is enumerated by the contract reader. An envelope preserves
  # empty and singleton arrays as property values throughout the wire roundtrip.
  $envelope = [pscustomobject]@{value=$Value}
  $copy = ConvertFrom-MathSecrContractJson (ConvertTo-Json -InputObject $envelope -Depth 100 -Compress)
  return ,$copy.value
}

function Assert-MathSecrBodyJudgmentInput {
  param($Judgment)
  $keys = @('comparator','comparedAtUtc','policy','verdict','candidateId','searchAttemptId',
    'comparison','sourceRenderScale','candidateRenderScale','unresolvedGlyphs')
  foreach ($key in $keys) {
    if ($Judgment -isnot [pscustomobject] -or $null -eq $Judgment.PSObject.Properties[$key]) {
      throw "judgment-missing:$key"
    }
    $value = $Judgment.$key
    $valid = switch ($key) {
      'comparator' { Test-MathSecrSearchNonblankString $value }
      'comparedAtUtc' {
        $stamp = [DateTimeOffset]::MinValue
        $value -is [string] -and $value -cmatch 'Z$' -and [DateTimeOffset]::TryParse($value,[ref]$stamp)
      }
      'policy' { $value -is [string] -and $value -ceq 'body-only-v1' }
      'verdict' { $value -is [string] -and $value -cin @('exact','mismatch') }
      'candidateId' { Test-IsCanonicalId $value }
      'searchAttemptId' { Test-IsCanonicalId $value }
      'comparison' { $value -is [pscustomobject] }
      'unresolvedGlyphs' { $value -is [bool] }
      default { (Test-IsStrictInteger $value) -and [int64]$value -gt 0 }
    }
    if (-not $valid) { throw "judgment-invalid:$key" }
  }
  foreach ($key in @('bodyText','conditions','formulas','figures','pointLabels','requiredValue','internalStatements')) {
    if ($null -eq $Judgment.comparison.PSObject.Properties[$key]) { throw "judgment-missing:comparison.$key" }
    $value = $Judgment.comparison.$key
    if ($value -isnot [string] -or $value -cnotin @('match','not-present','mismatch')) {
      throw "judgment-invalid:comparison.$key"
    }
  }
  foreach ($key in $Judgment.PSObject.Properties.Name) {
    if ($key -cnotin $keys) {throw "judgment-invalid:$key"}
  }
  foreach ($key in $Judgment.comparison.PSObject.Properties.Name) {
    if ($key -cnotin @('bodyText','conditions','formulas','figures','pointLabels','requiredValue','internalStatements')) {
      throw "judgment-invalid:comparison.$key"
    }
  }
  if ($Judgment.verdict -ceq 'mismatch' -or $Judgment.unresolvedGlyphs -or
      @($Judgment.comparison.PSObject.Properties | Where-Object {$_.Value -ceq 'mismatch'}).Count) {
    throw 'body-not-exact'
  }
}

function New-MathSecrAssembledTarget {
  param($Roster, [string]$OccurrenceKey, $Observation, $Judgment, [string]$CandidateRelativePath,
    [string]$ProjectRoot, $InputHashes)
  Assert-MathSecrBodyJudgmentInput $Judgment
  if (-not (Test-HasRequiredProperties $Roster @('schemaVersion','targets')) -or
      -not (Test-IsStrictInteger $Roster.schemaVersion) -or $Roster.schemaVersion -ne 1 -or
      $Roster.targets -isnot [array] -or -not (Test-IsCanonicalOccurrenceKey $OccurrenceKey)) {
    throw 'roster-row-missing'
  }
  $rows = @($Roster.targets | Where-Object {
    $_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['occurrenceKey'] -and $_.occurrenceKey -ceq $OccurrenceKey
  })
  if ($rows.Count -ne 1 -or -not (Test-HasRequiredProperties $rows[0] @('number','occurrenceKey','sourceBodyArtifact')) -or
      -not (Test-IsCanonicalId $rows[0].number) -or
      -not (Test-HasRequiredProperties $rows[0].sourceBodyArtifact @('path','sha256'))) { throw 'roster-row-missing' }
  $row = $rows[0]
  $source = Resolve-MathSecrStateArtifactPath $ProjectRoot $row.sourceBodyArtifact.path
  $sourceHash = if ($null -ne $source) {Get-MathSecrAssemblyHash $source} else {$null}
  if ($null -eq $source -or $row.sourceBodyArtifact.sha256 -isnot [string] -or
      $row.sourceBodyArtifact.sha256 -cnotmatch '\A[0-9a-fA-F]{64}\z' -or
      -not [string]::Equals($sourceHash,$row.sourceBodyArtifact.sha256,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'roster-hash-mismatch'
  }
  if (-not (Test-HasRequiredProperties $Observation @('schemaVersion','literalEvidence','candidateRecoveryEvidence','attempts')) -or
      -not (Test-IsStrictInteger $Observation.schemaVersion) -or $Observation.schemaVersion -ne 1 -or
      $Observation.attempts -isnot [array] -or $Observation.attempts.Count -eq 0) {
    throw 'search-contract-rejected:observation-input-shape'
  }
  $winning = @($Observation.attempts | Where-Object {
    $_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['attemptId'] -and $_.attemptId -ceq $Judgment.searchAttemptId
  })
  if ($winning.Count -ne 1 -or $null -eq $winning[0].PSObject.Properties['scope']) {
    throw 'search-contract-rejected:winning-attempt-binding'
  }
  if ($winning[0].scope -cne 'initial-scope') { throw "assembly-scope-unsupported:$($winning[0].scope)" }
  $attempts = @(foreach ($inputAttempt in $Observation.attempts) {
    if (-not (Test-HasRequiredProperties $inputAttempt @('attemptId','scope','phase','chips','resetBefore',
        'clearReceipt','removedChips','submission','beforeSubmit','observations')) -or
        $inputAttempt.chips -isnot [array] -or
        $inputAttempt.observations -isnot [array] -or $inputAttempt.observations.Count -eq 0) {
      throw 'search-contract-rejected:attempt-input-shape'
    }
    $attemptId = $inputAttempt.attemptId
    $last = $inputAttempt.observations[-1]
    if (-not (Test-HasRequiredProperties $last @('raw')) -or
        -not (Test-HasRequiredProperties $last.raw @('result')) -or
        -not (Test-HasRequiredProperties $last.raw.result @('count','orderedIds'))) {
      throw "observation-rejected:$attemptId"
    }
    $resultCount = $last.raw.result.count
    # Optional caller caches are checked, never substituted for the observed value.
    $claimedCount = $inputAttempt.PSObject.Properties['resultCount']
    if ($null -ne $claimedCount -and
        (-not (Test-IsStrictInteger $claimedCount.Value) -or $claimedCount.Value -ne $resultCount)) {
      throw "observation-rejected:$attemptId"
    }
    if (@($inputAttempt.chips | Where-Object {-not (Test-HasRequiredProperties $_ @('value'))}).Count) {
      throw "observation-rejected:$attemptId"
    }
    $receipt = [pscustomobject]@{
      schemaVersion=1;attemptId=$attemptId;submission=(Copy-MathSecrAssemblyObject $inputAttempt.submission)
      beforeSubmit=(Copy-MathSecrAssemblyObject $inputAttempt.beforeSubmit)
      observations=(Copy-MathSecrAssemblyObject $inputAttempt.observations)
    }
    $observed = Test-MathSecrSearchObservation -Packet $receipt -AttemptId $attemptId -Chips @($inputAttempt.chips.value) -ResultCount $resultCount
    if (-not $observed.FreshResultVerified) { throw "observation-rejected:$attemptId" }
    $isWinning = $attemptId -ceq $Judgment.searchAttemptId
    $exactIds = @(if ($isWinning -and @($last.raw.result.orderedIds) -ccontains $Judgment.candidateId) {$Judgment.candidateId})
    [pscustomobject]@{
      attemptId=$attemptId;scope=$inputAttempt.scope;phase=$inputAttempt.phase
      chips=(Copy-MathSecrAssemblyObject $inputAttempt.chips)
      submitted=($null -ne $inputAttempt.submission);freshResultVerified=$observed.FreshResultVerified
      resultCount=$resultCount;exactFound=[bool]$isWinning
      inspectedIds=(Copy-MathSecrAssemblyObject $last.raw.result.orderedIds);exactMatchIds=$exactIds
      resetBefore=$inputAttempt.resetBefore;clearReceipt=$inputAttempt.clearReceipt
      removedChips=(Copy-MathSecrAssemblyObject $inputAttempt.removedChips);observationReceipt=$receipt
    }
  })
  $rootCount = $Observation.PSObject.Properties['resultCount']
  $winningCount = @($attempts | Where-Object attemptId -CEQ $Judgment.searchAttemptId)[0].resultCount
  if ($null -ne $rootCount -and (-not (Test-IsStrictInteger $rootCount.Value) -or $rootCount.Value -ne $winningCount)) {
    throw "observation-rejected:$($Judgment.searchAttemptId)"
  }
  $packet = [pscustomobject]@{
    targetBinding=[pscustomobject]@{sourceProblemNumber=$row.number;occurrenceKey=$OccurrenceKey};outcome=$Judgment.verdict
    literalEvidence=(Copy-MathSecrAssemblyObject $Observation.literalEvidence)
    attempts=$attempts;candidateRecoveryEvidence=(Copy-MathSecrAssemblyObject $Observation.candidateRecoveryEvidence)
    commonChips=@();exactMatchIds=@();literalOnlyLadderCompleted=$false;resetBackoffPerformed=$false
    candidateRecoveryCompleted=$false;completeCoverageVerified=$false
  }
  $derived = Test-MathSecrSearchAttemptContract $packet
  if (-not $derived.SchemaValid) { throw "search-contract-rejected:$($derived.Errors -join ';')" }
  foreach ($pair in @(@('commonChips','CommonChips'),@('exactMatchIds','ExactMatchIds'),
      @('literalOnlyLadderCompleted','LiteralOnlyLadderCompleted'),@('resetBackoffPerformed','ResetBackoffPerformed'),
      @('candidateRecoveryCompleted','CandidateRecoveryCompleted'),@('completeCoverageVerified','CompleteCoverageVerified'))) {
    $packet.($pair[0]) = $derived.($pair[1])
  }
  $search = Test-MathSecrSearchAttemptContract $packet
  if ($search.Status -cne 'exact-found' -or @($search.Errors).Count) { throw "search-contract-rejected:$($search.Errors -join ';')" }
  $target = [pscustomobject]@{
    number=$row.number;occurrenceKey=$OccurrenceKey;initial=$Judgment.verdict;selectedId=$Judgment.candidateId
    searchAttemptReceipt=$packet
    bodyComparisonReceipt=[pscustomobject]@{
      sourceProblemNumber=$row.number;occurrenceKey=$OccurrenceKey;candidateId=$Judgment.candidateId;searchAttemptId=$Judgment.searchAttemptId
      policyVersion=$Judgment.policy;verdict=$Judgment.verdict;sourceRenderArtifact=$row.sourceBodyArtifact.path
      candidateRenderArtifact=$CandidateRelativePath;sourceRenderScale=$Judgment.sourceRenderScale
      candidateRenderScale=$Judgment.candidateRenderScale;comparison=(Copy-MathSecrAssemblyObject $Judgment.comparison)
      comparedBy=$Judgment.comparator;comparedAtUtc=$Judgment.comparedAtUtc;unresolvedGlyphs=$Judgment.unresolvedGlyphs
      sourceRenderSha256=$sourceHash;candidateRenderSha256=$InputHashes.candidateRender
    }
    sourceBodyArtifact=[pscustomobject]@{path=$row.sourceBodyArtifact.path;sha256=$sourceHash}
    resolution='initial_selected'
  }
  $target = Copy-MathSecrAssemblyObject $target
  $selected = Test-MathSecrSelectedSearchReceipt -Target $target -Resolution $target.resolution
  if (-not $selected.Valid) { throw 'selected-search-receipt-invalid' }
  $bodyArgs = @{Receipt=$target.bodyComparisonReceipt;Target=$target;ProjectRoot=$ProjectRoot;InspectedIds=$selected.InspectedIds;AttemptId=$selected.AttemptId}
  $body = Test-MathSecrBodyComparisonReceipt @bodyArgs
  if (-not $body.Valid) { throw "body-comparison-rejected:$($body.Errors -join ';')" }
  $lines = @(foreach ($key in @('roster','observation','judgment','candidateRender')) {$key+':'+$InputHashes.$key})
  $canonical = ($lines -join [char]10) + [char]10
  $inputDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
  $target | Add-Member -NotePropertyName preparation -NotePropertyValue ([pscustomobject]@{
    helperVersion='assemble-target-v1';inputs=$InputHashes;inputSha256=$inputDigest
    truthScope='receipt-structure-and-artifact-identity-only';searchObservation=$selected.Projection
  })
  return $target
}
