[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'perf/append_history_support.ps1')

function Assert-ValidationContextTest {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-ValidationContextRejection {
  param([scriptblock]$Action, [string]$ExpectedMessage)
  $message = $null
  try { $null = & $Action } catch { $message = $_.Exception.Message }
  Assert-ValidationContextTest ($null -ne $message) 'Changed artifact was accepted.'
  Assert-ValidationContextTest ($message -ceq $ExpectedMessage) ("Rejection changed: " + $message)
}

function Get-ValidationContextRejection {
  param([scriptblock]$Action)
  try { $null = & $Action } catch { return $_.Exception.Message }
  throw 'Invalid PDF was accepted.'
}

function Assert-ValidationWorkerExited {
  param([int]$WorkerId)
  $timer = [Diagnostics.Stopwatch]::StartNew()
  while ($null -ne (Get-Process -Id $WorkerId -ErrorAction SilentlyContinue) -and $timer.Elapsed.TotalSeconds -lt 5) {
    Start-Sleep -Milliseconds 25
  }
  Assert-ValidationContextTest ($null -eq (Get-Process -Id $WorkerId -ErrorAction SilentlyContinue)) "PDF worker $WorkerId survived context disposal."
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-context-' + [guid]::NewGuid().ToString('N'))
try {
  # These independent calls rejected incomplete input before needing a root.
  # Context creation must not replace their original typed rejection results.
  foreach ($explicitEmptyRoot in @($false,$true)) {
    $rootArguments = @{}
    if ($explicitEmptyRoot) { $rootArguments.ProjectRoot = '' }
    $missingAnomaly = Test-MathSecrSourceAnomalyReceipt -Receipt $null @rootArguments
    Assert-ValidationContextTest ($missingAnomaly -is [bool] -and -not $missingAnomaly) 'Rootless source-anomaly rejection changed.'
    $missingMetadata = Test-MathSecrMetadataRescueReceipt -Target ([pscustomobject]@{}) @rootArguments
    Assert-ValidationContextTest ($missingMetadata.Present -is [bool] -and -not $missingMetadata.Present -and $missingMetadata.Valid -is [bool] -and -not $missingMetadata.Valid) 'Rootless metadata-rescue rejection changed.'
    $excessDepth = Test-MathSecrEditAppendReceipt -Depth 64 @rootArguments
    Assert-ValidationContextTest ($excessDepth.Valid -is [bool] -and -not $excessDepth.Valid -and @($excessDepth.Errors).Count -eq 1 -and @($excessDepth.Errors)[0] -ceq 'edit-append-history-depth') 'Rootless append-depth rejection changed.'
    $missingBody = Test-MathSecrBodyComparisonReceipt -Receipt $null @rootArguments
    Assert-ValidationContextTest ($missingBody.Valid -is [bool] -and -not $missingBody.Valid -and @($missingBody.Errors).Count -eq 1 -and @($missingBody.Errors)[0] -ceq 'body-receipt-required') 'Rootless body-comparison rejection changed.'
    Assert-ValidationContextRejection {
      Get-MathSecrProductionArtifact -Receipt $null @rootArguments
    } 'Production validation: An artifact path and SHA-256 are required.'
    Assert-ValidationContextRejection {
      Assert-MathSecrProductionRoster -Session $null @rootArguments
    } 'Production validation: A versioned session, source roster and current snapshot are required.'
    Assert-ValidationContextRejection {
      Test-MathSecrProductionSelection -Session $null @rootArguments
    } 'Production validation: A versioned session, source roster and current snapshot are required.'
    Assert-ValidationContextRejection {
      Get-MathSecrProductionPersistedCapture -Session $null @rootArguments
    } 'Production validation: AfterReload requires the final persisted-card observation artifact.'
    Assert-ValidationContextRejection {
      Get-MathSecrProductionReportProjection -Session $null @rootArguments
    } 'Production validation: AfterReload requires actual persisted cards and the failure PDF field.'
    Assert-ValidationContextRejection {
      Get-MathSecrProductionReportProjection -Session ([pscustomobject]@{persistedCards=@();failureReportPdf='없음'}) -StateResult $null @rootArguments
    } 'Production validation: AfterReload state is not reportable: /. '
  }

  $fixture = New-MathSecrAppendHistoryFixture -ProblemCount 4 -HistoryDepth 2 -OutRoot $root
  # Observe the real worker inside production, then inspect the OS after each
  # top-level call. Reusing an explicit context must start a fresh worker.
  $startCommand = Get-Command Start-MathSecrPdfValidator -ErrorAction Stop
  $script:contextOriginalPdfStart = $startCommand.ScriptBlock
  $script:contextWorkerIds = [Collections.Generic.List[int]]::new()
  $parameters = [Management.Automation.ProxyCommand]::GetParamBlock([Management.Automation.CommandMetadata]::new($startCommand))
  $proxy = '[CmdletBinding()] param({0}) process {{ $value = & $script:contextOriginalPdfStart @PSBoundParameters; $script:contextWorkerIds.Add($Context.Resources[''pdf-validator''].Process.Id); $value }}' -f $parameters
  Set-Item Function:Start-MathSecrPdfValidator ([scriptblock]::Create($proxy))
  try {
    $lifecycleContext = New-MathSecrValidationContext -ProjectRoot $root
    foreach ($call in 1..2) {
      $result = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $fixture.Session -ProjectRoot $root -Context $lifecycleContext
      Assert-ValidationContextTest $result.Valid 'Lifecycle validation failed.'
      Assert-ValidationContextTest ($script:contextWorkerIds.Count -eq $call) 'A top-level production call did not start exactly one PDF worker.'
      Assert-ValidationWorkerExited $script:contextWorkerIds[$call - 1]
      Assert-ValidationContextTest ($lifecycleContext.ActiveDepth -eq 0 -and $lifecycleContext.Resources.Count -eq 0 -and $lifecycleContext.Disposers.Count -eq 0) 'A completed context retained resources.'
    }
    Assert-ValidationContextTest ($script:contextWorkerIds[0] -ne $script:contextWorkerIds[1]) 'A reused context retained the previous worker PID.'
  } finally { Set-Item Function:Start-MathSecrPdfValidator $script:contextOriginalPdfStart }

  $pdfSession = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath (Join-Path $root $fixture.Manifest.sessions[0].artifact.path) -Raw -Encoding UTF8)
  $pdfValidation = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $pdfSession -ProjectRoot $root
  $pdfPath = $pdfSession.failureReportPdf
  $pdfBytes = [IO.File]::ReadAllBytes($pdfPath)
  try {
    [IO.File]::WriteAllBytes($pdfPath, [byte[]]$pdfBytes[0..([int][Math]::Floor($pdfBytes.Length / 2) - 1)])
    $workerMessage = Get-ValidationContextRejection {
      Invoke-MathSecrProductionStep -Step AfterReload -InputObject $pdfSession -ProjectRoot $root -Context (New-MathSecrValidationContext -ProjectRoot $root)
    }
    $onceMessage = Get-ValidationContextRejection {
      Invoke-MathSecrUserSummaryLint -Text $pdfValidation.UserSummary -ExpectedProjection $pdfValidation.ReportProjection
    }
    Assert-ValidationContextTest ($workerMessage.StartsWith('Failed-problem report PDF validation failed: ')) 'Truncated PDF failed outside the PDF validator.'
    Assert-ValidationContextTest ($workerMessage -ceq $onceMessage) ("Worker and one-shot PDF diagnostics differ: " + $workerMessage + ' / ' + $onceMessage)
  } finally { [IO.File]::WriteAllBytes($pdfPath, $pdfBytes) }
  $restoredPdf = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $pdfSession -ProjectRoot $root
  Assert-ValidationContextTest $restoredPdf.Valid 'Restored PDF was rejected.'

  # A partially truncated EOF marker is recoverable and emits a pypdf warning.
  # Force a subsequent page-count rejection to compare the entire diagnostic,
  # including the warning, then verify the next worker request has a clean buffer.
  $warningContext = Enter-MathSecrValidationContext -ProjectRoot $root
  try {
    $warningBytes = [byte[]]$pdfBytes.Clone()
    $eofIndex = [Text.Encoding]::ASCII.GetString($warningBytes).LastIndexOf('%%EOF', [StringComparison]::Ordinal)
    Assert-ValidationContextTest ($eofIndex -ge 0) 'Generated PDF has no EOF marker.'
    $warningBytes[$eofIndex + 4] = [byte]0x20
    [IO.File]::WriteAllBytes($pdfPath, $warningBytes)
    $warningWorker = Get-ValidationContextRejection { Assert-FailedProblemReportPdf -Path $pdfPath -FailedProblems @(999999) -Context $warningContext }
    $warningOnce = Get-ValidationContextRejection { Assert-FailedProblemReportPdf -Path $pdfPath -FailedProblems @(999999) }
    Assert-ValidationContextTest ($warningWorker -ceq $warningOnce -and $warningWorker.Contains('EOF marker seems truncated')) 'Worker did not preserve the complete one-shot warning diagnostic.'
    [IO.File]::WriteAllBytes($pdfPath, $pdfBytes)
    $cleanWorker = Get-ValidationContextRejection { Assert-FailedProblemReportPdf -Path $pdfPath -FailedProblems @(999999) -Context $warningContext }
    $cleanOnce = Get-ValidationContextRejection { Assert-FailedProblemReportPdf -Path $pdfPath -FailedProblems @(999999) }
    Assert-ValidationContextTest ($cleanWorker -ceq $cleanOnce -and -not $cleanWorker.Contains('EOF marker seems truncated')) 'A worker response retained a warning from the previous request.'
    $null = Invoke-MathSecrUserSummaryLint -Text $pdfValidation.UserSummary -ExpectedProjection $pdfValidation.ReportProjection -Context $warningContext
  } finally {
    [IO.File]::WriteAllBytes($pdfPath, $pdfBytes)
    Exit-MathSecrValidationContext -Context $warningContext
  }

  $context = Enter-MathSecrValidationContext -ProjectRoot $root
  try {
    $null = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $pdfSession -ProjectRoot $root -Context $context
    $worker = $context.Resources['pdf-validator'].Process
    $killedId = $worker.Id
    $worker.Kill()
    Assert-ValidationContextTest ($worker.WaitForExit(5000)) 'Killed worker did not exit promptly.'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $killedMessage = Get-ValidationContextRejection {
      Invoke-MathSecrUserSummaryLint -Text $pdfValidation.UserSummary -ExpectedProjection $pdfValidation.ReportProjection -Context $context
    }
    $timer.Stop()
    Assert-ValidationContextTest ($killedMessage.StartsWith('Failed-problem report PDF validation failed: ')) 'Worker termination changed the PDF error prefix.'
    Assert-ValidationContextTest ($timer.Elapsed.TotalSeconds -lt 10) 'A killed worker waited for the 120-second response deadline.'
    Assert-ValidationContextTest ($context.Resources['pdf-validator'].Process.Id -eq $killedId) 'A killed worker was restarted within the same context.'
  } finally { Exit-MathSecrValidationContext -Context $context }
  Assert-ValidationWorkerExited $killedId
  $recovered = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $pdfSession -ProjectRoot $root -Context $context
  Assert-ValidationContextTest $recovered.Valid 'A new top-level call did not recover after worker termination.'

  # Stage 1 has no prior append receipt, so every proxy count below measures
  # this snapshot alone rather than recursive append validations.
  $appendSession = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath (Join-Path $root $fixture.Manifest.sessions[1].artifact.path) -Raw -Encoding UTF8)
  $snapshot = $appendSession.snapshot
  $expectedIds = [string[]]@($appendSession.persistedCards | ForEach-Object {$_.problemId})
  $expectedKeys = [string[]]@($appendSession.persistedCards | ForEach-Object {$_.occurrenceKey})
  $appendCommand = Get-Command Invoke-MathSecrEditAppendReceiptValidation -ErrorAction Stop
  $script:contextOriginalAppendValidation = $appendCommand.ScriptBlock
  $script:contextAppendValidationCount = 0
  $parameters = [Management.Automation.ProxyCommand]::GetParamBlock([Management.Automation.CommandMetadata]::new($appendCommand))
  $proxy = '[CmdletBinding()] param({0}) process {{ $script:contextAppendValidationCount++; & $script:contextOriginalAppendValidation @PSBoundParameters }}' -f $parameters
  Set-Item Function:Invoke-MathSecrEditAppendReceiptValidation ([scriptblock]::Create($proxy))
  try {
    $context = Enter-MathSecrValidationContext -ProjectRoot $root
    $appendArguments = @{Snapshot=$snapshot;ExpectedIds=$expectedIds;ExpectedKeys=$expectedKeys;ProjectRoot=$root;Depth=0;Context=$context}
    $originalAppendId = $snapshot.editAppendReceipt.appendId
    try {
      $first = Test-MathSecrEditAppendReceipt @appendArguments
      $second = Test-MathSecrEditAppendReceipt @appendArguments
      Assert-ValidationContextTest ($first.Valid -and [object]::ReferenceEquals($first,$second) -and $script:contextAppendValidationCount -eq 1) 'Identical append inputs did not reuse one validation result.'
      $copyArguments = $appendArguments.Clone()
      $copyArguments.Snapshot = Copy-MathSecrBenchmarkObject $snapshot
      $copied = Test-MathSecrEditAppendReceipt @copyArguments
      Assert-ValidationContextTest ($copied.Valid -and -not [object]::ReferenceEquals($first,$copied) -and $script:contextAppendValidationCount -eq 2) 'A copied snapshot reused a different object reference cache entry.'
      $orderArguments = $appendArguments.Clone()
      $orderArguments.ExpectedIds = [string[]]$expectedIds.Clone()
      [array]::Reverse($orderArguments.ExpectedIds)
      $reordered = Test-MathSecrEditAppendReceipt @orderArguments
      Assert-ValidationContextTest (-not $reordered.Valid -and $script:contextAppendValidationCount -eq 3) 'Changed expected ID order reused a cached result.'
      $keyOrderArguments = $appendArguments.Clone()
      $keyOrderArguments.ExpectedKeys = [string[]]$expectedKeys.Clone()
      [array]::Reverse($keyOrderArguments.ExpectedKeys)
      $reorderedKeys = Test-MathSecrEditAppendReceipt @keyOrderArguments
      Assert-ValidationContextTest (-not $reorderedKeys.Valid -and $script:contextAppendValidationCount -eq 4) 'Changed expected key order reused a cached result.'
      # Internal spaces are valid opaque-token content; commas are forbidden.
      $snapshot.editAppendReceipt.appendId = 'bad,id'
      foreach ($expectedCount in 5..6) {
        $mutated = Test-MathSecrEditAppendReceipt @appendArguments
        Assert-ValidationContextTest (-not $mutated.Valid -and @($mutated.Errors).Count -eq 1 -and $mutated.Errors[0] -ceq 'edit-append-schema' -and $script:contextAppendValidationCount -eq $expectedCount) 'A mutated snapshot or rejected result bypassed actual validation.'
      }
      $snapshot.editAppendReceipt.appendId = $originalAppendId
      $restoredAppend = Test-MathSecrEditAppendReceipt @appendArguments
      Assert-ValidationContextTest ($restoredAppend.Valid -and -not [object]::ReferenceEquals($first,$restoredAppend) -and $script:contextAppendValidationCount -eq 7) 'A restored snapshot reused its stale pre-mutation result.'
    } finally {
      $snapshot.editAppendReceipt.appendId = $originalAppendId
      Exit-MathSecrValidationContext -Context $context
    }

    # JSON preserves values but erases some CLR type distinctions. Both pairs
    # below serialize identically while the original contract rejects one type.
    $typeCases = @(
      @{Property='schemaVersion';ValidValue=$snapshot.editAppendReceipt.schemaVersion;InvalidValue=[DayOfWeek]::Monday},
      @{Property='appendId';ValidValue=[string]'x';InvalidValue=[char]'x'}
    )
    foreach ($typeCase in $typeCases) {
      $propertyName = $typeCase.Property
      $originalValue = $snapshot.editAppendReceipt.$propertyName
      $context = Enter-MathSecrValidationContext -ProjectRoot $root
      $script:contextAppendValidationCount = 0
      try {
        $snapshot.editAppendReceipt.$propertyName = $typeCase.ValidValue
        $typeArguments = @{Snapshot=$snapshot;ExpectedIds=$expectedIds;ExpectedKeys=$expectedKeys;ProjectRoot=$root;Depth=0;Context=$context}
        $first = Test-MathSecrEditAppendReceipt @typeArguments
        Assert-ValidationContextTest ($first.Valid -and $script:contextAppendValidationCount -eq 1) "Initial $propertyName type validation failed."
        $validJson = ConvertTo-Json -InputObject $snapshot -Depth 100 -Compress
        $snapshot.editAppendReceipt.$propertyName = $typeCase.InvalidValue
        Assert-ValidationContextTest ((ConvertTo-Json -InputObject $snapshot -Depth 100 -Compress) -ceq $validJson) "The $propertyName type regression no longer exercises equal JSON content."
        $invalidType = Test-MathSecrEditAppendReceipt @typeArguments
        Assert-ValidationContextTest (-not $invalidType.Valid -and @($invalidType.Errors).Count -eq 1 -and $invalidType.Errors[0] -ceq 'edit-append-schema' -and $script:contextAppendValidationCount -eq 2) "A JSON-equivalent invalid $propertyName CLR type reused a cached success."
        $snapshot.editAppendReceipt.$propertyName = $typeCase.ValidValue
        $restoredType = Test-MathSecrEditAppendReceipt @typeArguments
        Assert-ValidationContextTest ($restoredType.Valid -and -not [object]::ReferenceEquals($first,$restoredType) -and $script:contextAppendValidationCount -eq 3) "Restoring the $propertyName CLR type revived a stale cached success."
      } finally {
        $snapshot.editAppendReceipt.$propertyName = $originalValue
        Exit-MathSecrValidationContext -Context $context
      }
    }

    foreach ($listName in @('ExpectedIds','ExpectedKeys')) {
      $context = Enter-MathSecrValidationContext -ProjectRoot $root
      $script:contextAppendValidationCount = 0
      try {
        $list = [Collections.Generic.List[string]]::new()
        $originalValues = if ($listName -ceq 'ExpectedIds') {$expectedIds} else {$expectedKeys}
        $list.AddRange([string[]]$originalValues)
        $listArguments = @{Snapshot=$snapshot;ExpectedIds=$expectedIds;ExpectedKeys=$expectedKeys;ProjectRoot=$root;Depth=0;Context=$context}
        $listArguments[$listName] = $list
        $first = Test-MathSecrEditAppendReceipt @listArguments
        Assert-ValidationContextTest ($first.Valid -and $script:contextAppendValidationCount -eq 1) "Initial $listName list validation failed."
        $list.Add('extra-item')
        $copyArguments = $listArguments.Clone()
        $copyArguments[$listName] = [string[]]$originalValues.Clone()
        $cached = Test-MathSecrEditAppendReceipt @copyArguments
        Assert-ValidationContextTest ([object]::ReferenceEquals($first,$cached) -and $script:contextAppendValidationCount -eq 1) "Mutating the caller's $listName list changed the cached input copy."
        foreach ($expectedCount in 2..3) {
          $changedList = Test-MathSecrEditAppendReceipt @listArguments
          Assert-ValidationContextTest (-not $changedList.Valid -and $script:contextAppendValidationCount -eq $expectedCount) "A changed $listName list reused a cached result or cached a rejection."
        }
      } finally { Exit-MathSecrValidationContext -Context $context }
    }
    # Surface belongs to both cache identities, even for the same snapshot and
    # artifact. A rejected cross-surface call must execute rather than reuse PASS.
    $context = Enter-MathSecrValidationContext -ProjectRoot $root
    $script:contextAppendValidationCount = 0
    try {
      $surfaceArguments = @{Snapshot=$snapshot;ExpectedIds=$expectedIds;ExpectedKeys=$expectedKeys;ProjectRoot=$root;Depth=0;Context=$context}
      $asideResult = Test-MathSecrEditAppendReceipt @surfaceArguments -Surface aside-repl
      $iabResult = Test-MathSecrEditAppendReceipt @surfaceArguments -Surface codex-iab
      $asideAgain = Test-MathSecrEditAppendReceipt @surfaceArguments -Surface aside-repl
      Assert-ValidationContextTest ($asideResult.Valid -and -not $iabResult.Valid -and
        $iabResult.Errors -ccontains 'edit-append-schema' -and
        [object]::ReferenceEquals($asideResult,$asideAgain) -and $script:contextAppendValidationCount -eq 2) 'Append cache crossed a surface boundary.'
      $priorArtifact = $snapshot.editAppendReceipt.priorSessionArtifact
      $asideState = $pdfValidation.StateResult
      $iabState = Copy-MathSecrBenchmarkObject $asideState
      Set-MathSecrCachedStateResult -Context $context -ArtifactSha256 $priorArtifact.sha256 -Snapshot $pdfSession.snapshot -Phase AfterReload -StateResult $asideState -Surface aside-repl
      $otherState = Get-MathSecrCachedStateResult -Context $context -ArtifactSha256 $priorArtifact.sha256 -Phase AfterReload -AppendDepth 1 -Surface codex-iab
      Assert-ValidationContextTest ($null -eq $otherState) 'State cache crossed a surface boundary.'
      Set-MathSecrCachedStateResult -Context $context -ArtifactSha256 $priorArtifact.sha256 -Snapshot $pdfSession.snapshot -Phase AfterReload -StateResult $iabState -Surface codex-iab
      $cachedAside = Get-MathSecrCachedStateResult -Context $context -ArtifactSha256 $priorArtifact.sha256 -Phase AfterReload -AppendDepth 1 -Surface aside-repl
      $cachedIab = Get-MathSecrCachedStateResult -Context $context -ArtifactSha256 $priorArtifact.sha256 -Phase AfterReload -AppendDepth 1 -Surface codex-iab
      Assert-ValidationContextTest ([object]::ReferenceEquals($asideState,$cachedAside) -and
        [object]::ReferenceEquals($iabState,$cachedIab)) 'Writing one surface replaced another surface state cache entry.'
    } finally { Exit-MathSecrValidationContext -Context $context }
  } finally { Set-Item Function:Invoke-MathSecrEditAppendReceiptValidation $script:contextOriginalAppendValidation }

  $capturePath = Join-Path $root $fixture.Session.persistedCardObservationArtifact.path
  $originalBytes = [IO.File]::ReadAllBytes($capturePath)
  $originalDigest = $fixture.Session.persistedCardObservationArtifact.sha256
  # Exercise both implicit per-call contexts and reuse of one caller-owned object.
  foreach ($explicitContext in @($false, $true)) {
    $arguments = @{Step='AfterReload';ProjectRoot=$root}
    if ($explicitContext) { $arguments.Context = New-MathSecrValidationContext -ProjectRoot $root }
    $session = Copy-MathSecrBenchmarkObject $fixture.Session
    $initial = Invoke-MathSecrProductionStep -InputObject $session @arguments
    Assert-ValidationContextTest $initial.Valid 'Normal history was rejected.'
    $initialJson = ConvertTo-Json -InputObject $initial -Depth 100 -Compress

    [IO.File]::WriteAllBytes($capturePath, [byte[]]($originalBytes + [byte]0x20))
    Assert-ValidationContextRejection {
      Invoke-MathSecrProductionStep -InputObject $session @arguments
    } 'Production validation: Artifact hash does not match its bytes.'

    # Refreshing the digest must not turn invalid capture content into valid data.
    $capture = ConvertFrom-MathSecrContractJson ([Text.Encoding]::UTF8.GetString($originalBytes))
    $capture.schemaVersion = 2
    [IO.File]::WriteAllText($capturePath, (ConvertTo-Json -InputObject $capture -Depth 100 -Compress), [Text.UTF8Encoding]::new($false))
    $session.persistedCardObservationArtifact.sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    Assert-ValidationContextRejection {
      Invoke-MathSecrProductionStep -InputObject $session @arguments
    } 'Production validation: Persisted-card capture schema or surface is invalid.'

    [IO.File]::WriteAllBytes($capturePath, $originalBytes)
    $session.persistedCardObservationArtifact.sha256 = $originalDigest
    $restored = Invoke-MathSecrProductionStep -InputObject $session @arguments
    Assert-ValidationContextTest ($restored.Valid -and (ConvertTo-Json -InputObject $restored -Depth 100 -Compress) -ceq $initialJson) 'A prior rejection changed the restored result.'
  }

  # A caller that is already inside one validation scope can warm prior-state
  # caches. That must not bypass the original append-depth error on a later use.
  $context = Enter-MathSecrValidationContext -ProjectRoot $root
  try {
    $null = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $fixture.Session -ProjectRoot $root -Context $context
    $wrongDigest = Copy-MathSecrBenchmarkObject $fixture.Session.persistedCardObservationArtifact
    $wrongDigest.sha256 = '0' * 64
    Assert-ValidationContextRejection {
      Get-MathSecrProductionArtifact -Receipt $wrongDigest -ProjectRoot $root -Context $context
    } 'Production validation: Artifact hash does not match its bytes.'
    $bounded = Invoke-MathSecrStateMachine -Snapshot $fixture.Session.snapshot -Phase AfterReload -ProjectRoot $root -AppendDepth 63 -Context $context
    Assert-ValidationContextTest ($bounded.State -ceq 'EDIT_APPEND_VERIFY' -and @($bounded.EvidenceErrors).Count -eq 1 -and @($bounded.EvidenceErrors)[0] -ceq 'edit-append-prior-state') ("A warmed state cache bypassed the append-depth limit: " + $bounded.State + '; ' + ($bounded.EvidenceErrors -join '; '))
    $shallow = Invoke-MathSecrStateMachine -Snapshot $fixture.Session.snapshot -Phase AfterReload -ProjectRoot $root -AppendDepth 0 -Context $context
    Assert-ValidationContextTest ($shallow.State -ceq 'REPORT' -and $shallow.Status -ceq '완료') 'A depth rejection polluted a later shallow validation.'
    $direct = Test-MathSecrEditAppendReceipt -Snapshot $fixture.Session.snapshot -ExpectedIds @() -ExpectedKeys @() -ProjectRoot $root -Depth 64 -Context $context
    Assert-ValidationContextTest (-not $direct.Valid -and @($direct.Errors).Count -eq 1 -and $direct.Errors[0] -ceq 'edit-append-history-depth') 'The original append-depth Errors value changed.'
  } finally { Exit-MathSecrValidationContext -Context $context }

  # SHA-256 covers the BOM as well as the payload. Parsing consumes the BOM and
  # preserves the same typed values and date strings as the contract reader.
  $bomPath = Join-Path $root 'bom-contract.json'
  $wire = '{"small":1,"large":2147483648,"flag":true,"text":"1","when":"2026-06-05T00:31:59.2552072+09:00","items":[1,2]}'
  $utf8Bom = [Text.UTF8Encoding]::new($true)
  [IO.File]::WriteAllBytes($bomPath, [byte[]]($utf8Bom.GetPreamble() + $utf8Bom.GetBytes($wire)))
  $digest = (Get-FileHash -LiteralPath $bomPath -Algorithm SHA256).Hash
  $parsed = Read-MathSecrArtifactBytes -Path $bomPath -ExpectedSha256 $digest -Parse
  $expected = ConvertFrom-MathSecrContractJson $wire
  Assert-ValidationContextTest ([string]::Equals($parsed.Sha256,$digest,[StringComparison]::OrdinalIgnoreCase) -and $parsed.Value.small.GetType() -eq $expected.small.GetType() -and $parsed.Value.large.GetType() -eq $expected.large.GetType() -and $parsed.Value.when -is [string] -and $parsed.Value.when -ceq $expected.when) 'BOM bytes, integer type, or timestamp string changed.'
  $unparsed = Read-MathSecrArtifactBytes -Path $bomPath -ExpectedSha256 $digest
  Assert-ValidationContextTest ($null -eq $unparsed.Value) 'The non-parsing reader returned a parsed value.'
  Assert-ValidationContextRejection {
    Read-MathSecrArtifactBytes -Path $bomPath -ExpectedSha256 ('0' * 64) -Parse
  } 'Artifact hash does not match its bytes.'

  # This receipt validates only the offline anomaly shape. A bad image digest
  # has historically returned false, rather than throwing a production error.
  $anomalyTarget = $fixture.Session.snapshot.targets[0]
  $anomaly = [pscustomobject]@{
    truthScope='offline-contract';sourceProblemNumber=$anomalyTarget.number
    occurrenceKey=$anomalyTarget.occurrenceKey;candidateId='candidate-2'
    sourceRenderArtifact='source-1.png';sourceRenderSha256=$anomalyTarget.sourceBodyArtifact.sha256
    candidateRenderArtifact='candidate-2.png';candidateRenderSha256=$fixture.Session.snapshot.targets[1].sourceBodyArtifact.sha256
    sourceRenderScale=2;candidateRenderScale=2;conflictClass='glyph-ambiguity'
    comparisonState='unresolved';metadataOverrideUsed=$false
  }
  $inspected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $null = $inspected.Add('candidate-2')
  $anomalyArguments = @{Target=$anomalyTarget;ProjectRoot=$root;InspectedIds=$inspected;Context=(New-MathSecrValidationContext -ProjectRoot $root)}
  Assert-ValidationContextTest (Test-MathSecrSourceAnomalyReceipt -Receipt $anomaly @anomalyArguments) 'The synthetic anomaly contract shape was rejected.'
  $anomaly.sourceRenderSha256 = '0' * 64
  $anomalyResult = Test-MathSecrSourceAnomalyReceipt -Receipt $anomaly @anomalyArguments
  Assert-ValidationContextTest ($anomalyResult -is [bool] -and -not $anomalyResult) 'An anomaly hash failure did not return false.'

  # The old JSON comparison equates integer widths but distinguishes JSON
  # booleans, strings, property order and array order. Preserve those boundaries.
  $left = [pscustomobject][ordered]@{id=[int]1;items=@([int]2,[int]3)}
  $right = [pscustomobject][ordered]@{id=[long]1;items=@([long]2,[long]3)}
  Assert-ValidationContextTest (Test-MathSecrObjectEquals $left $right) 'Equivalent JSON integers were rejected.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals $true 1)) 'Boolean and integer values were equated.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals '1' 1)) 'String and integer values were equated.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals @('a','b') @('b','a'))) 'Array order was ignored.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals @() $null)) 'An empty array was equated with null.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals @(1) 1)) 'A single-element array was equated with a scalar.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals ([pscustomobject]@{items=@()}) ([pscustomobject]@{items=$null}))) 'A nested empty array was equated with null.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals ([pscustomobject]@{items=@(1)}) ([pscustomobject]@{items=1}))) 'A nested single-element array was equated with a scalar.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals ([pscustomobject][ordered]@{a=1;b=2}) ([pscustomobject][ordered]@{b=2;a=1}))) 'Property order was ignored.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals ([pscustomobject]@{id=1}) ([pscustomobject]@{ID=1}))) 'Property-name case was ignored.'
  Assert-ValidationContextTest (Test-MathSecrObjectEquals ([pscustomobject]@{}) ([pscustomobject]@{})) 'Empty objects were rejected.'
  Assert-ValidationContextTest (Test-MathSecrObjectEquals ([ordered]@{}) ([pscustomobject]@{})) 'Equivalent empty JSON objects were rejected.'
  Assert-ValidationContextTest (-not (Test-MathSecrObjectEquals ([pscustomobject]@{}) ([pscustomobject]@{value=$null}))) 'A present null-valued property was dropped.'
  Write-Output 'ValidationContext PASS'
} finally {
  if (Test-Path -LiteralPath $root) { Remove-MathSecrOwnedBenchmarkRoot $root }
}
