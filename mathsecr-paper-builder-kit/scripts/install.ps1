param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$CodexHome = $env:CODEX_HOME,
  [string]$EvidenceRoot,
  [switch]$CheckOnly,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Item {
  param([string]$Name, [string]$Status, [string]$Detail = "")
  $line = "{0,-32} {1,-10} {2}" -f $Name, $Status, $Detail
  Write-Host $line
}

function Test-Command {
  param([string]$Command)
  $cmd = Get-Command $Command -ErrorAction SilentlyContinue
  if ($cmd) {
    if ($cmd.Source) { return $cmd.Source }
    return $cmd.Path
  }
  return $null
}

function Invoke-PythonRuntimeCapabilityPreflight {
  param([string]$PythonExecutable)

  $requiredModules = "PIL (Pillow), reportlab, pypdf"
  if (-not $PythonExecutable) {
    throw "Python runtime capability preflight failed: Python was not found on PATH. The failed-problem PDF report is mandatory for per-problem failures and requires imports $requiredModules. Install Python with these packages and retry."
  }

$probeCode = @'
import importlib

required = ('PIL', 'reportlab', 'pypdf')
missing = []
for name in required:
    try:
        importlib.import_module(name)
    except Exception as exc:
        missing.append(f'{name}: {exc}')
if missing:
    print('MATHSECR_RUNTIME_CAPABILITY_MISSING')
    for item in missing:
        print(item)
    raise SystemExit(3)
print('MATHSECR_RUNTIME_CAPABILITY_PASS')
'@

  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $probeOutput = & $PythonExecutable -c $probeCode 2>&1
    $probeExitCode = $LASTEXITCODE
  } catch {
    $probeOutput = @($_.Exception.Message)
    $probeExitCode = 1
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }

  $probeText = @($probeOutput | ForEach-Object { [string]$_ }) -join "`n"
  if ($probeExitCode -ne 0 -or $probeText -notlike "*MATHSECR_RUNTIME_CAPABILITY_PASS*") {
    $detail = $probeText.Trim()
    if (-not $detail) { $detail = "interpreter probe exited with code $probeExitCode" }
    throw "Python runtime capability preflight failed for '$PythonExecutable'. The failed-problem PDF report requires imports $requiredModules. Install the missing packages for this interpreter and retry. Probe detail: $detail"
  }

  Write-Item "Python report runtime" "OK" "$PythonExecutable (imports: $requiredModules)"
  return $PythonExecutable
}

function Invoke-SkillStructureValidator {
  param([string]$ValidatorPath, [string]$SkillDirectory, [string]$PythonExecutable)
  if (Test-Path -LiteralPath $ValidatorPath -PathType Leaf) {
    if (-not $PythonExecutable) {
      throw "Installed skill structure validator exists but the validated Python runtime is unavailable: $ValidatorPath"
    }
    Write-Host ""
    Write-Host "Validating installed skill structure..."
    & $PythonExecutable $ValidatorPath $SkillDirectory
    if ($LASTEXITCODE -ne 0) {
      throw "Installed skill structure validator failed with exit code $LASTEXITCODE"
    }
    Write-Host "Installed skill structure validation PASS."
  } else {
    Write-Host ""
    Write-Host "Skill structure validation skipped: validator not available."
  }
}

