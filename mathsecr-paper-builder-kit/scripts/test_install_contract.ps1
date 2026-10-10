param(
  [string]$EvidenceRoot
)

$ErrorActionPreference = "Stop"

function Resolve-TestEvidenceRoot {
  param([string]$InputPath, [string]$HubRoot)
  if ($InputPath) {
    return [System.IO.Path]::GetFullPath($InputPath)
  }

  $hubCandidate = Join-Path $HubRoot ".omo\evidence"
  if (Test-Path -LiteralPath $hubCandidate) {
    return [System.IO.Path]::GetFullPath($hubCandidate)
  }

  $hubParent = Split-Path -Parent $HubRoot
  if ((Split-Path -Leaf $hubParent) -eq ".worktrees") {
    $mainHub = Split-Path -Parent $hubParent
    $mainCandidate = Join-Path $mainHub ".omo\evidence"
    if (Test-Path -LiteralPath $mainCandidate) {
      return [System.IO.Path]::GetFullPath($mainCandidate)
    }
  }

  return [System.IO.Path]::GetFullPath($hubCandidate)
}

function Invoke-ContractProcess {
  param(
    [string]$Name,
    [string[]]$Arguments,
    [bool]$ExpectSuccess
  )

  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $script:PowerShellExe @Arguments 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  $succeeded = $code -eq 0
  if ($succeeded -ne $ExpectSuccess) {
    $tail = @($output | Select-Object -Last 30) -join [Environment]::NewLine
    throw "$Name returned exit $code; expected success=$ExpectSuccess`n$tail"
  }
  return [pscustomobject]@{
    Name = $Name
    ExitCode = $code
    Output = @($output)
  }
}

