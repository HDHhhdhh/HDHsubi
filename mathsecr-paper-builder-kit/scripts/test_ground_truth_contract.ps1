param(
  [string]$ProjectRoot = (Get-Location).Path,
  [ValidateSet('All', 'ValidRegistry', 'ValidExternalShape', 'CircularBodyExactSelfOracle', 'CrossSideOracleReuse', 'CrossSideProducerReuse', 'BodySideProvenanceMismatch', 'ExternalBodyExactMissingSides', 'UnboundExternalBodyExactArtifacts', 'ExternalBodyExactPolicyDrift', 'CharacterizationOverclaim', 'OracleHashDrift', 'RunnerLabelDrift', 'RunnerEvaluatorMisbinding', 'RunnerCaseDrift', 'RunnerDeadBranchDispatch', 'OutputMarkerDrift', 'OutputMarkerDataOnly', 'StringBoolean', 'DesignTraversal', 'ReparseTraversal', 'DuplicateClaimId', 'OfflineContractOracle', 'SourceAnomalyOverclaim', 'RegressionEvidenceOverclaim', 'RequiredOfflineClaimDeletion')]
  [string]$Case = 'All'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
. (Join-Path $PSScriptRoot 'ground_truth_contract.ps1')

function Copy-GroundTruthRegistry {
  param($Document)
  return ($Document | ConvertTo-Json -Depth 100 | ConvertFrom-Json)
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Expect-Rejection {
  param([string]$Name, $Document, [string]$ExpectedFragment)

  try {
    $null = Test-MathSecrGroundTruthRegistryDocument -Document $Document -ProjectRoot $ProjectRoot
  } catch {
    Assert-True ($_.Exception.Message -like "*$ExpectedFragment*") "$Name rejected with unexpected message: $($_.Exception.Message)"
    Write-Host "$Name rejected as expected: $($_.Exception.Message)"
    return
  }
  throw "$Name should have failed the ground-truth contract."
}

function Expect-ActionRejection {
  param([string]$Name, [scriptblock]$Action, [string]$ExpectedFragment)

  try {
    & $Action
  } catch {
    Assert-True ($_.Exception.Message -like "*$ExpectedFragment*") "$Name rejected with unexpected message: $($_.Exception.Message)"
    Write-Host "$Name rejected as expected: $($_.Exception.Message)"
    return
  }
  throw "$Name should have failed the ground-truth contract."
}

$registryPath = Join-Path $ProjectRoot 'mathsecr-paper-builder-kit\test-fixtures\evaluation\ground-truth-claims.json'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
  throw "Missing ground-truth registry: $registryPath"
}
$registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
$redCount = 0
$cases = if ($Case -ceq 'All') {
  @('ValidRegistry', 'ValidExternalShape', 'CircularBodyExactSelfOracle', 'CrossSideOracleReuse', 'CrossSideProducerReuse', 'BodySideProvenanceMismatch', 'ExternalBodyExactMissingSides', 'UnboundExternalBodyExactArtifacts', 'ExternalBodyExactPolicyDrift', 'CharacterizationOverclaim', 'OracleHashDrift', 'RunnerLabelDrift', 'RunnerEvaluatorMisbinding', 'RunnerCaseDrift', 'RunnerDeadBranchDispatch', 'OutputMarkerDrift', 'OutputMarkerDataOnly', 'StringBoolean', 'DesignTraversal', 'ReparseTraversal', 'DuplicateClaimId', 'OfflineContractOracle', 'SourceAnomalyOverclaim', 'RegressionEvidenceOverclaim', 'RequiredOfflineClaimDeletion')
} else {
  @($Case)
}
try {
  foreach ($item in $cases) {
    switch ($item) {
    'ValidRegistry' {
      $summary = Test-MathSecrGroundTruthRegistryDocument -Document $registry -ProjectRoot $ProjectRoot
      Assert-True ($summary.ClaimCount -eq 7) 'canonical ground-truth registry must contain seven audited claims.'
      Assert-True ($summary.ExternalCount -eq 0 -and $summary.CompleteOracleCount -eq 0) 'canonical registry must not claim an independent external oracle.'
      Assert-True ($summary.CharacterizationCount -eq 4 -and $summary.ContractCount -eq 3) 'canonical registry claim-class counts drifted.'
    }
    'ValidExternalShape' {
      $candidate = Copy-GroundTruthRegistry $registry
      $oraclePath = 'mathsecr-paper-builder-kit/test-fixtures/pdf-pages/goguk2-print2/page-1.png'
      $oracleHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ProjectRoot ($oraclePath -replace '/', '\'))).Hash
      $candidate.claims = @($candidate.claims) + @([pscustomobject]@{
          id = 'valid-external-render-identity-probe'
          claimClass = 'external-ground-truth'
          relationKind = 'pinned-render-byte-identity'
          evaluator = 'mathsecr-paper-builder-kit/scripts/test_ground_truth_contract.ps1'
          evaluatorProducerId = 'ground-truth-contract-test'
          runnerLabel = 'Ground Truth External Shape Positive'
          runnerCase = 'ValidExternalShape'
          outputMarker = 'truth_scope=external-ground-truth subject=synthetic-pinned-render-byte-identity'
          designArtifacts = @('mathsecr-paper-builder-kit/test-fixtures/evaluation/ground-truth-claims.json')
          requiredOracleSides = @('source-render')
          oracleArtifacts = @([pscustomobject]@{
              side = 'source-render'
              path = $oraclePath
              sha256 = $oracleHash
              provenanceType = 'source-derived-render'
              producerId = 'user-source-document'
              independentOfEvaluator = $true
            })
          missingOracleSides = @()
          independentOracleComplete = $true
          forbiddenConclusions = @('current-live-truth', 'product-contract')
        })
      $externalSummary = Test-MathSecrGroundTruthRegistryDocument -Document $candidate -ProjectRoot $ProjectRoot
      Assert-True ($externalSummary.ExternalCount -eq 1 -and $externalSummary.CompleteOracleCount -eq 1) 'complete independent external shape should be accepted without weakening the canonical body-exact boundary.'
    }
    'CircularBodyExactSelfOracle' {
      $candidate = Copy-GroundTruthRegistry $registry
      $body = @($candidate.claims | Where-Object id -ceq 'body-exact-corpus-scoring')[0]
      $body.independentOracleComplete = $true
      $body.missingOracleSides = @()
      $goldPath = 'mathsecr-paper-builder-kit/test-fixtures/docs/body_exact_benchmark_gold.json'
      $goldHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ProjectRoot ($goldPath -replace '/', '\'))).Hash
      $body.oracleArtifacts = @($body.oracleArtifacts) + @(
        [pscustomobject]@{ side = 'candidate-body'; path = $goldPath; sha256 = $goldHash; provenanceType = 'captured-live-body'; producerId = 'external-reviewer'; independentOfEvaluator = $true },
        [pscustomobject]@{ side = 'independent-adjudication'; path = $goldPath; sha256 = $goldHash; provenanceType = 'independent-adjudication'; producerId = 'external-reviewer'; independentOfEvaluator = $true }
      )
      Expect-Rejection 'CircularBodyExactSelfOracle' $candidate 'independent oracle cannot reuse a design artifact'
      $redCount++
    }
    'CrossSideOracleReuse' {
      $candidate = Copy-GroundTruthRegistry $registry
      $body = @($candidate.claims | Where-Object id -ceq 'body-exact-corpus-scoring')[0]
      $sourceArtifact = $body.oracleArtifacts[0]
      $body.missingOracleSides = @()
      $body.oracleArtifacts = @($body.oracleArtifacts) + @(
        [pscustomobject]@{ side = 'candidate-body'; path = $sourceArtifact.path; sha256 = $sourceArtifact.sha256; provenanceType = 'captured-live-body'; producerId = 'candidate-capture'; independentOfEvaluator = $true },
        [pscustomobject]@{ side = 'independent-adjudication'; path = $sourceArtifact.path; sha256 = $sourceArtifact.sha256; provenanceType = 'independent-adjudication'; producerId = 'independent-reviewer'; independentOfEvaluator = $true }
      )
      Expect-Rejection 'CrossSideOracleReuse' $candidate 'reuses one canonical path across oracle sides'
      $redCount++
    }
    'CrossSideProducerReuse' {
      $candidate = Copy-GroundTruthRegistry $registry
      $body = @($candidate.claims | Where-Object id -ceq 'body-exact-corpus-scoring')[0]
      $candidatePath = 'mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_db_inference_live_trace_2026-07-29.txt'
      $adjudicationPath = 'mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_search_feature_live_trace_2026-07-29.txt'
      $candidateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ProjectRoot ($candidatePath -replace '/', '\'))).Hash
      $adjudicationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ProjectRoot ($adjudicationPath -replace '/', '\'))).Hash
      $body.missingOracleSides = @()
      $body.oracleArtifacts = @($body.oracleArtifacts) + @(
        [pscustomobject]@{ side = 'candidate-body'; path = $candidatePath; sha256 = $candidateHash; provenanceType = 'captured-live-body'; producerId = 'user-source-document'; independentOfEvaluator = $true },
        [pscustomobject]@{ side = 'independent-adjudication'; path = $adjudicationPath; sha256 = $adjudicationHash; provenanceType = 'independent-adjudication'; producerId = 'independent-reviewer'; independentOfEvaluator = $true }
      )
      Expect-Rejection 'CrossSideProducerReuse' $candidate "reuses producer 'user-source-document' across oracle sides"
      $redCount++
    }
    'BodySideProvenanceMismatch' {
      $candidate = Copy-GroundTruthRegistry $registry
      $body = @($candidate.claims | Where-Object id -ceq 'body-exact-corpus-scoring')[0]
      $candidatePath = 'mathsecr-paper-builder-kit/test-fixtures/pdf-pages/goguk2-print2/page-6.png'
      $candidateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ProjectRoot ($candidatePath -replace '/', '\'))).Hash
      $body.oracleArtifacts = @($body.oracleArtifacts) + @(
        [pscustomobject]@{ side = 'candidate-body'; path = $candidatePath; sha256 = $candidateHash; provenanceType = 'source-derived-render'; producerId = 'candidate-capture'; independentOfEvaluator = $true }
      )
      Expect-Rejection 'BodySideProvenanceMismatch' $candidate "body-exact side 'candidate-body' cannot use provenance"
      $redCount++
    }
    'ExternalBodyExactMissingSides' {
      $candidate = Copy-GroundTruthRegistry $registry
      $body = @($candidate.claims | Where-Object id -ceq 'body-exact-corpus-scoring')[0]
      $body.claimClass = 'external-ground-truth'
      Expect-Rejection 'ExternalBodyExactMissingSides' $candidate 'external body-exact promotion is disabled'
      $redCount++
    }
    'UnboundExternalBodyExactArtifacts' {
      $candidate = Copy-GroundTruthRegistry $registry
      $body = @($candidate.claims | Where-Object id -ceq 'body-exact-corpus-scoring')[0]
      $candidatePath = 'mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_db_inference_live_trace_2026-07-29.txt'
      $adjudicationPath = 'mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_search_feature_live_trace_2026-07-29.txt'
      $candidateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ProjectRoot ($candidatePath -replace '/', '\'))).Hash
      $adjudicationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ProjectRoot ($adjudicationPath -replace '/', '\'))).Hash
      $body.claimClass = 'external-ground-truth'
      $body.evaluator = 'mathsecr-paper-builder-kit/scripts/test_ground_truth_contract.ps1'
      $body.evaluatorProducerId = 'ground-truth-contract-test'
      $body.runnerLabel = 'Ground Truth External Shape Positive'
      $body.runnerCase = 'ValidExternalShape'
      $body.outputMarker = 'truth_scope=external-ground-truth subject=synthetic-pinned-render-byte-identity'
      $body.missingOracleSides = @()
      $body.independentOracleComplete = $true
      $body.forbiddenConclusions = @('current-live-truth', 'product-contract')
      $body.oracleArtifacts = @($body.oracleArtifacts) + @(
        [pscustomobject]@{ side = 'candidate-body'; path = $candidatePath; sha256 = $candidateHash; provenanceType = 'captured-live-body'; producerId = 'candidate-capture'; independentOfEvaluator = $true },
        [pscustomobject]@{ side = 'independent-adjudication'; path = $adjudicationPath; sha256 = $adjudicationHash; provenanceType = 'independent-adjudication'; producerId = 'independent-reviewer'; independentOfEvaluator = $true }
      )
      Expect-Rejection 'UnboundExternalBodyExactArtifacts' $candidate 'external body-exact promotion is disabled'
      $redCount++
    }
    'ExternalBodyExactPolicyDrift' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.contract.externalBodyExactPolicy = 'allow-self-declared-provenance'
      Expect-Rejection 'ExternalBodyExactPolicyDrift' $candidate 'must forbid promotion until a typed adjudication receipt is implemented'
      $redCount++
    }
    'CharacterizationOverclaim' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.claims[1].forbiddenConclusions = @('external-ground-truth', 'product-contract')
      Expect-Rejection 'CharacterizationOverclaim' $candidate "forbiddenConclusions must include 'current-live-truth'"
      $redCount++
    }
    'OracleHashDrift' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.claims[0].oracleArtifacts[0].sha256 = ('A' * 64)
      Expect-Rejection 'OracleHashDrift' $candidate 'oracle SHA-256 mismatch'
      $redCount++
    }
    'RunnerLabelDrift' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.claims[0].runnerLabel = 'Nonexistent Ground Truth Gate'
      Expect-Rejection 'RunnerLabelDrift' $candidate 'must map to exactly one direct full-runner gate'
      $redCount++
    }
    'RunnerEvaluatorMisbinding' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.claims[0].evaluator = 'mathsecr-paper-builder-kit/scripts/test_body_exact_benchmark.ps1'
      Expect-Rejection 'RunnerEvaluatorMisbinding' $candidate 'not declared evaluator'
      $redCount++
    }
    'RunnerCaseDrift' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.claims[0].runnerCase = 'All'
      Expect-Rejection 'RunnerCaseDrift' $candidate 'runner case mismatch'
      $redCount++
    }
    'RunnerDeadBranchDispatch' {
      $tempRunner = Join-Path ([System.IO.Path]::GetTempPath()) ("mathsecr-ground-truth-dead-runner-" + [guid]::NewGuid().ToString('N') + '.ps1')
      try {
        $runnerSource = @(
          'Invoke-Logged ''Synthetic Dead Gate'' {',
          '  if ($false) {',
          '    Invoke-Script -RelativePath ''mathsecr-paper-builder-kit/scripts/test_ground_truth_contract.ps1'' -Parameters @{ Case = ''All'' }',
          '  }',
          '}'
        )
        [System.IO.File]::WriteAllText($tempRunner, (($runnerSource -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        $deadGates = @(Get-MathSecrGroundTruthRunnerGates $tempRunner)
        Assert-True ($deadGates.Count -eq 1 -and $deadGates[0].DispatchCount -eq 0) 'dead nested Invoke-Script must not count as a direct runner dispatch.'
        Write-Host 'RunnerDeadBranchDispatch rejected as expected: dead nested Invoke-Script is not a direct gate dispatch.'
      } finally {
        if (Test-Path -LiteralPath $tempRunner) { Remove-Item -LiteralPath $tempRunner -Force }
      }
      $redCount++
    }
    'OutputMarkerDrift' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.claims[0].outputMarker = 'truth_scope=dated-characterization fake-marker-only'
      Expect-Rejection 'OutputMarkerDrift' $candidate 'must emit its truth-scope output marker'
      $redCount++
    }
    'OutputMarkerDataOnly' {
      $tempMarkerScript = Join-Path ([System.IO.Path]::GetTempPath()) ("mathsecr-ground-truth-data-only-" + [guid]::NewGuid().ToString('N') + '.ps1')
      try {
        $markerSource = @(
          '$dataOnly = ''truth_scope=dated-characterization fake-marker-only''',
          'Write-Output ''safe output'''
        )
        [System.IO.File]::WriteAllText($tempMarkerScript, (($markerSource -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        Expect-ActionRejection 'OutputMarkerDataOnly' {
          Assert-MathSecrGroundTruthOutputMarker $tempMarkerScript 'truth_scope=dated-characterization fake-marker-only' 'synthetic data-only marker'
        } 'must emit its truth-scope output marker'
      } finally {
        if (Test-Path -LiteralPath $tempMarkerScript) { Remove-Item -LiteralPath $tempMarkerScript -Force }
      }
      $redCount++
    }
    'StringBoolean' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.claims[0].independentOracleComplete = 'false'
      Expect-Rejection 'StringBoolean' $candidate 'independentOracleComplete must be a strict Boolean'
      $redCount++
    }
    'DesignTraversal' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.claims[0].designArtifacts[0] = 'mathsecr-paper-builder-kit/test-fixtures/../escape.json'
      Expect-Rejection 'DesignTraversal' $candidate 'contains a traversal segment'
      $redCount++
    }
    'ReparseTraversal' {
      $reparseRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mathsecr-ground-truth-reparse-" + [guid]::NewGuid().ToString('N'))
      $reparseProject = Join-Path $reparseRoot 'project'
      $reparseOutside = Join-Path $reparseRoot 'outside'
      $reparseLink = Join-Path $reparseProject 'linked'
      try {
        New-Item -ItemType Directory -Force -Path $reparseProject, $reparseOutside | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $reparseOutside 'oracle.txt'), 'outside', (New-Object System.Text.UTF8Encoding($false)))
        New-Item -ItemType Junction -Path $reparseLink -Target $reparseOutside | Out-Null
        Expect-ActionRejection 'ReparseTraversal' {
          $null = Resolve-MathSecrGroundTruthPath $reparseProject 'linked/oracle.txt' 'synthetic reparse oracle'
        } 'crosses a reparse point'
      } finally {
        if (Test-Path -LiteralPath $reparseLink) { [System.IO.Directory]::Delete($reparseLink, $false) }
        if (Test-Path -LiteralPath $reparseRoot) { Remove-Item -LiteralPath $reparseRoot -Recurse -Force }
      }
      $redCount++
    }
    'DuplicateClaimId' {
      $candidate = Copy-GroundTruthRegistry $registry
      $candidate.claims[1].id = $candidate.claims[0].id
      Expect-Rejection 'DuplicateClaimId' $candidate 'registry repeats claim id'
      $redCount++
    }
    'OfflineContractOracle' {
      $candidate = Copy-GroundTruthRegistry $registry
      $dbClaim = @($candidate.claims | Where-Object id -ceq 'db-inference-policy')[0]
      $dbClaim.requiredOracleSides = @('live-product-behavior')
      $dbClaim.missingOracleSides = @('live-product-behavior')
      Expect-Rejection 'OfflineContractOracle' $candidate 'offline-contract must not pretend to own an external oracle'
      $redCount++
    }
    'SourceAnomalyOverclaim' {
      $candidate = Copy-GroundTruthRegistry $registry
      $claim = @($candidate.claims | Where-Object id -ceq 'source-anomaly-receipt-shape')[0]
      $claim.claimClass = 'external-ground-truth'
      Expect-Rejection 'SourceAnomalyOverclaim' $candidate 'external-ground-truth requires a complete independent oracle'
      $redCount++
    }
    'RegressionEvidenceOverclaim' {
      $candidate = Copy-GroundTruthRegistry $registry
      $claim = @($candidate.claims | Where-Object id -ceq 'regression-evidence-current-bytes')[0]
      $claim.claimClass = 'external-ground-truth'
      Expect-Rejection 'RegressionEvidenceOverclaim' $candidate 'external-ground-truth requires a complete independent oracle'
      $redCount++
    }
    'RequiredOfflineClaimDeletion' {
      $candidate = Copy-GroundTruthRegistry $registry
      $replacement = Copy-GroundTruthRegistry (@($candidate.claims | Where-Object id -ceq 'regression-evidence-current-bytes')[0])
      $replacement.id = 'unrelated-compensating-contract'
      $candidate.claims = @($candidate.claims | Where-Object id -cne 'regression-evidence-current-bytes')
      $candidate.claims = @($candidate.claims) + @($replacement)
      Expect-Rejection 'RequiredOfflineClaimDeletion' $candidate "required audited claim 'regression-evidence-current-bytes' is missing"
      $redCount++
    }
    }
  }
} finally {
}

$final = Test-MathSecrGroundTruthRegistryDocument -Document $registry -ProjectRoot $ProjectRoot
if ($Case -ceq 'ValidExternalShape') {
  Write-Host 'GroundTruthExternalShape PASS truth_scope=external-ground-truth subject=synthetic-pinned-render-byte-identity'
}
Write-Host "GroundTruth PASS claims=$($final.ClaimCount) external=$($final.ExternalCount) dated=$($final.CharacterizationCount) contract=$($final.ContractCount) independent_complete=$($final.CompleteOracleCount) intentional_red_cases=$redCount"