function Test-SamePath {
  param([string]$Left, [string]$Right)
  $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd('\')
  $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd('\')
  return [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativeChildPath {
  param([string]$Root, [string]$Child)
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
  $childFull = [System.IO.Path]::GetFullPath($Child)
  $prefix = $rootFull + '\'
  if (-not $childFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Path is outside the expected root: $childFull (root: $rootFull)"
  }
  return $childFull.Substring($prefix.Length)
}

function Assert-TargetKitRootSafety {
  param([string]$ProjectPath, [string]$TargetPath)
  $projectOriginal = [System.IO.Path]::GetFullPath($ProjectPath)
  $projectRootPath = [System.IO.Path]::GetPathRoot($projectOriginal)
  if ([string]::Equals($projectOriginal.TrimEnd('\'), $projectRootPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing support-kit cleanup when ProjectRoot is a filesystem root: $projectOriginal"
  }
  $projectFull = $projectOriginal.TrimEnd('\')
  $targetFull = [System.IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
  $expectedTarget = [System.IO.Path]::GetFullPath((Join-Path $projectFull "mathsecr-paper-builder-kit")).TrimEnd('\')
  if (-not [string]::Equals($targetFull, $expectedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing support-kit cleanup outside the exact target path: $targetFull"
  }
  if (-not $targetFull.StartsWith($projectFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing support-kit cleanup outside ProjectRoot: $targetFull"
  }
  if ((Test-Path -LiteralPath $targetFull) -and -not (Test-Path -LiteralPath $targetFull -PathType Container)) {
    throw "TargetKitRoot exists but is not a directory: $targetFull"
  }
}

function Assert-TargetSkillRootSafety {
  param([string]$CodexHomePath, [string]$TargetPath)
  $codexOriginal = [System.IO.Path]::GetFullPath($CodexHomePath)
  $codexRootPath = [System.IO.Path]::GetPathRoot($codexOriginal)
  if ([string]::Equals($codexOriginal.TrimEnd('\'), $codexRootPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing installed-skill cleanup when CodexHome is a filesystem root: $codexOriginal"
  }
  $codexFull = $codexOriginal.TrimEnd('\')
  $targetFull = [System.IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
  $expectedTarget = [System.IO.Path]::GetFullPath((Join-Path $codexFull "skills\mathsecr-paper-builder")).TrimEnd('\')
  if (-not [string]::Equals($targetFull, $expectedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing installed-skill cleanup outside the exact target path: $targetFull"
  }
  if (-not $targetFull.StartsWith($codexFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing installed-skill cleanup outside CodexHome: $targetFull"
  }
  if ((Test-Path -LiteralPath $targetFull) -and -not (Test-Path -LiteralPath $targetFull -PathType Container)) {
    throw "TargetSkillDir exists but is not a directory: $targetFull"
  }
}

function Remove-ObsoleteTargetKitFiles {
  param([string]$SourceRoot, [string]$TargetRoot, [string]$ProjectPath)
  Assert-TargetKitRootSafety $ProjectPath $TargetRoot
  if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
    return
  }

  $targetRootItem = Get-Item -LiteralPath $TargetRoot -Force
  if (($targetRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing support-kit cleanup because TargetKitRoot is a reparse point: $TargetRoot"
  }
  $reparsePoints = @(Get-ChildItem -LiteralPath $TargetRoot -Force -Recurse | Where-Object {
    ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
  })
  if ($reparsePoints.Count -gt 0) {
    throw "Refusing support-kit cleanup because the target contains a reparse point: $($reparsePoints[0].FullName)"
  }

  $sourceRelativeFiles = @{}
  foreach ($sourceFile in Get-ChildItem -LiteralPath $SourceRoot -Force -File -Recurse) {
    $relativePath = Get-RelativeChildPath $SourceRoot $sourceFile.FullName
    $sourceRelativeFiles[$relativePath] = $true
  }

  $targetPrefix = [System.IO.Path]::GetFullPath($TargetRoot).TrimEnd('\') + '\'
  foreach ($targetFile in Get-ChildItem -LiteralPath $TargetRoot -Force -File -Recurse) {
    $relativePath = Get-RelativeChildPath $TargetRoot $targetFile.FullName
    if (-not $sourceRelativeFiles.ContainsKey($relativePath)) {
      $targetFileFull = [System.IO.Path]::GetFullPath($targetFile.FullName)
      if (-not $targetFileFull.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a file outside TargetKitRoot: $targetFileFull"
      }
      Remove-Item -LiteralPath $targetFileFull -Force
      Write-Item "Remove obsolete kit file" "OK" $targetFileFull
    }
  }
}

function Remove-ObsoleteTargetSkillFiles {
  param([string]$SourceRoot, [string]$TargetRoot, [string]$CodexHomePath)
  Assert-TargetSkillRootSafety $CodexHomePath $TargetRoot
  if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
    return
  }

  foreach ($ancestorPath in @(
    $CodexHomePath,
    (Join-Path $CodexHomePath "skills"),
    $TargetRoot
  )) {
    if (Test-Path -LiteralPath $ancestorPath) {
      $ancestorItem = Get-Item -LiteralPath $ancestorPath -Force
      if (($ancestorItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing installed-skill cleanup because the path contains a reparse point: $ancestorPath"
      }
    }
  }
  $reparsePoints = @(Get-ChildItem -LiteralPath $TargetRoot -Force -Recurse | Where-Object {
    ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
  })
  if ($reparsePoints.Count -gt 0) {
    throw "Refusing installed-skill cleanup because the target contains a reparse point: $($reparsePoints[0].FullName)"
  }

  $sourceRelativeFiles = @{}
  foreach ($sourceFile in Get-ChildItem -LiteralPath $SourceRoot -Force -File -Recurse) {
    $relativePath = Get-RelativeChildPath $SourceRoot $sourceFile.FullName
    $sourceRelativeFiles[$relativePath] = $true
  }

  $targetPrefix = [System.IO.Path]::GetFullPath($TargetRoot).TrimEnd('\') + '\'
  foreach ($targetFile in Get-ChildItem -LiteralPath $TargetRoot -Force -File -Recurse) {
    $relativePath = Get-RelativeChildPath $TargetRoot $targetFile.FullName
    if (-not $sourceRelativeFiles.ContainsKey($relativePath)) {
      $targetFileFull = [System.IO.Path]::GetFullPath($targetFile.FullName)
      if (-not $targetFileFull.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a file outside TargetSkillDir: $targetFileFull"
      }
      Remove-Item -LiteralPath $targetFileFull -Force
      Write-Item "Remove obsolete skill file" "OK" $targetFileFull
    }
  }
}

function Resolve-EvidenceRoot {
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

function Assert-FileContentEqual {
  param([string]$Name, [string]$ExpectedPath, [string]$ActualPath)
  if (-not (Test-Path -LiteralPath $ActualPath)) {
    throw "[$Name] missing installed file: $ActualPath"
  }
  $textExtensions = @(".html", ".json", ".md", ".ps1", ".txt")
  $extension = [System.IO.Path]::GetExtension($ExpectedPath).ToLowerInvariant()
  if ($textExtensions -contains $extension) {
    $expectedText = Get-Content -LiteralPath $ExpectedPath -Raw
    $actualText = Get-Content -LiteralPath $ActualPath -Raw
    $normalizedExpected = ($expectedText -replace "`r`n", "`n") -replace "`r", "`n"
    $normalizedActual = ($actualText -replace "`r`n", "`n") -replace "`r", "`n"
    $equal = $normalizedExpected -ceq $normalizedActual
  } else {
    $expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ExpectedPath).Hash
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ActualPath).Hash
    $equal = $expectedHash -ceq $actualHash
  }
  if (-not $equal) {
    throw "[$Name] installed file is out of sync: $ActualPath"
  }
}

$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$HubRoot = Split-Path -Parent $KitRoot
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not $CodexHome) {
  $CodexHome = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex"
}
$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$EvidenceRoot = Resolve-EvidenceRoot $EvidenceRoot $HubRoot

$SourceAgents = Join-Path $KitRoot "AGENTS.md"
$SourceSkillDir = Join-Path $KitRoot "skills\mathsecr-paper-builder"
$SourceSkill = Join-Path $SourceSkillDir "SKILL.md"
$SourcePrompt = Join-Path $KitRoot "prompts\start-prompt.md"
$SourceReusablePrompt = Join-Path $KitRoot "prompts\mathsecr_new_paper_prompt.md"
$SourceValidator = Join-Path $KitRoot "scripts\validate_mathsecr_docs.ps1"
$SourceRe0MemoTest = Join-Path $KitRoot "scripts\test_re0_memo.ps1"
$SourceRe0MemoFixture = Join-Path $KitRoot "test-fixtures\lessons\re0-memo-registry.json"
$SourceGroundTruthContract = Join-Path $KitRoot "scripts\ground_truth_contract.ps1"
$SourceGroundTruthTest = Join-Path $KitRoot "scripts\test_ground_truth_contract.ps1"
$SourceGroundTruthFixture = Join-Path $KitRoot "test-fixtures\evaluation\ground-truth-claims.json"
$SourceRegressionEvidenceContract = Join-Path $KitRoot "scripts\regression_evidence_contract.ps1"
$SourceRegressionEvidenceTest = Join-Path $KitRoot "scripts\test_regression_evidence_contract.ps1"
$SourceSearchCharacterizationTest = Join-Path $KitRoot "scripts\test_search_characterization.ps1"
$SourceSearchCharacterizationFixture = Join-Path $KitRoot "test-fixtures\search-characterization\phrase-stability-2026-07-31.json"
$SourceIdleSearchCharacterizationTest = Join-Path $KitRoot "scripts\test_idle_search_characterization.ps1"
$SourceIdleSearchCharacterizationFixture = Join-Path $KitRoot "test-fixtures\search-characterization\idle-first-query-2026-07-31.json"
$SourceSelectionJournalScript = Join-Path $KitRoot "scripts\selection_journal.ps1"
$SourceSelectionJournalTest = Join-Path $KitRoot "scripts\test_selection_journal.ps1"
$SourceSelectionJournalFixture = Join-Path $KitRoot "test-fixtures\selection-journal\cases.json"
$SourcePdfSegmentationTest = Join-Path $KitRoot "scripts\test_pdf_segmentation.ps1"
$SourcePdfSegmentationFixtureRoot = Join-Path $KitRoot "test-fixtures\pdf-segmentation"
$SourcePdfSegmentationManifest = Join-Path $SourcePdfSegmentationFixtureRoot "segmentation-corpus-2026-07-31.json"
$SourceFixtureRoot = Join-Path $KitRoot "test-fixtures\docs"
$TargetAgents = Join-Path $ProjectRoot "AGENTS.md"
$TargetKitRoot = Join-Path $ProjectRoot "mathsecr-paper-builder-kit"
$TargetSkillDir = Join-Path $CodexHome "skills\mathsecr-paper-builder"
$TargetSkill = Join-Path $TargetSkillDir "SKILL.md"
$TargetEvidenceRoot = Join-Path $ProjectRoot ".omo\evidence"

$RequiredFixtureNames = @(
  "mathsecr_feature_exploration.md",
  "mathsecr_card_inventory_2000.json",
  "gajwa2_candidate_summary.json",
  "mathsecr_search_feature_live_trace_2026-07-29.txt",
  "mathsecr_db_inference_search_matrix_2026-07-29.json",
  "mathsecr_db_inference_live_trace_2026-07-29.txt"
)
$RequiredEvidenceNames = @(
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
if (Test-Path -LiteralPath $SourceRe0MemoFixture -PathType Leaf) {
  try {
    $re0MemoRegistry = Get-Content -LiteralPath $SourceRe0MemoFixture -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    throw "Re0-memo registry is not valid JSON: $SourceRe0MemoFixture. $($_.Exception.Message)"
  }
  foreach ($evidencePath in @($re0MemoRegistry.lessons | ForEach-Object { @($_.evidence) })) {
    if ($evidencePath -isnot [string]) {
      throw "Re0-memo registry contains a non-string evidence path."
    }
    $normalizedEvidencePath = ([string]$evidencePath).Replace('\', '/')
    if ($normalizedEvidencePath -cnotmatch '^\.omo/evidence/([^/]+)$') {
      throw "Re0-memo registry evidence must be a direct .omo/evidence child: $evidencePath"
    }
    $RequiredEvidenceNames += [string]$Matches[1]
  }
  $RequiredEvidenceNames = @($RequiredEvidenceNames | Sort-Object -Unique)
}

# These are offline contract assets copied with the support kit.  The PDF
# source files named by the corpus live outside the repository and are not a
# package prerequisite; the manifest and every packaged render are.
$RequiredKitAssetRelativePaths = @(
  "docs\db_inference_contract.md",
  "scripts\run_validations.ps1",
  "scripts\search_attempt_contract.ps1",
  "scripts\test_search_attempt_contract.ps1",
  "scripts\search_query_plan.ps1",
  "scripts\test_search_query_plan.ps1",
  "scripts\search_observation.js",
  "scripts\search_observation_contract.ps1",
  "scripts\test_search_observation.ps1",
  "scripts\test_filter_collector.cjs",
  "scripts\test_filter_contract.ps1",
  "test-fixtures\filter-collector\filter-adapter.synthetic.json",
  "scripts\body_comparison_contract.ps1",
  "scripts\test_body_comparison_contract.ps1",
  "scripts\read_contract_json.ps1",
  "scripts\validate_selection_snapshot.ps1",
  "scripts\prepare_selection_evidence.ps1",
  "scripts\test_prepare_selection_evidence.ps1",
  "scripts\aside_preflight.ps1",
  "scripts\check_aside_repl.ps1",
  "scripts\test_aside_preflight.ps1",
  "scripts\production_validation.ps1",
  "scripts\validate_production_step.ps1",
  "scripts\test_production_validation.ps1",
  "scripts\test_partial_save_phases.ps1",
  "docs\production_validation.md",
  "test-fixtures\production-validation\source-roster.json",
  "docs\selection_evidence_preparation.md",
  "docs\search_preparation_and_selection_evidence.md",
  "docs\search_query_plan.md",
  "docs\search_observation_contract.md",
  "test-fixtures\search-query-plan\source-order-input.json",
  "test-fixtures\search-observation\simulator-adapter.json",
  "test-fixtures\search-observation\collector_dom_test.js",
  "test-fixtures\body-comparison\synthetic_selection_test_support.ps1",
  "test-fixtures\search-attempts\goguk2-mid-q2.json",
  "scripts\test_re0_memo.ps1",
  "test-fixtures\lessons\re0-memo-registry.json",
  "scripts\ground_truth_contract.ps1",
  "scripts\test_ground_truth_contract.ps1",
  "test-fixtures\evaluation\ground-truth-claims.json",
  "scripts\regression_evidence_contract.ps1",
  "scripts\test_regression_evidence_contract.ps1",
  "scripts\db_inference.ps1",
  "scripts\test_db_inference.ps1",
  "test-fixtures\db-inference\cases.json",
  "scripts\selection_journal.ps1",
  "scripts\test_selection_journal.ps1",
  "test-fixtures\selection-journal\cases.json",
  "scripts\create_failed_problem_report.py",
  "scripts\test_failed_problem_report.ps1",
  "scripts\test_pdf_segmentation.ps1",
  "test-fixtures\pdf-segmentation\segmentation-corpus-2026-07-31.json"
)
if (Test-Path -LiteralPath $SourcePdfSegmentationManifest -PathType Leaf) {
  try {
    $pdfSegmentationManifest = Get-Content -LiteralPath $SourcePdfSegmentationManifest -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    throw "PDF segmentation manifest is not valid JSON: $SourcePdfSegmentationManifest. $($_.Exception.Message)"
  }
  $pdfFixtureRootFull = [System.IO.Path]::GetFullPath($SourcePdfSegmentationFixtureRoot).TrimEnd('\')
  foreach ($artifact in @($pdfSegmentationManifest.artifacts)) {
    $relativeArtifactPath = [string]$artifact.path
    if ([string]::IsNullOrWhiteSpace($relativeArtifactPath) -or [System.IO.Path]::IsPathRooted($relativeArtifactPath)) {
      throw "PDF segmentation manifest contains a non-relative artifact path: $relativeArtifactPath"
    }
    $artifactFull = [System.IO.Path]::GetFullPath((Join-Path $SourcePdfSegmentationFixtureRoot $relativeArtifactPath))
    if (-not $artifactFull.StartsWith($pdfFixtureRootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "PDF segmentation manifest artifact escapes its fixture root: $relativeArtifactPath"
    }
    $RequiredKitAssetRelativePaths += Join-Path "test-fixtures\pdf-segmentation" $relativeArtifactPath
  }
}
if (Test-Path -LiteralPath $SourceGroundTruthFixture -PathType Leaf) {
  try {
    $groundTruthRegistry = Get-Content -LiteralPath $SourceGroundTruthFixture -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    throw "Ground-truth registry is not valid JSON: $SourceGroundTruthFixture. $($_.Exception.Message)"
  }
  $declaredGroundTruthPaths = @([string]$groundTruthRegistry.contract.runner)
  foreach ($claim in @($groundTruthRegistry.claims)) {
    $declaredGroundTruthPaths += [string]$claim.evaluator
    $declaredGroundTruthPaths += @($claim.designArtifacts | ForEach-Object { [string]$_ })
    $declaredGroundTruthPaths += @($claim.oracleArtifacts | ForEach-Object { [string]$_.path })
  }
  $hubRootFull = [System.IO.Path]::GetFullPath($HubRoot).TrimEnd('\')
  $kitRootFull = [System.IO.Path]::GetFullPath($KitRoot).TrimEnd('\')
  foreach ($declaredPath in @($declaredGroundTruthPaths | Sort-Object -Unique)) {
    $normalizedDeclaredPath = ([string]$declaredPath).Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($normalizedDeclaredPath) -or
        [System.IO.Path]::IsPathRooted($normalizedDeclaredPath) -or
        @($normalizedDeclaredPath -split '\\+' | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0) {
      throw "Ground-truth registry contains an unsafe ProjectRoot-relative asset path: $declaredPath"
    }
    $declaredFullPath = [System.IO.Path]::GetFullPath((Join-Path $HubRoot $normalizedDeclaredPath))
    if (-not $declaredFullPath.StartsWith($hubRootFull + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $declaredFullPath.StartsWith($kitRootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Ground-truth registry asset must stay under the support kit: $declaredPath"
    }
    $RequiredKitAssetRelativePaths += $declaredFullPath.Substring($kitRootFull.Length + 1)
  }
}

$AssertInstalledBundleSync = {
  Assert-FileContentEqual "Root AGENTS sync" $SourceAgents $TargetAgents

  $sourceSkillFiles = @(Get-ChildItem -LiteralPath $SourceSkillDir -Force -File -Recurse)
  $targetSkillFiles = @(Get-ChildItem -LiteralPath $TargetSkillDir -Force -File -Recurse)
  $sourceSkillRelativeFiles = @{}
  foreach ($sourceSkillFile in $sourceSkillFiles) {
    $relativePath = Get-RelativeChildPath $SourceSkillDir $sourceSkillFile.FullName
    $sourceSkillRelativeFiles[$relativePath] = $true
  }
  $targetSkillRelativeFiles = @{}
  foreach ($targetSkillFile in $targetSkillFiles) {
    $relativePath = Get-RelativeChildPath $TargetSkillDir $targetSkillFile.FullName
    $targetSkillRelativeFiles[$relativePath] = $true
  }
  $missingSkillFiles = @($sourceSkillRelativeFiles.Keys | Where-Object { -not $targetSkillRelativeFiles.ContainsKey($_) } | Sort-Object)
  $extraSkillFiles = @($targetSkillRelativeFiles.Keys | Where-Object { -not $sourceSkillRelativeFiles.ContainsKey($_) } | Sort-Object)
  if ($missingSkillFiles.Count -gt 0 -or $extraSkillFiles.Count -gt 0) {
    $missingSummary = ($missingSkillFiles | Select-Object -First 10) -join ", "
    $extraSummary = ($extraSkillFiles | Select-Object -First 10) -join ", "
    throw "Installed skill file set is out of sync. Missing: [$missingSummary] Extra: [$extraSummary]"
  }
  foreach ($sourceSkillFile in $sourceSkillFiles) {
    $relativePath = Get-RelativeChildPath $SourceSkillDir $sourceSkillFile.FullName
    Assert-FileContentEqual "Installed skill sync" $sourceSkillFile.FullName (Join-Path $TargetSkillDir $relativePath)
  }

  $sourceKitFiles = @(Get-ChildItem -LiteralPath $KitRoot -Force -File -Recurse)
  $targetKitFiles = @(Get-ChildItem -LiteralPath $TargetKitRoot -Force -File -Recurse)
  $sourceRelativeFiles = @{}
  foreach ($sourceKitFile in $sourceKitFiles) {
    $relativePath = Get-RelativeChildPath $KitRoot $sourceKitFile.FullName
    $sourceRelativeFiles[$relativePath] = $true
  }
  $targetRelativeFiles = @{}
  foreach ($targetKitFile in $targetKitFiles) {
    $relativePath = Get-RelativeChildPath $TargetKitRoot $targetKitFile.FullName
    $targetRelativeFiles[$relativePath] = $true
  }

  $missingRelativeFiles = @($sourceRelativeFiles.Keys | Where-Object { -not $targetRelativeFiles.ContainsKey($_) } | Sort-Object)
  $extraRelativeFiles = @($targetRelativeFiles.Keys | Where-Object { -not $sourceRelativeFiles.ContainsKey($_) } | Sort-Object)
  if ($missingRelativeFiles.Count -gt 0 -or $extraRelativeFiles.Count -gt 0) {
    $missingSummary = ($missingRelativeFiles | Select-Object -First 10) -join ", "
    $extraSummary = ($extraRelativeFiles | Select-Object -First 10) -join ", "
    throw "Support kit file set is out of sync. Missing: [$missingSummary] Extra: [$extraSummary]"
  }

  foreach ($sourceKitFile in $sourceKitFiles) {
    $relativePath = Get-RelativeChildPath $KitRoot $sourceKitFile.FullName
    $targetKitFile = Join-Path $TargetKitRoot $relativePath
    Assert-FileContentEqual "Support kit sync" $sourceKitFile.FullName $targetKitFile
  }

  foreach ($evidenceName in $RequiredEvidenceNames) {
    Assert-FileContentEqual "Evidence sync" (Join-Path $EvidenceRoot $evidenceName) (Join-Path $TargetEvidenceRoot $evidenceName)
  }
}

Write-Host "MathSecr Paper Builder Kit"
Write-Host "Kit root:      $KitRoot"
Write-Host "Project root:  $ProjectRoot"
Write-Host "Codex home:    $CodexHome"
Write-Host "Evidence root: $EvidenceRoot"
Write-Host ""

Write-Host "Environment checks"
Write-Item "PowerShell" "OK" $PSVersionTable.PSVersion.ToString()
$projectExists = Test-Path -LiteralPath $ProjectRoot
$codexHomeExists = Test-Path -LiteralPath $CodexHome
Write-Item "Project root exists" ($(if ($projectExists) { "OK" } else { "MISSING" })) $ProjectRoot
Write-Item "Codex home exists" ($(if ($codexHomeExists) { "OK" } else { "MISSING" })) $CodexHome

$browserCache = Join-Path $CodexHome "plugins\cache\openai-bundled\browser"
Write-Item "Browser plugin cache" ($(if (Test-Path -LiteralPath $browserCache) { "OK" } else { "CHECK" })) $browserCache

$resolvedPythonCommand = Test-Command "python"
Write-Item "python" ($(if ($resolvedPythonCommand) { "OK" } else { "MISSING" })) ($(if ($resolvedPythonCommand) { $resolvedPythonCommand } else { "not found on PATH" }))
$resolvedPythonCommand = Invoke-PythonRuntimeCapabilityPreflight $resolvedPythonCommand

foreach ($cmd in @("node", "rg", "pdftoppm", "pdftotext")) {
  $found = Test-Command $cmd
  Write-Item $cmd ($(if ($found) { "OK" } else { "OPTIONAL" })) ($(if ($found) { $found } else { "not found on PATH" }))
}

$skillValidator = Join-Path $CodexHome "skills\.system\skill-creator\scripts\quick_validate.py"
Write-Item "Skill validator" ($(if (Test-Path -LiteralPath $skillValidator) { "OK" } else { "OPTIONAL" })) $skillValidator

Write-Host ""
Write-Host "Package files"
$packageMissing = $false
$packageFiles = @(
  @{ Name = "AGENTS.md source"; Path = $SourceAgents },
  @{ Name = "SKILL.md source"; Path = $SourceSkill },
  @{ Name = "start prompt source"; Path = $SourcePrompt },
  @{ Name = "reusable prompt source"; Path = $SourceReusablePrompt },
  @{ Name = "docs validator source"; Path = $SourceValidator },
  @{ Name = "re0-memo registry test source"; Path = $SourceRe0MemoTest },
  @{ Name = "re0-memo registry fixture source"; Path = $SourceRe0MemoFixture },
  @{ Name = "ground-truth contract source"; Path = $SourceGroundTruthContract },
  @{ Name = "ground-truth registry test source"; Path = $SourceGroundTruthTest },
  @{ Name = "ground-truth registry fixture source"; Path = $SourceGroundTruthFixture },
  @{ Name = "regression-evidence contract source"; Path = $SourceRegressionEvidenceContract },
  @{ Name = "regression-evidence test source"; Path = $SourceRegressionEvidenceTest },
  @{ Name = "search characterization test source"; Path = $SourceSearchCharacterizationTest },
  @{ Name = "search characterization fixture source"; Path = $SourceSearchCharacterizationFixture },
  @{ Name = "idle search characterization test source"; Path = $SourceIdleSearchCharacterizationTest },
  @{ Name = "idle search characterization fixture source"; Path = $SourceIdleSearchCharacterizationFixture },
  @{ Name = "selection journal script source"; Path = $SourceSelectionJournalScript },
  @{ Name = "selection journal test source"; Path = $SourceSelectionJournalTest },
  @{ Name = "selection journal fixture source"; Path = $SourceSelectionJournalFixture },
  @{ Name = "PDF segmentation test source"; Path = $SourcePdfSegmentationTest }
)
foreach ($assetRelativePath in @($RequiredKitAssetRelativePaths | Sort-Object -Unique)) {
  $packageFiles += @{ Name = "kit asset $assetRelativePath"; Path = (Join-Path $KitRoot $assetRelativePath) }
}
foreach ($fixtureName in $RequiredFixtureNames) {
  $packageFiles += @{ Name = "fixture $fixtureName"; Path = (Join-Path $SourceFixtureRoot $fixtureName) }
}
foreach ($evidenceName in $RequiredEvidenceNames) {
  $packageFiles += @{ Name = "evidence $evidenceName"; Path = (Join-Path $EvidenceRoot $evidenceName) }
}
foreach ($item in $packageFiles) {
  $exists = Test-Path -LiteralPath $item.Path -PathType Leaf
  Write-Item $item.Name ($(if ($exists) { "OK" } else { "MISSING" })) $item.Path
  if (-not $exists) { $packageMissing = $true }
}
if ($packageMissing) {
  throw "Package asset check failed. Use a full hub checkout or pass -EvidenceRoot with every indexed evidence file."
}
Write-Host "Running source ground-truth registry preflight..."
& $SourceGroundTruthTest -ProjectRoot $HubRoot -Case ValidRegistry

if ($CheckOnly) {
  if (-not $projectExists -or -not $codexHomeExists) {
    throw "CheckOnly requires an existing project root and Codex home."
  }
  Write-Host ""
  Write-Host "Installed files"
  foreach ($item in @(
    @{ Name = "Installed AGENTS.md"; Path = $TargetAgents },
    @{ Name = "Installed kit AGENTS.md"; Path = (Join-Path $TargetKitRoot "AGENTS.md") },
    @{ Name = "Installed kit SKILL.md"; Path = (Join-Path $TargetKitRoot "skills\mathsecr-paper-builder\SKILL.md") },
    @{ Name = "Installed skill"; Path = $TargetSkill }
  )) {
    $exists = Test-Path -LiteralPath $item.Path -PathType Leaf
    Write-Item $item.Name ($(if ($exists) { "OK" } else { "MISSING" })) $item.Path
    if (-not $exists) { throw "Missing installed file: $($item.Path)" }
  }

  & $AssertInstalledBundleSync

  Invoke-SkillStructureValidator $skillValidator $TargetSkillDir $resolvedPythonCommand

  Write-Host ""
  Write-Host "Running project document validator..."
  & $SourceValidator -Scenario All -ProjectRoot $ProjectRoot -CodexHome $CodexHome
  Write-Host "Running re0-memo registry validator..."
  & $SourceRe0MemoTest -ProjectRoot $ProjectRoot -Case ValidRegistry
  Write-Host "Running ground-truth registry validator..."
  & $SourceGroundTruthTest -ProjectRoot $ProjectRoot -Case ValidRegistry
  Write-Host "Running regression-evidence validator..."
  & $SourceRegressionEvidenceTest -ProjectRoot $ProjectRoot -Case ValidReceipt
  Write-Host ""
  Write-Host "CheckOnly PASS: installation exists and is in sync."
  exit 0
}

if (-not $projectExists) {
  New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null
}
if (-not $codexHomeExists) {
  New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
}
if ((Test-Path -LiteralPath $TargetAgents) -and -not $Force) {
  Write-Item "Install AGENTS.md" "SKIP" "exists; validation will require exact sync or rerun with -Force"
} else {
  Copy-Item -LiteralPath $SourceAgents -Destination $TargetAgents -Force
  Write-Item "Install AGENTS.md" "OK" $TargetAgents
}

Assert-TargetSkillRootSafety $CodexHome $TargetSkillDir
if (Test-SamePath $SourceSkillDir $TargetSkillDir) {
  Write-Item "Install skill tree" "IN-PLACE" $TargetSkillDir
} elseif ((Test-Path -LiteralPath $TargetSkillDir -PathType Container) -and -not $Force) {
  Write-Item "Install skill tree" "SKIP" "exists; validation will require exact sync or rerun with -Force"
} else {
  if ($Force) {
    Remove-ObsoleteTargetSkillFiles $SourceSkillDir $TargetSkillDir $CodexHome
  }
  if (-not (Test-Path -LiteralPath $TargetSkillDir)) {
    New-Item -ItemType Directory -Force -Path $TargetSkillDir | Out-Null
  }
  Copy-Item -Path (Join-Path $SourceSkillDir "*") -Destination $TargetSkillDir -Recurse -Force
  Write-Item "Install skill tree" "OK" $TargetSkillDir
}

Assert-TargetKitRootSafety $ProjectRoot $TargetKitRoot
if (Test-SamePath $KitRoot $TargetKitRoot) {
  Write-Item "Install support kit" "IN-PLACE" $TargetKitRoot
} elseif ((Test-Path -LiteralPath $TargetKitRoot) -and -not $Force) {
  Write-Item "Install support kit" "SKIP" "exists; validation will require exact document sync or rerun with -Force"
} else {
  if ($Force) {
    Remove-ObsoleteTargetKitFiles $KitRoot $TargetKitRoot $ProjectRoot
  }
  if (-not (Test-Path -LiteralPath $TargetKitRoot)) {
    New-Item -ItemType Directory -Force -Path $TargetKitRoot | Out-Null
  }
  Copy-Item -Path (Join-Path $KitRoot "*") -Destination $TargetKitRoot -Recurse -Force
  Write-Item "Install support kit" "OK" $TargetKitRoot
}

if (-not (Test-Path -LiteralPath $TargetEvidenceRoot)) {
  New-Item -ItemType Directory -Force -Path $TargetEvidenceRoot | Out-Null
}
foreach ($evidenceName in $RequiredEvidenceNames) {
  $sourceEvidence = Join-Path $EvidenceRoot $evidenceName
  $targetEvidence = Join-Path $TargetEvidenceRoot $evidenceName
  if (Test-SamePath $sourceEvidence $targetEvidence) {
    Write-Item "Install evidence" "IN-PLACE" $evidenceName
  } elseif ((Test-Path -LiteralPath $targetEvidence) -and -not $Force) {
    Write-Item "Install evidence" "SKIP" "$evidenceName; validation will require exact sync or rerun with -Force"
  } else {
    Copy-Item -LiteralPath $sourceEvidence -Destination $targetEvidence -Force
    Write-Item "Install evidence" "OK" $evidenceName
  }
}

& $AssertInstalledBundleSync

Invoke-SkillStructureValidator $skillValidator $TargetSkillDir $resolvedPythonCommand

Write-Host ""
Write-Host "Running project document validator..."
& $SourceValidator -Scenario All -ProjectRoot $ProjectRoot -CodexHome $CodexHome
Write-Host "Running re0-memo registry validator..."
& $SourceRe0MemoTest -ProjectRoot $ProjectRoot -Case ValidRegistry
Write-Host "Running ground-truth registry validator..."
& $SourceGroundTruthTest -ProjectRoot $ProjectRoot -Case ValidRegistry
Write-Host "Running regression-evidence validator..."
& $SourceRegressionEvidenceTest -ProjectRoot $ProjectRoot -Case ValidReceipt

Write-Host ""
Write-Host "Done. Open the target project in Codex and start with mathsecr-paper-builder-kit\prompts\start-prompt.md."
