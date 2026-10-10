param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$CodexHome = $env:CODEX_HOME,
  [string]$EvidenceRoot,
  [string]$EvidencePath,
  [switch]$PromptDriftRed,
  [int]$SimulatorPort = 8785
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not $CodexHome) {
  $CodexHome = Join-Path $HOME ".codex"
}
$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
if (-not $EvidenceRoot) {
  $EvidenceRoot = Join-Path $ProjectRoot ".omo\evidence"
}
$EvidenceRoot = [System.IO.Path]::GetFullPath($EvidenceRoot)

if (-not $EvidencePath) {
  $EvidencePath = if ($PromptDriftRed) {
    Join-Path $ProjectRoot ".omo\evidence\task-9-regression-pack-red.txt"
  } else {
    Join-Path $ProjectRoot ".omo\evidence\task-9-regression-pack.txt"
  }
}
$EvidencePath = [System.IO.Path]::GetFullPath($EvidencePath)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$regressionEvidenceContractPath = Join-Path $scriptRoot 'regression_evidence_contract.ps1'
if (-not (Test-Path -LiteralPath $regressionEvidenceContractPath -PathType Leaf)) {
  throw "Missing regression-evidence contract: $regressionEvidenceContractPath"
}
. $regressionEvidenceContractPath
$regressionEvidenceSidecarPath = Get-MathSecrRegressionEvidenceSidecarPath $EvidencePath
if (Test-Path -LiteralPath $regressionEvidenceSidecarPath) {
  Remove-Item -LiteralPath $regressionEvidenceSidecarPath -Force
}
$regressionStartedAtUtc = [DateTimeOffset]::UtcNow
$regressionInputSnapshot = Get-MathSecrRegressionInputSnapshot -ProjectRoot $ProjectRoot -EvidencePath $EvidencePath
$summary = New-Object System.Collections.Generic.List[string]

function Add-Summary {
  param([string]$Line)
  $summary.Add($Line) | Out-Null
}

function Write-Summary {
  $dir = Split-Path -Parent $EvidencePath
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $summary | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
}

function Invoke-Logged {
  param(
    [string]$Name,
    [scriptblock]$Block
  )
  Add-Summary "## $Name"
  try {
    $output = & $Block 2>&1
    if ($null -ne $output) {
      foreach ($line in @($output)) {
        Add-Summary ([string]$line)
      }
    }
    Add-Summary "RESULT: PASS"
    Add-Summary ""
  } catch {
    Add-Summary "RESULT: FAIL"
    Add-Summary "ERROR: $($_.Exception.Message)"
    Add-Summary ""
    throw
  }
}

function Invoke-Script {
  param([string]$RelativePath, [hashtable]$Parameters = @{})
  $path = Join-Path $ProjectRoot $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing script: $path"
  }
  & $path @Parameters
}

function Invoke-NoForbiddenPromptScan {
  $paths = @(
    ".omo\prompts",
    "AGENTS.md",
    "mathsecr-paper-builder-kit\AGENTS.md",
    "mathsecr-paper-builder-kit\prompts",
    "mathsecr-paper-builder-kit\skills"
  )
  $files = foreach ($path in $paths) {
    $full = Join-Path $ProjectRoot $path
    if (Test-Path -LiteralPath $full -PathType Leaf) {
      Get-Item -LiteralPath $full
    } elseif (Test-Path -LiteralPath $full -PathType Container) {
      Get-ChildItem -LiteralPath $full -File -Recurse
    }
  }
  $forbiddenMatches = @(
    foreach ($file in @($files | Sort-Object FullName -Unique)) {
      Select-String -LiteralPath $file.FullName -SimpleMatch "미완성(0선택)"
    }
  )
  if ($forbiddenMatches.Count -gt 0) {
    $forbiddenMatches | ForEach-Object {
      Add-Summary "$($_.Path):$($_.LineNumber):$($_.Line)"
    }
    throw "Forbidden prompt drift text found"
  }
  "No forbidden zero-selection prompt drift text found"
}