function Set-SyntheticSkillValidator {
  param([string]$Path, [bool]$ShouldPass)
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }

  if ($ShouldPass) {
    $source = @'
import pathlib
import sys

skill = pathlib.Path(sys.argv[1]) / "SKILL.md"
if not skill.is_file():
    print("missing SKILL.md", file=sys.stderr)
    sys.exit(2)
text = skill.read_text(encoding="utf-8")
for marker in ("---", "name: mathsecr-paper-builder", "description:"):
    if marker not in text:
        print(f"missing marker: {marker}", file=sys.stderr)
        sys.exit(3)
print("SYNTHETIC_SKILL_VALIDATOR_PASS")
'@
  } else {
    $source = @'
import sys

print("SYNTHETIC_SKILL_VALIDATOR_FORCED_FAIL", file=sys.stderr)
sys.exit(7)
'@
  }
  [System.IO.File]::WriteAllText($Path, $source, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-FailingPythonShim {
  param([string]$Path)

  $source = @'
@echo off
echo synthetic missing imports: PIL reportlab pypdf 1>&2
exit /b 19
'@
  [System.IO.File]::WriteAllText($Path, $source, (New-Object System.Text.UTF8Encoding($false)))
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
$hubRoot = Split-Path -Parent $kitRoot
$installer = Join-Path $scriptRoot "install.ps1"
$checker = Join-Path $scriptRoot "check.ps1"
$EvidenceRoot = Resolve-TestEvidenceRoot $EvidenceRoot $hubRoot
$script:PowerShellExe = (Get-Process -Id $PID).Path

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mathsecr-install-contract-" + [guid]::NewGuid().ToString("N"))
$targetProject = Join-Path $testRoot "project"
$targetCodexHome = Join-Path $testRoot "codex"
$missingProject = Join-Path $testRoot "missing-project"
$missingCodexHome = Join-Path $testRoot "missing-codex"
$missingEvidence = Join-Path $testRoot "missing-evidence"
$safetyProject = Join-Path $testRoot "filesystem-root-guard-project"
$syntheticSkillValidator = Join-Path $targetCodexHome "skills\.system\skill-creator\scripts\quick_validate.py"

$requiredEvidenceNames = @(
  "mathsecr_source_selector_exception_2026-06-05.md",
  "mathsecr_restart_results_2026-06-05.md",
  "mathsecr_mission_first_review_2026-06-05.md",
  "mathsecr_search_momentum_review_2026-06-05.md",
  "mathsecr_state_contamination_2026-06-05.md",
  "mathsecr_new_paper_adaptive_search_policy_2026-06-05.md",
  "mathsecr_scheduled_retry_results_2026-06-05.md",
  "mathsecr_minimal_failure_rules_2026-06-06.md",
  "mathsecr_body_only_exact_policy_2026-06-07.md",
  "mathsecr_search_regression_recovery_policy_2026-06-07.md",
  "mathsecr_formula_search_feature_test_2026-06-08.md",
  "mathsecr_search_feature_live_verification_2026-07-29.md",
  "mathsecr_db_inference_search_test_2026-07-29.md",
  "mathsecr_external_handoff_gap_fill_2026-07-31.md",
  "mathsecr_selection_journal_resume_2026-07-31.md",
  "mathsecr_pdf_segmentation_corpus_2026-07-31.md",
  "mathsecr_idle_search_characterization_2026-07-31.md",
  "mathsecr_metadata_rescue_gap_2026-08-15.md",
  "mathsecr_semantic_and_false_negative_2026-08-26.md",
  "mathsecr_report_receipt_binding_2026-08-26.md",
  "mathsecr_session_019ecab8_learning_review.md",
  "mathsecr_re0_memo_2026-08-27.md",
  "mathsecr_mandela_ground_truth_2026-08-27.md",
  "mathsecr_recent_two_week_learning_expansion_2026-08-27.md"
)
$re0MemoRegistryPath = Join-Path $kitRoot "test-fixtures\lessons\re0-memo-registry.json"
if (-not (Test-Path -LiteralPath $re0MemoRegistryPath -PathType Leaf)) {
  throw "Missing re0-memo registry in source kit: $re0MemoRegistryPath"
}
try {
  $re0MemoRegistry = Get-Content -LiteralPath $re0MemoRegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  throw "Re0-memo registry is not valid JSON: $re0MemoRegistryPath. $($_.Exception.Message)"
}
foreach ($evidencePath in @($re0MemoRegistry.lessons | ForEach-Object { @($_.evidence) })) {
  if ($evidencePath -isnot [string]) {
    throw "Re0-memo registry contains a non-string evidence path."
  }
  $normalizedEvidencePath = ([string]$evidencePath).Replace('\', '/')
  if ($normalizedEvidencePath -cnotmatch '^\.omo/evidence/([^/]+)$') {
    throw "Re0-memo registry evidence must be a direct .omo/evidence child: $evidencePath"
  }
  $requiredEvidenceNames += [string]$Matches[1]
}
$requiredEvidenceNames = @($requiredEvidenceNames | Sort-Object -Unique)

$pdfSegmentationManifestPath = Join-Path $kitRoot "test-fixtures\pdf-segmentation\segmentation-corpus-2026-07-31.json"
if (-not (Test-Path -LiteralPath $pdfSegmentationManifestPath -PathType Leaf)) {
  throw "Missing PDF segmentation manifest in source kit: $pdfSegmentationManifestPath"
}
try {
  $pdfSegmentationManifest = Get-Content -LiteralPath $pdfSegmentationManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  throw "PDF segmentation manifest is not valid JSON: $pdfSegmentationManifestPath. $($_.Exception.Message)"
}
$pdfSegmentationArtifactPaths = @($pdfSegmentationManifest.artifacts | ForEach-Object { [string]$_.path })
if ($pdfSegmentationArtifactPaths.Count -eq 0) {
  throw "PDF segmentation manifest does not declare any packaged render artifacts."
}
$pdfFixtureRootFull = [System.IO.Path]::GetFullPath((Join-Path $kitRoot "test-fixtures\pdf-segmentation")).TrimEnd('\')
$pdfFixturePrefix = $pdfFixtureRootFull + '\'
foreach ($artifactPath in $pdfSegmentationArtifactPaths) {
  if ([string]::IsNullOrWhiteSpace($artifactPath) -or [System.IO.Path]::IsPathRooted($artifactPath)) {
    throw "PDF segmentation manifest declares a non-relative artifact path: $artifactPath"
  }
  $artifactFullPath = [System.IO.Path]::GetFullPath((Join-Path $pdfFixtureRootFull $artifactPath))
  if (-not $artifactFullPath.StartsWith($pdfFixturePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "PDF segmentation manifest artifact escapes its fixture root: $artifactPath"
  }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
  Set-SyntheticSkillValidator $syntheticSkillValidator $true
  $commonPrefix = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File")
  $installResult = Invoke-ContractProcess "clean temp install" ($commonPrefix + @(
    $installer,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot,
    "-Force"
  )) $true
  $installText = $installResult.Output -join "`n"
  foreach ($marker in @(
    "SYNTHETIC_SKILL_VALIDATOR_PASS",
    "CoreRules PASS",
    "SyncContract PASS",
    "SessionCoverage PASS",
    "PromptDrift observed expected missing-hard-stop failure",
    "PromptDrift observed expected browser-switch failure",
    "PromptDrift PASS",
    "Re0Memo PASS",
    "GroundTruth PASS",
    "RegressionEvidence PASS",
    "Validation complete"
  )) {
    if ($installText -notlike "*$marker*") {
      throw "clean temp install did not run the full document validator: missing $marker"
    }
  }

  $requiredFiles = @(
    (Join-Path $targetProject "AGENTS.md"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\AGENTS.md"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\skills\mathsecr-paper-builder\SKILL.md"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\prompts\start-prompt.md"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\prompts\mathsecr_new_paper_prompt.md"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\validate_mathsecr_docs.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\run_validations.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\search_attempt_contract.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_search_attempt_contract.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\search-attempts\goguk2-mid-q2.json"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_re0_memo.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\lessons\re0-memo-registry.json"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\ground_truth_contract.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_ground_truth_contract.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\evaluation\ground-truth-claims.json"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\regression_evidence_contract.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_regression_evidence_contract.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_search_characterization.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\search-characterization\phrase-stability-2026-07-31.json"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_idle_search_characterization.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\search-characterization\idle-first-query-2026-07-31.json"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\docs\db_inference_contract.md"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\db_inference.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_db_inference.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\db-inference\cases.json"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\selection_journal.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_selection_journal.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\selection-journal\cases.json"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\create_failed_problem_report.py"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_failed_problem_report.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_pdf_segmentation.ps1"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\pdf-segmentation\segmentation-corpus-2026-07-31.json"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\docs\mathsecr_feature_exploration.md"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\docs\mathsecr_card_inventory_2000.json"),
    (Join-Path $targetProject "mathsecr-paper-builder-kit\test-fixtures\docs\gajwa2_candidate_summary.json"),
    (Join-Path $targetCodexHome "skills\mathsecr-paper-builder\SKILL.md"),
    (Join-Path $targetCodexHome "skills\mathsecr-paper-builder\agents\openai.yaml"),
    $syntheticSkillValidator
  )
  foreach ($artifactPath in $pdfSegmentationArtifactPaths) {
    $requiredFiles += Join-Path $targetProject (Join-Path "mathsecr-paper-builder-kit\test-fixtures\pdf-segmentation" $artifactPath)
  }
  $missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
  if ($missingFiles.Count -gt 0) {
    throw "clean temp install omitted required files: $($missingFiles -join ', ')"
  }

  $installedCropReportTest = Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_failed_problem_report.ps1"
  $installedCropReportResult = Invoke-ContractProcess "installed failed-problem crop-report contract" ($commonPrefix + @(
    $installedCropReportTest,
    "-ProjectRoot", $targetProject,
    "-Case", "All"
  )) $true
  $installedCropReportText = $installedCropReportResult.Output -join "`n"
  if ($installedCropReportText -notlike "*FailedProblemReport PASS*" -or
      $installedCropReportText -notlike "*temp_cleanup=PASS*") {
    throw "Installed failed-problem crop-report test omitted its pass/cleanup markers."
  }

  $installedSearchAttemptTest = Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_search_attempt_contract.ps1"
  $installedSearchAttemptResult = Invoke-ContractProcess "installed search-attempt provenance contract" ($commonPrefix + @(
    $installedSearchAttemptTest,
    "-ProjectRoot", $targetProject,
    "-Case", "All"
  )) $true
  $installedSearchAttemptText = $installedSearchAttemptResult.Output -join "`n"
  if ($installedSearchAttemptText -notlike "*Search-attempt contract tests PASS*") {
    throw "Installed search-attempt provenance test omitted its PASS marker."
  }

  $installedRe0MemoTest = Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_re0_memo.ps1"
  $installedRe0MemoResult = Invoke-ContractProcess "installed re0-memo registry contract" ($commonPrefix + @(
    $installedRe0MemoTest,
    "-ProjectRoot", $targetProject,
    "-Case", "ValidRegistry"
  )) $true
  $installedRe0MemoText = $installedRe0MemoResult.Output -join "`n"
  if ($installedRe0MemoText -notlike "*Re0Memo PASS*") {
    throw "Installed re0-memo registry test omitted its PASS marker."
  }

  $installedGroundTruthTest = Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_ground_truth_contract.ps1"
  $installedGroundTruthResult = Invoke-ContractProcess "installed ground-truth registry contract" ($commonPrefix + @(
    $installedGroundTruthTest,
    "-ProjectRoot", $targetProject,
    "-Case", "ValidRegistry"
  )) $true
  $installedGroundTruthText = $installedGroundTruthResult.Output -join "`n"
  if ($installedGroundTruthText -notlike "*GroundTruth PASS*") {
    throw "Installed ground-truth registry test omitted its PASS marker."
  }

  $installedRegressionEvidenceTest = Join-Path $targetProject "mathsecr-paper-builder-kit\scripts\test_regression_evidence_contract.ps1"
  $installedRegressionEvidenceResult = Invoke-ContractProcess "installed regression-evidence contract" ($commonPrefix + @(
    $installedRegressionEvidenceTest,
    "-ProjectRoot", $targetProject,
    "-Case", "All"
  )) $true
  $installedRegressionEvidenceText = $installedRegressionEvidenceResult.Output -join "`n"
  if ($installedRegressionEvidenceText -notlike "*RegressionEvidence PASS truth_scope=offline-contract product_behavior=false*") {
    throw "Installed regression-evidence test omitted its scoped PASS marker."
  }

  $runtimeFailureBin = Join-Path $testRoot "python-missing-report-deps-bin"
  New-Item -ItemType Directory -Force -Path $runtimeFailureBin | Out-Null
  $runtimeFailurePython = Join-Path $runtimeFailureBin "python.cmd"
  Set-FailingPythonShim $runtimeFailurePython
  $runtimeFailureProject = Join-Path $testRoot "runtime-preflight-target"
  $runtimeFailureCodex = Join-Path $testRoot "runtime-preflight-codex"
  $runtimeFailureKit = Join-Path $runtimeFailureProject "mathsecr-paper-builder-kit"
  New-Item -ItemType Directory -Force -Path $runtimeFailureKit | Out-Null
  New-Item -ItemType Directory -Force -Path $runtimeFailureCodex | Out-Null
  $runtimeFailureSentinel = Join-Path $runtimeFailureKit "preserve-before-runtime-preflight.txt"
  [System.IO.File]::WriteAllText($runtimeFailureSentinel, "must survive missing-Python-dependency preflight", (New-Object System.Text.UTF8Encoding($false)))

  $previousPath = $env:Path
  try {
    $env:Path = "$runtimeFailureBin;$previousPath"
    $runtimeFailureResult = Invoke-ContractProcess "missing Python report dependency preflight" ($commonPrefix + @(
      $installer,
      "-ProjectRoot", $runtimeFailureProject,
      "-CodexHome", $runtimeFailureCodex,
      "-EvidenceRoot", $EvidenceRoot,
      "-Force"
    )) $false
  } finally {
    $env:Path = $previousPath
  }
  $runtimeFailureText = $runtimeFailureResult.Output -join "`n"
  foreach ($runtimeMarker in @(
    "Python runtime capability preflight failed",
    "PIL (Pillow)",
    "reportlab",
    "pypdf"
  )) {
    if (-not $runtimeFailureText.Contains($runtimeMarker)) {
      throw "Runtime capability preflight omitted marker '$runtimeMarker'."
    }
  }
  if (-not (Test-Path -LiteralPath $runtimeFailureSentinel -PathType Leaf)) {
    throw "Runtime capability preflight mutated the existing target before rejection."
  }
  if ((Test-Path -LiteralPath (Join-Path $runtimeFailureProject "AGENTS.md")) -or
      (Test-Path -LiteralPath (Join-Path $runtimeFailureCodex "skills\mathsecr-paper-builder\SKILL.md"))) {
    throw "Runtime capability preflight installed files before rejecting the missing dependency runtime."
  }

  foreach ($evidenceName in $requiredEvidenceNames) {
    $installedEvidence = Join-Path $targetProject ".omo\evidence\$evidenceName"
    if (-not (Test-Path -LiteralPath $installedEvidence -PathType Leaf)) {
      throw "clean temp install omitted indexed evidence: $installedEvidence"
    }
  }

  $preflightAssetCases = @(
    "scripts\run_validations.ps1",
    "scripts\search_attempt_contract.ps1",
    "scripts\test_search_attempt_contract.ps1",
    "test-fixtures\search-attempts\goguk2-mid-q2.json",
    "scripts\test_re0_memo.ps1",
    "test-fixtures\lessons\re0-memo-registry.json",
    "scripts\ground_truth_contract.ps1",
    "scripts\test_ground_truth_contract.ps1",
    "test-fixtures\evaluation\ground-truth-claims.json",
    "scripts\regression_evidence_contract.ps1",
    "scripts\test_regression_evidence_contract.ps1",
    "test-fixtures\docs\body_exact_benchmark_gold.json",
    "test-fixtures\pdf-pages\goguk2-print2\page-1.png",
    "scripts\test_search_characterization.ps1",
    "test-fixtures\search-characterization\phrase-stability-2026-07-31.json",
    "scripts\test_idle_search_characterization.ps1",
    "test-fixtures\search-characterization\idle-first-query-2026-07-31.json",
    "docs\db_inference_contract.md",
    "scripts\db_inference.ps1",
    "scripts\test_db_inference.ps1",
    "test-fixtures\db-inference\cases.json",
    "scripts\selection_journal.ps1",
    "scripts\test_selection_journal.ps1",
    "test-fixtures\selection-journal\cases.json",
    "scripts\create_failed_problem_report.py",
    "scripts\test_failed_problem_report.ps1",
    "scripts\test_pdf_segmentation.ps1",
    "test-fixtures\pdf-segmentation\segmentation-corpus-2026-07-31.json",
    "test-fixtures\pdf-segmentation\rendered-pages\daejin2-page-01.png",
    "test-fixtures\pdf-segmentation\rendered-pages\juyeop1-page-08.png"
  )
  $preflightAssetIndex = 0
  foreach ($missingRelativeAsset in $preflightAssetCases) {
    $preflightAssetIndex++
    $incompleteHub = Join-Path $testRoot "incomplete-source-$preflightAssetIndex"
    $incompleteKit = Join-Path $incompleteHub "mathsecr-paper-builder-kit"
    New-Item -ItemType Directory -Force -Path $incompleteKit | Out-Null
    Copy-Item -Path (Join-Path $kitRoot "*") -Destination $incompleteKit -Recurse -Force

    $missingSourceAsset = Join-Path $incompleteKit $missingRelativeAsset
    $resolvedMissingSourceAsset = [System.IO.Path]::GetFullPath($missingSourceAsset)
    $resolvedIncompleteKit = [System.IO.Path]::GetFullPath($incompleteKit).TrimEnd('\')
    if (-not $resolvedMissingSourceAsset.StartsWith($resolvedIncompleteKit + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing synthetic package-asset removal outside incomplete kit: $resolvedMissingSourceAsset"
    }
    Remove-Item -LiteralPath $resolvedMissingSourceAsset -Force

    $preflightTargetProject = Join-Path $testRoot "preflight-target-$preflightAssetIndex"
    $preflightTargetCodex = Join-Path $testRoot "preflight-codex-$preflightAssetIndex"
    $preflightTargetKit = Join-Path $preflightTargetProject "mathsecr-paper-builder-kit"
    New-Item -ItemType Directory -Force -Path $preflightTargetKit | Out-Null
    New-Item -ItemType Directory -Force -Path $preflightTargetCodex | Out-Null
    $preflightSentinel = Join-Path $preflightTargetKit "preserve-before-preflight.txt"
    [System.IO.File]::WriteAllText($preflightSentinel, "must survive missing-package preflight", (New-Object System.Text.UTF8Encoding($false)))

    $incompleteInstaller = Join-Path $incompleteKit "scripts\install.ps1"
    $preflightFailure = Invoke-ContractProcess "missing new package asset preflight $preflightAssetIndex" ($commonPrefix + @(
      $incompleteInstaller,
      "-ProjectRoot", $preflightTargetProject,
      "-CodexHome", $preflightTargetCodex,
      "-EvidenceRoot", $EvidenceRoot,
      "-Force"
    )) $false
    $preflightFailureText = $preflightFailure.Output -join "`n"
    if (-not $preflightFailureText.Contains("Package asset check failed") -or
        -not $preflightFailureText.Contains($resolvedMissingSourceAsset)) {
      throw "Missing package asset preflight did not identify the exact absent asset: $resolvedMissingSourceAsset"
    }
    if (-not (Test-Path -LiteralPath $preflightSentinel -PathType Leaf)) {
      throw "Missing package asset preflight mutated the existing target before rejection."
    }
    if ((Test-Path -LiteralPath (Join-Path $preflightTargetProject "AGENTS.md")) -or
        (Test-Path -LiteralPath (Join-Path $preflightTargetCodex "skills\mathsecr-paper-builder\SKILL.md"))) {
      throw "Missing package asset preflight installed files before rejecting the incomplete source."
    }
  }

  $manifestPathCases = @(
    @{ Name = "rooted"; ArtifactPath = "C:\mathsecr-pdf-segmentation-escape.png"; ErrorMarker = "non-relative artifact path" },
    @{ Name = "parent-escape"; ArtifactPath = "..\escape.png"; ErrorMarker = "escapes its fixture root" }
  )
  $manifestPathIndex = 0
  foreach ($manifestPathCase in $manifestPathCases) {
    $manifestPathIndex++
    $malformedHub = Join-Path $testRoot "malformed-manifest-source-$manifestPathIndex"
    $malformedKit = Join-Path $malformedHub "mathsecr-paper-builder-kit"
    New-Item -ItemType Directory -Force -Path $malformedKit | Out-Null
    Copy-Item -Path (Join-Path $kitRoot "*") -Destination $malformedKit -Recurse -Force

    $malformedManifestPath = Join-Path $malformedKit "test-fixtures\pdf-segmentation\segmentation-corpus-2026-07-31.json"
    $malformedManifest = Get-Content -LiteralPath $malformedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $malformedManifest.artifacts[0].path = [string]$manifestPathCase.ArtifactPath
    $malformedManifestJson = $malformedManifest | ConvertTo-Json -Depth 40
    [System.IO.File]::WriteAllText($malformedManifestPath, $malformedManifestJson, (New-Object System.Text.UTF8Encoding($false)))

    $manifestTargetProject = Join-Path $testRoot "manifest-preflight-target-$manifestPathIndex"
    $manifestTargetCodex = Join-Path $testRoot "manifest-preflight-codex-$manifestPathIndex"
    $manifestTargetKit = Join-Path $manifestTargetProject "mathsecr-paper-builder-kit"
    New-Item -ItemType Directory -Force -Path $manifestTargetKit | Out-Null
    New-Item -ItemType Directory -Force -Path $manifestTargetCodex | Out-Null
    $manifestSentinel = Join-Path $manifestTargetKit "preserve-before-manifest-preflight.txt"
    [System.IO.File]::WriteAllText($manifestSentinel, "must survive malformed-manifest preflight", (New-Object System.Text.UTF8Encoding($false)))

    $malformedInstaller = Join-Path $malformedKit "scripts\install.ps1"
    $manifestFailure = Invoke-ContractProcess "malformed manifest path preflight $($manifestPathCase.Name)" ($commonPrefix + @(
      $malformedInstaller,
      "-ProjectRoot", $manifestTargetProject,
      "-CodexHome", $manifestTargetCodex,
      "-EvidenceRoot", $EvidenceRoot,
      "-Force"
    )) $false
    $manifestFailureText = $manifestFailure.Output -join "`n"
    if (-not $manifestFailureText.Contains([string]$manifestPathCase.ErrorMarker)) {
      throw "Malformed manifest preflight '$($manifestPathCase.Name)' did not report '$($manifestPathCase.ErrorMarker)'."
    }
    if (-not (Test-Path -LiteralPath $manifestSentinel -PathType Leaf)) {
      throw "Malformed manifest preflight '$($manifestPathCase.Name)' mutated the existing target before rejection."
    }
    if ((Test-Path -LiteralPath (Join-Path $manifestTargetProject "AGENTS.md")) -or
        (Test-Path -LiteralPath (Join-Path $manifestTargetCodex "skills\mathsecr-paper-builder\SKILL.md"))) {
      throw "Malformed manifest preflight '$($manifestPathCase.Name)' installed files before rejection."
    }
  }

  $installedAgents = Get-Content -LiteralPath (Join-Path $targetProject "AGENTS.md") -Raw
  if ($installedAgents -match "C:\\Users\\[^\\\r\n]+") {
    throw "installed AGENTS.md contains a user-specific absolute Windows path"
  }
  if ($installedAgents -notlike "*Codex home*") {
    throw "installed AGENTS.md lacks portable Codex home wording"
  }
  if (-not $installedAgents.Contains('artifact=<path>; sha256=<64 hex>; identity=<구체 설명>')) {
    throw "installed AGENTS.md lacks the card/visual identity fallback evidence contract"
  }
  foreach ($fallbackMarker in @("ProjectRoot 내부 상대 경로", "실제 파일이 존재", "SHA-256과 일치")) {
    if (-not $installedAgents.Contains($fallbackMarker)) {
      throw "installed AGENTS.md lacks the card/visual fallback artifact check: $fallbackMarker"
    }
  }

  $installedPrompt = Get-Content -LiteralPath (Join-Path $targetProject "mathsecr-paper-builder-kit\prompts\start-prompt.md") -Raw
  $canonicalAsideReplHardStop = 'ASIDE_REPL_HARD_STOP: If Aside REPL is unavailable or cannot attach to and verify the live paper, report `차단`. Do not switch that session to the Codex in-app Browser, Chrome, an extension, or Computer Use.'
  if (-not $installedPrompt.Contains($canonicalAsideReplHardStop)) {
    throw "installed start prompt lacks the non-Aside-REPL fallback hard stop"
  }

  $targetAgentsPath = Join-Path $targetProject "AGENTS.md"
  $targetAgentsText = Get-Content -LiteralPath $targetAgentsPath -Raw
  $lfOnlyAgents = ($targetAgentsText -replace "`r`n", "`n") -replace "`r", "`n"
  [System.IO.File]::WriteAllText($targetAgentsPath, $lfOnlyAgents, (New-Object System.Text.UTF8Encoding($false)))

  $checkResult = Invoke-ContractProcess "installed sync check" ($commonPrefix + @(
    $checker,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot
  )) $true
  $checkText = $checkResult.Output -join "`n"
  if ($checkText -notlike "*SYNTHETIC_SKILL_VALIDATOR_PASS*" -or $checkText -notlike "*Installed skill structure validation PASS.*") {
    throw "CheckOnly did not execute the installed skill structure validator"
  }

  $obsoleteTargetFile = Join-Path $targetProject "mathsecr-paper-builder-kit\prompts\obsolete_prompt.md"
  [System.IO.File]::WriteAllText($obsoleteTargetFile, "obsolete target-only file", (New-Object System.Text.UTF8Encoding($false)))
  $extraFileResult = Invoke-ContractProcess "target-only support file check" ($commonPrefix + @(
    $checker,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot
  )) $false
  if (-not ($extraFileResult.Output -join "`n").Contains("Extra: [prompts\obsolete_prompt.md]")) {
    throw "CheckOnly did not identify the exact target-only support file"
  }

  $forceRepairResult = Invoke-ContractProcess "force repair target-only support file" ($commonPrefix + @(
    $installer,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot,
    "-Force"
  )) $true
  if (Test-Path -LiteralPath $obsoleteTargetFile) {
    throw "-Force reinstall left the target-only obsolete support file in place"
  }
  if (-not ($forceRepairResult.Output -join "`n").Contains($obsoleteTargetFile)) {
    throw "-Force reinstall did not print the deleted support file's absolute path"
  }
  $postRepairCheckResult = Invoke-ContractProcess "post-force repair check" ($commonPrefix + @(
    $checker,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot
  )) $true

  $obsoleteSkillFile = Join-Path $targetCodexHome "skills\mathsecr-paper-builder\references\obsolete.md"
  $obsoleteSkillScript = Join-Path $targetCodexHome "skills\mathsecr-paper-builder\scripts\obsolete.ps1"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $obsoleteSkillFile) | Out-Null
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $obsoleteSkillScript) | Out-Null
  [System.IO.File]::WriteAllText($obsoleteSkillFile, "obsolete target-only skill file", (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText($obsoleteSkillScript, "# obsolete target-only skill script", (New-Object System.Text.UTF8Encoding($false)))
  $extraSkillFileResult = Invoke-ContractProcess "target-only installed skill file check" ($commonPrefix + @(
    $checker,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot
  )) $false
  if (-not ($extraSkillFileResult.Output -join "`n").Contains("references\obsolete.md")) {
    throw "CheckOnly did not identify the exact target-only installed skill file"
  }
  if (-not ($extraSkillFileResult.Output -join "`n").Contains("scripts\obsolete.ps1")) {
    throw "CheckOnly did not identify the target-only installed skill script"
  }

  $forceSkillRepairResult = Invoke-ContractProcess "force repair target-only installed skill file" ($commonPrefix + @(
    $installer,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot,
    "-Force"
  )) $true
  if (Test-Path -LiteralPath $obsoleteSkillFile) {
    throw "-Force reinstall left the target-only obsolete installed skill file in place"
  }
  if (Test-Path -LiteralPath $obsoleteSkillScript) {
    throw "-Force reinstall left the target-only obsolete installed skill script in place"
  }
  $forceSkillRepairText = $forceSkillRepairResult.Output -join "`n"
  foreach ($deletedSkillPath in @($obsoleteSkillFile, $obsoleteSkillScript)) {
    if (-not $forceSkillRepairText.Contains($deletedSkillPath)) {
      throw "-Force reinstall did not print the deleted installed skill path: $deletedSkillPath"
    }
  }
  $postSkillRepairCheckResult = Invoke-ContractProcess "post-force installed skill repair check" ($commonPrefix + @(
    $checker,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot
  )) $true

  Set-SyntheticSkillValidator $syntheticSkillValidator $false
  $validatorFailureResult = Invoke-ContractProcess "installed skill validator failure" ($commonPrefix + @(
    $checker,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot
  )) $false
  Set-SyntheticSkillValidator $syntheticSkillValidator $true

  Add-Content -LiteralPath (Join-Path $targetProject "mathsecr-paper-builder-kit\prompts\start-prompt.md") -Value "synthetic support-kit drift"
  $driftResult = Invoke-ContractProcess "support-kit drift check" ($commonPrefix + @(
    $checker,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $EvidenceRoot
  )) $false

  $missingRootResult = Invoke-ContractProcess "missing-root check" ($commonPrefix + @(
    $checker,
    "-ProjectRoot", $missingProject,
    "-CodexHome", $missingCodexHome,
    "-EvidenceRoot", $EvidenceRoot
  )) $false

  $missingAssetResult = Invoke-ContractProcess "missing-package-asset check" ($commonPrefix + @(
    $checker,
    "-ProjectRoot", $targetProject,
    "-CodexHome", $targetCodexHome,
    "-EvidenceRoot", $missingEvidence
  )) $false

  $filesystemRoot = [System.IO.Path]::GetPathRoot($targetCodexHome)
  $filesystemRootGuardResult = Invoke-ContractProcess "filesystem-root installed-skill cleanup guard" ($commonPrefix + @(
    $installer,
    "-ProjectRoot", $safetyProject,
    "-CodexHome", $filesystemRoot,
    "-EvidenceRoot", $EvidenceRoot,
    "-Force"
  )) $false
  $filesystemRootGuardText = $filesystemRootGuardResult.Output -join "`n"
  if ($filesystemRootGuardText -notlike "*Refusing installed-skill cleanup when CodexHome is a filesystem root*") {
    throw "filesystem-root safety test failed for the installed-skill cleanup guard"
  }
  if ($filesystemRootGuardText -like "*Remove obsolete skill file*") {
    throw "filesystem-root safety test observed an installed-skill deletion before rejection"
  }

  Write-Host "INSTALL_CONTRACT_TEST: PASS"
  Write-Host "clean_install_exit=$($installResult.ExitCode) installed_check_exit=$($checkResult.ExitCode)"
  Write-Host "line_ending_normalization=PASS support_drift_exit=$($driftResult.ExitCode)"
  Write-Host "extra_file_exit=$($extraFileResult.ExitCode) force_repair_exit=$($forceRepairResult.ExitCode) post_repair_check_exit=$($postRepairCheckResult.ExitCode)"
  Write-Host "extra_skill_file_exit=$($extraSkillFileResult.ExitCode) force_skill_repair_exit=$($forceSkillRepairResult.ExitCode) post_skill_repair_check_exit=$($postSkillRepairCheckResult.ExitCode)"
  Write-Host "force_delete_path_logging=PASS"
  Write-Host "check_skill_validator=PASS validator_failure_exit=$($validatorFailureResult.ExitCode)"
  Write-Host "missing_root_exit=$($missingRootResult.ExitCode) missing_asset_exit=$($missingAssetResult.ExitCode)"
  Write-Host "new_asset_preflight_rejections=$($preflightAssetCases.Count)"
  Write-Host "manifest_path_preflight_rejections=$($manifestPathCases.Count)"
  Write-Host "installed_failed_problem_report_exit=$($installedCropReportResult.ExitCode)"
  Write-Host "installed_search_attempt_contract_exit=$($installedSearchAttemptResult.ExitCode)"
  Write-Host "installed_re0_memo_contract_exit=$($installedRe0MemoResult.ExitCode)"
  Write-Host "installed_ground_truth_contract_exit=$($installedGroundTruthResult.ExitCode)"
  Write-Host "installed_regression_evidence_contract_exit=$($installedRegressionEvidenceResult.ExitCode)"
  Write-Host "runtime_capability_preflight_rejections=1 sentinel_preserved=true"
  Write-Host "filesystem_root_guard_exit=$($filesystemRootGuardResult.ExitCode)"
  Write-Host "installed_support_files=$($requiredFiles.Count) installed_evidence_files=$($requiredEvidenceNames.Count)"
} finally {
  $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
  $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing cleanup outside the system temp directory: $resolvedTestRoot"
  }
  if (Test-Path -LiteralPath $resolvedTestRoot) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
  Write-Host "temp_cleanup=PASS"
}
