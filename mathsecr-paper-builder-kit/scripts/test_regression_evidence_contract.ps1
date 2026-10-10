param(
  [string]$ProjectRoot = (Get-Location).Path,
  [ValidateSet('All', 'ValidReceipt', 'UnrelatedEvidenceAdded', 'ReferencedEvidenceDrift', 'OutputReferencedAsEvidence', 'MissingSidecar', 'StalePassArtifactReuse', 'EvidenceHashDrift', 'StringBoolean', 'StringInputFileCount', 'EvidencePathTraversal', 'FailResultReuse', 'ExtraSelfAttestedProperty', 'MissingExactPassLine')]
  [string]$Case = 'All'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'regression_evidence_contract.ps1')

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Expect-Rejection {
  param([string]$Name, [scriptblock]$Action, [string]$ExpectedFragment)

  try {
    & $Action
  } catch {
    Assert-True ($_.Exception.Message -like "*$ExpectedFragment*") "$Name rejected with unexpected message: $($_.Exception.Message)"
    Write-Host "$Name rejected as expected: $($_.Exception.Message)"
    return
  }
  throw "$Name should have failed the regression-evidence contract."
}

function Write-Utf8Text {
  param([string]$Path, [string]$Text)
  $parent = Split-Path -Parent $Path
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-ValidSyntheticReceipt {
  param([string]$Root, [string]$Name)

  $project = Join-Path $Root $Name
  Write-Utf8Text (Join-Path $project 'AGENTS.md') "synthetic agents`n"
  Write-Utf8Text (Join-Path $project 'mathsecr-paper-builder-kit\scripts\run_mathsecr_regression.ps1') "Write-Host 'synthetic runner'`n"
  Write-Utf8Text (Join-Path $project 'mathsecr-paper-builder-kit\test-fixtures\case.txt') "fixture-a`n"
  $installerDeclaration = '$RequiredEvidenceNames = @(' + "`n" + '  "referenced-installer.md"' + "`n" + ')'
  Write-Utf8Text (Join-Path $project 'mathsecr-paper-builder-kit\scripts\install.ps1') $installerDeclaration
  Write-Utf8Text (Join-Path $project 'mathsecr-paper-builder-kit\test-fixtures\lessons\re0-memo-registry.json') '{"lessons":[{"evidence":[".omo/evidence/referenced-registry.md"]}]}'
  Write-Utf8Text (Join-Path $project 'mathsecr-paper-builder-kit\test-fixtures\evaluation\ground-truth-claims.json') '{"claims":[{"designArtifacts":[".omo/evidence/referenced-design.md"],"oracleArtifacts":[{"path":".omo/evidence/referenced-oracle.md"}]}]}'
  Write-Utf8Text (Join-Path $project '.omo\prompts\prompt.md') "consumer reference`n"
  Write-Utf8Text (Join-Path $project '.omo\evidence\dated-source.md') "dated observation`n"
  $referencedEvidencePaths = @(
    (Join-Path $project '.omo\evidence\referenced-installer.md'),
    (Join-Path $project '.omo\evidence\referenced-registry.md'),
    (Join-Path $project '.omo\evidence\referenced-design.md'),
    (Join-Path $project '.omo\evidence\referenced-oracle.md')
  )
  foreach ($referencedPath in $referencedEvidencePaths) {
    Write-Utf8Text $referencedPath "referenced evidence`n"
  }
  $evidencePath = Join-Path $project '.omo\evidence\task-9-regression-pack.txt'
  $snapshot = Get-MathSecrRegressionInputSnapshot -ProjectRoot $project -EvidencePath $evidencePath
  Write-Utf8Text $evidencePath "# Synthetic Regression Pack`nREGRESSION PACK RESULT: PASS`n"
  $started = [DateTimeOffset]::UtcNow.AddSeconds(-1)
  $sidecarPath = Write-MathSecrRegressionEvidenceSidecar -ProjectRoot $project -EvidencePath $evidencePath -StartSnapshot $snapshot -StartedAtUtc $started -CompletedAtUtc ([DateTimeOffset]::UtcNow)
  $verified = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $project -EvidencePath $evidencePath
  return [pscustomobject]@{
    ProjectRoot = $project
    EvidencePath = $evidencePath
    SidecarPath = $sidecarPath
    FixturePath = Join-Path $project 'mathsecr-paper-builder-kit\test-fixtures\case.txt'
    ReferencedEvidencePaths = $referencedEvidencePaths
    UnrelatedEvidencePath = Join-Path $project '.omo\evidence\dated-source.md'
    Verified = $verified
  }
}

function Edit-Sidecar {
  param([string]$Path, [scriptblock]$Mutation)
  $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  & $Mutation $document
  Write-Utf8Text $Path (($document | ConvertTo-Json -Depth 20) + "`n")
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mathsecr-regression-evidence-' + [guid]::NewGuid().ToString('N'))
$redCount = 0
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$cases = if ($Case -ceq 'All') {
  @(
    'ValidReceipt',
    'UnrelatedEvidenceAdded',
    'ReferencedEvidenceDrift',
    'OutputReferencedAsEvidence',
    'MissingSidecar',
    'StalePassArtifactReuse',
    'EvidenceHashDrift',
    'StringBoolean',
    'StringInputFileCount',
    'EvidencePathTraversal',
    'FailResultReuse',
    'ExtraSelfAttestedProperty',
    'MissingExactPassLine'
  )
} else {
  @($Case)
}
try {
  foreach ($item in $cases) {
    switch ($item) {
      'ValidReceipt' {
        $valid = New-ValidSyntheticReceipt $testRoot 'valid'
        Assert-True ($valid.Verified.InputFileCount -eq 11) 'valid receipt omitted an installer, registry, or ground-truth evidence input.'
      }
      'UnrelatedEvidenceAdded' {
        $unrelated = New-ValidSyntheticReceipt $testRoot 'unrelated-evidence'
        Write-Utf8Text (Join-Path $unrelated.ProjectRoot '.omo\evidence\unrelated-late-review.md') "unrelated review`n"
        $verified = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $unrelated.ProjectRoot -EvidencePath $unrelated.EvidencePath
        Assert-True ($verified.InputManifestSha256 -ceq $unrelated.Verified.InputManifestSha256) 'unrelated evidence changed the validation manifest.'
      }
      'ReferencedEvidenceDrift' {
        $referenced = New-ValidSyntheticReceipt $testRoot 'referenced-evidence'
        Write-Utf8Text $referenced.ReferencedEvidencePaths[0] "referenced evidence changed`n"
        Expect-Rejection 'ReferencedEvidenceDrift' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $referenced.ProjectRoot -EvidencePath $referenced.EvidencePath
        } 'current validation input bytes'
        $redCount++
      }
      'OutputReferencedAsEvidence' {
        $cyclic = New-ValidSyntheticReceipt $testRoot 'cyclic-evidence'
        $registryPath = Join-Path $cyclic.ProjectRoot 'mathsecr-paper-builder-kit\test-fixtures\lessons\re0-memo-registry.json'
        Write-Utf8Text $registryPath '{"lessons":[{"evidence":[".omo/evidence/task-9-regression-pack.txt"]}]}'
        Expect-Rejection 'OutputReferencedAsEvidence' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $cyclic.ProjectRoot -EvidencePath $cyclic.EvidencePath
        } 'cannot reference the regression output or its sidecar'
        $redCount++
      }
      'MissingSidecar' {
        $missing = New-ValidSyntheticReceipt $testRoot 'missing-sidecar'
        Remove-Item -LiteralPath $missing.SidecarPath -Force
        Expect-Rejection 'MissingSidecar' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $missing.ProjectRoot -EvidencePath $missing.EvidencePath
        } 'does not exist'
        $redCount++
      }
      'StalePassArtifactReuse' {
        $stale = New-ValidSyntheticReceipt $testRoot 'stale-input'
        Write-Utf8Text $stale.FixturePath "fixture-b`n"
        Expect-Rejection 'StalePassArtifactReuse' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $stale.ProjectRoot -EvidencePath $stale.EvidencePath
        } 'current validation input bytes'
        $redCount++
      }
      'EvidenceHashDrift' {
        $evidenceDrift = New-ValidSyntheticReceipt $testRoot 'evidence-drift'
        Write-Utf8Text $evidenceDrift.EvidencePath "# Synthetic Regression Pack`nREGRESSION PACK RESULT: PASS`nchanged`n"
        Expect-Rejection 'EvidenceHashDrift' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $evidenceDrift.ProjectRoot -EvidencePath $evidenceDrift.EvidencePath
        } 'evidenceSha256'
        $redCount++
      }
      'StringBoolean' {
        $stringBoolean = New-ValidSyntheticReceipt $testRoot 'string-boolean'
        Edit-Sidecar $stringBoolean.SidecarPath { param($document) $document.productBehavior = 'false' }
        Expect-Rejection 'StringBoolean' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $stringBoolean.ProjectRoot -EvidencePath $stringBoolean.EvidencePath
        } 'strict Boolean'
        $redCount++
      }
      'StringInputFileCount' {
        $stringCount = New-ValidSyntheticReceipt $testRoot 'string-count'
        Edit-Sidecar $stringCount.SidecarPath { param($document) $document.inputFileCount = [string]$document.inputFileCount }
        Expect-Rejection 'StringInputFileCount' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $stringCount.ProjectRoot -EvidencePath $stringCount.EvidencePath
        } 'positive integer'
        $redCount++
      }
      'EvidencePathTraversal' {
        $traversal = New-ValidSyntheticReceipt $testRoot 'traversal'
        Edit-Sidecar $traversal.SidecarPath { param($document) $document.evidencePath = '../task-9-regression-pack.txt' }
        Expect-Rejection 'EvidencePathTraversal' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $traversal.ProjectRoot -EvidencePath $traversal.EvidencePath
        } 'does not bind the requested evidence file'
        $redCount++
      }
      'FailResultReuse' {
        $failResult = New-ValidSyntheticReceipt $testRoot 'fail-result'
        Edit-Sidecar $failResult.SidecarPath { param($document) $document.result = 'FAIL' }
        Expect-Rejection 'FailResultReuse' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $failResult.ProjectRoot -EvidencePath $failResult.EvidencePath
        } 'result must be PASS'
        $redCount++
      }
      'ExtraSelfAttestedProperty' {
        $extra = New-ValidSyntheticReceipt $testRoot 'extra-property'
        Edit-Sidecar $extra.SidecarPath { param($document) $document | Add-Member -NotePropertyName selfAttestedTruth -NotePropertyValue $true }
        Expect-Rejection 'ExtraSelfAttestedProperty' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $extra.ProjectRoot -EvidencePath $extra.EvidencePath
        } 'exact schema'
        $redCount++
      }
      'MissingExactPassLine' {
        $missingPass = New-ValidSyntheticReceipt $testRoot 'missing-pass-line'
        Write-Utf8Text $missingPass.EvidencePath "# Synthetic Regression Pack`nRESULT: PASS`n"
        Edit-Sidecar $missingPass.SidecarPath {
          param($document)
          $document.evidenceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $missingPass.EvidencePath).Hash.ToUpperInvariant()
        }
        Expect-Rejection 'MissingExactPassLine' {
          $null = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $missingPass.ProjectRoot -EvidencePath $missingPass.EvidencePath
        } 'exact regression PASS line'
        $redCount++
      }
    }
  }
} finally {
  $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
  $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing cleanup outside the system temp directory: $resolvedTestRoot"
  }
  if (Test-Path -LiteralPath $resolvedTestRoot) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}

$finalMarker = 'RegressionEvidence PASS truth_scope=offline-contract product_behavior=false'
Assert-True ($finalMarker -ceq 'RegressionEvidence PASS truth_scope=offline-contract product_behavior=false') 'RegressionEvidence output marker drifted.'
Write-Host "RegressionEvidence PASS truth_scope=offline-contract product_behavior=false intentional_red_cases=$redCount"