function Invoke-SimulatorHttpSmoke {
  $simDir = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\iab-simulator"
  if (-not (Test-Path -LiteralPath (Join-Path $simDir "index.html"))) {
    throw "Missing simulator index.html"
  }

  $listenerPattern = "^\s*TCP\s+\S+:$([regex]::Escape([string]$SimulatorPort))\s+\S+\s+LISTENING\s+\d+\s*$"
  $preexistingListener = @(netstat -ano -p TCP | Select-String -Pattern $listenerPattern)
  if ($preexistingListener) {
    throw "Simulator port is already in use before smoke: $SimulatorPort"
  }

  $python = Get-Command python -ErrorAction Stop
  $stdoutPath = $null
  $stderrPath = $null
  $serverProcess = $null
  $bodyError = $null
  $cleanupErrors = [System.Collections.Generic.List[string]]::new()

  try {
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $serverProcess = Start-Process -FilePath $python.Source `
      -ArgumentList @("-m", "http.server", [string]$SimulatorPort, "--bind", "127.0.0.1") `
      -WorkingDirectory $simDir -WindowStyle Hidden -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath -PassThru

    $response = $null
    for ($i = 0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 200
      $response = & curl.exe -s -i "http://127.0.0.1:$SimulatorPort/index.html?mode=broad" 2>&1
      if ($LASTEXITCODE -eq 0 -and ($response -join "`n") -like "*MathSecr iab simulator*") {
        break
      }
      $response = $null
    }
    if (-not $response) {
      throw "Simulator HTTP smoke did not return expected body"
    }
    $text = $response -join "`n"
    if ($text -notlike "*197,341*" -or $text -notlike "*broad*") {
      throw "Simulator response missing broad-result marker"
    }
    if ($text -notlike "*출제하기*") {
      throw "Simulator response missing forbidden visual control marker"
    }
    "HTTP simulator smoke PASS on port $SimulatorPort"
    "Body markers: MathSecr iab simulator, broad, 197,341, 출제하기"
  } catch {
    $bodyError = $_
  } finally {
    if ($serverProcess) {
      try {
        $serverProcess.Refresh()
        if (-not $serverProcess.HasExited) {
          Stop-Process -Id $serverProcess.Id -Force -ErrorAction Stop
        }
        if (-not $serverProcess.WaitForExit(10000)) {
          $cleanupErrors.Add("server process did not exit: PID $($serverProcess.Id)")
        }
      } catch {
        $cleanupErrors.Add("server process cleanup failed: $($_.Exception.Message)")
      }
    }
    foreach ($logPath in @($stdoutPath, $stderrPath) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) {
      if (Test-Path -LiteralPath $logPath) {
        try {
          Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue |
            Select-Object -First 5 | ForEach-Object { Add-Summary "server: $_" }
          Remove-Item -LiteralPath $logPath -Force -ErrorAction Stop
        } catch {
          $cleanupErrors.Add("temporary log cleanup failed for '$logPath': $($_.Exception.Message)")
        }
      }
    }
    $listening = $null
    for ($cleanupRead = 0; $cleanupRead -lt 50; $cleanupRead++) {
      $listening = @(netstat -ano -p TCP | Select-String -Pattern $listenerPattern)
      if (-not $listening) { break }
      Start-Sleep -Milliseconds 200
    }
    if ($listening) {
      $listening | ForEach-Object { Add-Summary "cleanup-listening: $_" }
      $cleanupErrors.Add("simulator server still LISTENING on port $SimulatorPort")
    } else {
      Add-Summary "cleanup: no :$SimulatorPort LISTENING socket"
    }
  }
  if ($null -ne $bodyError) {
    foreach ($cleanupError in $cleanupErrors) { Add-Summary "cleanup-error: $cleanupError" }
    throw $bodyError
  }
  if ($cleanupErrors.Count -gt 0) {
    throw "Simulator cleanup failed: $($cleanupErrors -join ' | ')"
  }
}

