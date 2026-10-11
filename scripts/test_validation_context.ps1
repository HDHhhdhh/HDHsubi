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
