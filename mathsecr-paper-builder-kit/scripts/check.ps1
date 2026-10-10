param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$CodexHome = $env:CODEX_HOME,
  [string]$EvidenceRoot
)

$script = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "install.ps1"
& $script -ProjectRoot $ProjectRoot -CodexHome $CodexHome -EvidenceRoot $EvidenceRoot -CheckOnly
