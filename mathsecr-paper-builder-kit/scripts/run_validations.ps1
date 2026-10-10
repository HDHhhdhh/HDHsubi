param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$CodexHome = $env:CODEX_HOME,
  [string]$EvidenceRoot,
  [string]$EvidencePath,
  [switch]$PromptDriftRed,
  [int]$SimulatorPort = 8785
)

$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "run_mathsecr_regression.ps1"
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
  throw "Missing full validation runner: $runner"
}

$arguments = @{
  ProjectRoot = $ProjectRoot
  SimulatorPort = $SimulatorPort
}
if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $arguments.CodexHome = $CodexHome }
if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) { $arguments.EvidenceRoot = $EvidenceRoot }
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) { $arguments.EvidencePath = $EvidencePath }
if ($PromptDriftRed) { $arguments.PromptDriftRed = $true }

& $runner @arguments
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}