function Invoke-PromptDriftRed {
  $promptDir = Join-Path $ProjectRoot ".omo\prompts"
  New-Item -ItemType Directory -Force -Path $promptDir | Out-Null
  $tempPrompt = Join-Path $promptDir ("_tmp_regression_prompt_drift_red_{0}.md" -f [Guid]::NewGuid().ToString("N"))
  $ownsTempPrompt = $false
  try {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $content = $encoding.GetBytes("최종 상태: 미완성(0선택)")
    $stream = [System.IO.File]::Open($tempPrompt, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $ownsTempPrompt = $true
    try {
      $stream.Write($content, 0, $content.Length)
    } finally {
      $stream.Dispose()
    }

    $scanRejected = $false
    try {
      Invoke-NoForbiddenPromptScan
    } catch {
      "PowerShell prompt scan red case rejected as expected: $($_.Exception.Message)"
      $scanRejected = $true
    }
    if (-not $scanRejected) { throw "PowerShell prompt scan red case unexpectedly passed" }

    $validatorRejected = $false
    try {
      Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\validate_mathsecr_docs.ps1" -Parameters @{ Scenario = "PromptDrift"; ProjectRoot = $ProjectRoot; CodexHome = $CodexHome }
    } catch {
      "PromptDrift validator red case rejected as expected: $($_.Exception.Message)"
      $validatorRejected = $true
    }
    if (-not $validatorRejected) { throw "PromptDrift validator red case unexpectedly passed" }
  } finally {
    if ($ownsTempPrompt) {
      Remove-Item -LiteralPath $tempPrompt -Force -ErrorAction Stop
      if (Test-Path -LiteralPath $tempPrompt) { throw "Owned prompt-drift fixture cleanup failed: $tempPrompt" }
      Add-Summary "cleanup: removed owned GUID prompt fixture $([System.IO.Path]::GetFileName($tempPrompt))"
    }
  }
}

Add-Summary "# MathSecr Regression Pack"
Add-Summary "ProjectRoot: $ProjectRoot"
Add-Summary "PromptDriftRed: $PromptDriftRed"
Add-Summary "truth_scope=offline-contract product_behavior=false"
Add-Summary "InputFileCount: $($regressionInputSnapshot.FileCount)"
Add-Summary "InputManifestSha256: $($regressionInputSnapshot.InputManifestSha256)"
Add-Summary "RunnerSha256: $($regressionInputSnapshot.RunnerSha256)"
Add-Summary ""
Add-Summary "Known failure classes covered: prompt drift; blank-scope broad result 197,341; selected-bundle collapse and ordered permutation; repeated source-occurrence identity collapse; same-source search regression requiring CANDIDATE_RECOVERY; semantic common-chip false negative; missing literal-only ladder/backoff; retry-budget false absence; incomplete candidate recovery/coverage; printed-metadata one-chip rescue required; incomplete lazy-result traversal; transcription-conflict/source_anomaly gating without an artifact-bound receipt or with false zero/partial report closure; stale regression PASS reuse after current input bytes change; iab unavailable -> 차단; zero-selection -> 검색 완료/0선택; misleading completion report; install/check false-green; synthetic fixture provenance; year-range pinned serializer-guard/local-adapter claim drift; body-exact origin-evidence overclaim and blind-run leakage; circular fixture/gold/evidence self-confirmation and external-truth overclaim; unstable third search snapshot; phrase/split-AND evidence drift; idle first-query early-touch/duration/receipt/signature/selection drift; frozen-regression live-wait and service/freshness/exact claim-boundary overreach; same-card duplicate-insertion overclaim; selection-journal retry/ACK/idempotency and corrupt-tail handling; failed-problem crop-report PDF generation, manifest validation, and deterministic temp cleanup; PDF segmentation packaged-manifest/render checks with pinned source-hash verification when originals are available, printed-order, bounding-box, and honest-gap handling; postmortem-to-gate linkage drift and high-impact lesson downgrade; dirty read-only cleanup."
Add-Summary ""

try {
  if ($PromptDriftRed) {
    Invoke-Logged "Intentional Prompt Drift Red Case" { Invoke-PromptDriftRed }
    Add-Summary "REGRESSION PACK RED RESULT: EXPECTED FAILURE OBSERVED"
    Write-Summary
    exit 1
  }

  Invoke-Logged "Validator All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\validate_mathsecr_docs.ps1" -Parameters @{ Scenario = "All"; ProjectRoot = $ProjectRoot; CodexHome = $CodexHome }
  }
  Invoke-Logged "Prompt Drift PowerShell Scan" { Invoke-NoForbiddenPromptScan }
  Invoke-Logged "Kit Check" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\check.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; CodexHome = $CodexHome; EvidenceRoot = $EvidenceRoot }
  }
  Invoke-Logged "Install And Check Contract" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_install_contract.ps1" -Parameters @{ EvidenceRoot = $EvidenceRoot }
  }
  Invoke-Logged "Synthetic Fixture Generation" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\new_test_fixtures.ps1" -Parameters @{ ProjectRoot = $ProjectRoot }
  }
  Invoke-Logged "Year Range Pinned Serializer Guard" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_year_range_serialization_baseline.ps1" -Parameters @{ ProjectRoot = $ProjectRoot }
  }
  Invoke-Logged "Year Range Local CLI Adapter Contract" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_year_range_serialization_contract.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Ground Truth Independence Contract All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_ground_truth_contract.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Regression Evidence Contract" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_regression_evidence_contract.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Ground Truth External Shape Positive" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_ground_truth_contract.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "ValidExternalShape" }
  }
  Invoke-Logged "Body-Exact Corpus Consistency Gate" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\verify_body_exact_benchmark.ps1" -Parameters @{ ProjectRoot = $ProjectRoot }
  }
  Invoke-Logged "Body-Exact Corpus Consistency Harness" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_body_exact_benchmark.ps1" -Parameters @{ ProjectRoot = $ProjectRoot }
  }
  Invoke-Logged "DB Inference Contract All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_db_inference.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Offline State Machine All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_state_machine.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Partial Save Phases" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_partial_save_phases.ps1" -Parameters @{ ProjectRoot = $ProjectRoot }
  }
  Invoke-Logged "Aside Preflight Contract" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_aside_preflight.ps1" -Parameters @{}
  }
  Invoke-Logged "Production Validation" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_production_validation.ps1" -Parameters @{ ProjectRoot = $ProjectRoot }
  }
  Invoke-Logged "Search Attempt Provenance Contract All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_search_attempt_contract.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Search Query Preparation Contract All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_search_query_plan.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Search Observation Contract All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_search_observation.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Body Comparison Selection Contract All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_body_comparison_contract.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Selection Evidence Preparation Contract" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_prepare_selection_evidence.ps1" -Parameters @{ ProjectRoot = $ProjectRoot }
  }
  Invoke-Logged "Search Characterization Evidence Gate" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_search_characterization.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Idle Search Characterization Evidence Gate" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_idle_search_characterization.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Selection Journal Contract All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_selection_journal.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Failed Problem Crop Report Contract All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_failed_problem_report.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "PDF Segmentation Corpus Contract All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_pdf_segmentation.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Session Report Linter All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_report_lint.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Re0 Memo Registry All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit\scripts\test_re0_memo.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
  }
  Invoke-Logged "Simulator HTTP Smoke" { Invoke-SimulatorHttpSmoke }

  Add-Summary "REGRESSION PACK RESULT: PASS"
  Write-Summary
  $regressionEvidenceSidecarPath = Write-MathSecrRegressionEvidenceSidecar `
    -ProjectRoot $ProjectRoot `
    -EvidencePath $EvidencePath `
    -StartSnapshot $regressionInputSnapshot `
    -StartedAtUtc $regressionStartedAtUtc `
    -CompletedAtUtc ([DateTimeOffset]::UtcNow)
  $regressionReceipt = Test-MathSecrRegressionEvidenceSidecar -ProjectRoot $ProjectRoot -EvidencePath $EvidencePath
  Write-Host "Regression pack PASS"
  Write-Host "Evidence: $EvidencePath"
  Write-Host "Evidence sidecar: $regressionEvidenceSidecarPath"
  Write-Host "RegressionEvidence PASS truth_scope=offline-contract product_behavior=false input_files=$($regressionReceipt.InputFileCount) input_manifest_sha256=$($regressionReceipt.InputManifestSha256)"
} catch {
  if (Test-Path -LiteralPath $regressionEvidenceSidecarPath) {
    Remove-Item -LiteralPath $regressionEvidenceSidecarPath -Force
  }
  Add-Summary "REGRESSION PACK RESULT: FAIL"
  Add-Summary "ERROR: $($_.Exception.Message)"
  Write-Summary
  Write-Error $_
  exit 1
}
