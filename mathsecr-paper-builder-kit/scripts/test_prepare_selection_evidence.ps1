param([string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'read_contract_json.ps1')
. (Join-Path $PSScriptRoot 'state_machine.ps1')
. (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/body-comparison/synthetic_selection_test_support.ps1')
$helper = Join-Path $PSScriptRoot 'prepare_selection_evidence.ps1'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$testRoot = Join-Path $tempBase ('mathsecr-selection-preparation-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$assertions = 0
function Assert-PreparationTest {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
  $script:assertions++
}
function Copy-PreparationTest {
  param($Value)
  ConvertFrom-MathSecrContractJson (ConvertTo-Json -InputObject $Value -Depth 80)
}
function Write-PreparationTest {
  param($Value, [string]$Path)
  [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 80), [Text.UTF8Encoding]::new($false))
}
try {
  # Real PNG bytes, synthetic judgments and captures: structural tests only.
  $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
  [IO.File]::WriteAllBytes((Join-Path $testRoot 'source.png'), $png)
  [IO.File]::WriteAllBytes((Join-Path $testRoot 'candidate.png'), $png)
  $observation = New-MathSecrSyntheticSelectionObservation -AttemptId 'attempt-1' -Chips @('본문','조건') -ResultCount 1 -OrderedIds @('candidate-1')
  $seed = [pscustomobject]@{
    number='1'; occurrenceKey='source-page-1-left'; selectedId='candidate-1'; initial='exact'
    searchAttemptReceipt=[pscustomobject]@{
      targetBinding=[pscustomobject]@{sourceProblemNumber='1';occurrenceKey='source-page-1-left'}
      outcome='exact';literalEvidence=[pscustomobject]@{body=@('본문','조건');printedMetadata=@();visibleUiMetadata=@();formula=@()}
      attempts=@([pscustomobject]@{
        attemptId='attempt-1';scope='initial-scope';phase='initial'
        chips=@([pscustomobject]@{value='본문';provenance='literal-body';evidenceReceipt='synthetic-body'},[pscustomobject]@{value='조건';provenance='literal-body';evidenceReceipt='synthetic-condition'})
        submitted=$true;freshResultVerified=$false;resultCount=1;exactFound=$true
        inspectedIds=@('candidate-1');exactMatchIds=@('candidate-1');resetBefore=$true;clearReceipt='synthetic-clean';removedChips=@()
        observationReceipt=$observation
      })
      candidateRecoveryEvidence=[pscustomobject]@{routes=@();coverage=@()}
      commonChips=@();exactMatchIds=@();literalOnlyLadderCompleted=$false;resetBackoffPerformed=$false
      candidateRecoveryCompleted=$false;completeCoverageVerified=$false
    }
    bodyComparisonReceipt=[pscustomobject]@{
      sourceProblemNumber='1';occurrenceKey='source-page-1-left';candidateId='candidate-1';searchAttemptId='attempt-1'
      policyVersion='body-only-v1';verdict='exact';sourceRenderArtifact='source.png';candidateRenderArtifact='candidate.png'
      sourceRenderScale=2;candidateRenderScale=1
      comparison=[pscustomobject]@{bodyText='match';conditions='match';formulas='match';figures='not-present';pointLabels='not-present';requiredValue='match';internalStatements='not-present'}
      comparedBy='synthetic-structural-test';comparedAtUtc='2026-09-05T00:00:05.000Z';unresolvedGlyphs=$false
    }
  }
  $inputPath = Join-Path $testRoot 'input.json'
  $outPath = Join-Path $testRoot 'output.json'
  Write-PreparationTest $seed $inputPath
  $beforeHash = (Get-FileHash -LiteralPath $inputPath).Hash
  $result = & $helper -InputPath $inputPath -OutPath $outPath -ProjectRoot $testRoot
  $prepared = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $outPath -Raw)
  Assert-PreparationTest ($result.validation -ceq 'passed') 'Positive target was not prepared.'
  Assert-PreparationTest ((Get-FileHash -LiteralPath $inputPath).Hash -ceq $beforeHash) 'Preparation changed its input file.'
  Assert-PreparationTest ($prepared.bodyComparisonReceipt.sourceRenderSha256 -ceq (Get-FileHash -LiteralPath (Join-Path $testRoot 'source.png')).Hash.ToLowerInvariant()) 'Source SHA was not computed from bytes.'
  Assert-PreparationTest ($prepared.bodyComparisonReceipt.candidateRenderSha256 -ceq (Get-FileHash -LiteralPath (Join-Path $testRoot 'candidate.png')).Hash.ToLowerInvariant()) 'Candidate SHA was not computed from bytes.'
  Assert-PreparationTest ((ConvertTo-Json -InputObject $prepared.searchAttemptReceipt.attempts[0].observationReceipt -Depth 80 -Compress) -ceq (ConvertTo-Json -InputObject $seed.searchAttemptReceipt.attempts[0].observationReceipt -Depth 80 -Compress)) 'Raw observations changed.'
  Assert-PreparationTest ($prepared.bodyComparisonReceipt.comparedAtUtc -is [string] -and $prepared.bodyComparisonReceipt.comparedAtUtc -ceq $seed.bodyComparisonReceipt.comparedAtUtc) 'Comparison timestamp changed.'
  Assert-PreparationTest ($prepared.bodyComparisonReceipt.verdict -ceq $seed.bodyComparisonReceipt.verdict) 'Body verdict changed.'
  Assert-PreparationTest ($prepared.preparation.searchObservation.FreshResultVerified -eq $true -and $prepared.preparation.searchObservation.BodyExactVerified -eq $false) 'Projection did not preserve the validator claim boundary.'
  $selected = Test-MathSecrSelectedSearchReceipt $prepared 'initial_selected'
  $bodyResult = Test-MathSecrBodyComparisonReceipt -Receipt $prepared.bodyComparisonReceipt -Target $prepared -ProjectRoot $testRoot -InspectedIds $selected.InspectedIds -AttemptId $selected.AttemptId
  Assert-PreparationTest ($selected.Valid -and $bodyResult.Valid) 'Serialized output failed existing selection validators.'
  $realDirectory = Join-Path $testRoot 'real'
  $null = New-Item -ItemType Directory -Path $realDirectory
  [IO.File]::WriteAllBytes((Join-Path $realDirectory 'candidate.png'), $png)
  Write-PreparationTest $seed (Join-Path $realDirectory 'input.json')
  $null = New-Item -ItemType Junction -Path (Join-Path $testRoot 'linked') -Target $realDirectory
  $attacks = @(
    @{name='mismatch component';mutate={param($v) $v.bodyComparisonReceipt.comparison.formulas='mismatch'}},
    @{name='explicit mismatch';mutate={param($v) $v.bodyComparisonReceipt.verdict='mismatch'}},
    @{name='missing verdict';mutate={param($v) $v.bodyComparisonReceipt.PSObject.Properties.Remove('verdict')}},
    @{name='wrong source';mutate={param($v) $v.bodyComparisonReceipt.sourceProblemNumber='2'}},
    @{name='wrong occurrence';mutate={param($v) $v.bodyComparisonReceipt.occurrenceKey='other'}},
    @{name='wrong candidate';mutate={param($v) $v.bodyComparisonReceipt.candidateId='other'}},
    @{name='wrong attempt';mutate={param($v) $v.bodyComparisonReceipt.searchAttemptId='other'}},
    @{name='wrong search binding';mutate={param($v) $v.searchAttemptReceipt.targetBinding.occurrenceKey='other'}},
    @{name='uninspected';mutate={param($v) $v.searchAttemptReceipt.attempts[0].inspectedIds=@('other')}},
    @{name='missing actual exact';mutate={param($v) $v.searchAttemptReceipt.attempts[0].exactFound=$false}},
    @{name='stale capture';mutate={param($v) $v.searchAttemptReceipt.attempts[0].observationReceipt.observations[-1].raw.result.observedSubmitId='old-submit'}},
    @{name='missing artifact';mutate={param($v) $v.bodyComparisonReceipt.sourceRenderArtifact='missing.png'}},
    @{name='directory artifact';mutate={param($v) $v.bodyComparisonReceipt.sourceRenderArtifact='.'}},
    @{name='traversal';mutate={param($v) $v.bodyComparisonReceipt.candidateRenderArtifact='../candidate.png'}},
    @{name='absolute artifact';mutate={param($v) $v.bodyComparisonReceipt.candidateRenderArtifact=Join-Path $testRoot 'candidate.png'}},
    @{name='reparse artifact';mutate={param($v) $v.bodyComparisonReceipt.candidateRenderArtifact='linked/candidate.png'}},
    @{name='same path';mutate={param($v) $v.bodyComparisonReceipt.candidateRenderArtifact='source.png'}},
    @{name='supplied wrong hash';mutate={param($v) $v.bodyComparisonReceipt | Add-Member sourceRenderSha256 ('0'*64)}},
    @{name='wrong source binding';mutate={param($v) $v | Add-Member sourceBodyArtifact ([pscustomobject]@{path='source.png';sha256=('0'*64)})}},
    @{name='unresolved';mutate={param($v) $v.bodyComparisonReceipt.unresolvedGlyphs=$true}},
    @{name='missing comparer';mutate={param($v) $v.bodyComparisonReceipt.comparedBy=''}},
    @{name='string scale';mutate={param($v) $v.bodyComparisonReceipt.sourceRenderScale='2'}}
  )
  $index = 0
  foreach ($attack in $attacks) {
    $value = Copy-PreparationTest $seed
    & $attack.mutate $value
    $badInput = Join-Path $testRoot "bad-$index.json"
    $badOutput = Join-Path $testRoot "rejected-$index.json"
    Write-PreparationTest $value $badInput
    $badHash = (Get-FileHash -LiteralPath $badInput).Hash
    $rejected = $false
    try { $null = & $helper -InputPath $badInput -OutPath $badOutput -ProjectRoot $testRoot } catch { $rejected = $true }
    Assert-PreparationTest $rejected "$($attack.name) was accepted."
    Assert-PreparationTest (-not (Test-Path -LiteralPath $badOutput)) "$($attack.name) wrote output before rejection."
    Assert-PreparationTest ((Get-FileHash -LiteralPath $badInput).Hash -ceq $badHash) "$($attack.name) modified input."
    $index++
  }
  $savedHash = (Get-FileHash -LiteralPath $outPath).Hash
  $rejected = $false
  try { $null = & $helper -InputPath $inputPath -OutPath $outPath -ProjectRoot $testRoot } catch { $rejected = $true }
  Assert-PreparationTest ($rejected -and (Get-FileHash -LiteralPath $outPath).Hash -ceq $savedHash) 'Existing output was overwritten.'
  $outside = Join-Path $tempBase ('mathsecr-outside-' + [Guid]::NewGuid().ToString('N') + '.json')
  $rejected = $false
  try { $null = & $helper -InputPath $inputPath -OutPath $outside -ProjectRoot $testRoot } catch { $rejected = $true }
  Assert-PreparationTest ($rejected -and -not (Test-Path -LiteralPath $outside)) 'Outside-root output was allowed.'
  foreach ($pathAttack in @(
    @{input=(Join-Path $testRoot 'linked/input.json');output=(Join-Path $testRoot 'reparse-input-out.json')},
    @{input=$inputPath;output=(Join-Path $testRoot 'linked/output.json')},
    @{input=$inputPath;output=(Join-Path $testRoot 'missing-parent/output.json')}
  )) {
    $rejected = $false
    try { $null = & $helper -InputPath $pathAttack.input -OutPath $pathAttack.output -ProjectRoot $testRoot } catch { $rejected = $true }
    Assert-PreparationTest ($rejected -and -not (Test-Path -LiteralPath $pathAttack.output)) 'Unsafe JSON path was accepted or wrote output.'
  }
  Write-Output "PASS Selection Evidence Preparation: $assertions assertions; actual file hashes, serialized positive, mismatch/binding/artifact failures before write, unchanged raw captures; offline-contract only."
} finally {
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  if ($resolvedTestRoot.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($resolvedTestRoot).StartsWith('mathsecr-selection-preparation-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
