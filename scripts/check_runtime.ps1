[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 is required.' }
$scriptRoot = Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/scripts'
# Load the real production boundary, not private historical test registries.
. (Join-Path $scriptRoot 'production_validation.ps1')
. (Join-Path $scriptRoot 'selection_assembly.ps1')
. (Join-Path $scriptRoot 'search_query_plan.ps1')
. (Join-Path $scriptRoot 'db_inference.ps1')
foreach ($name in @('Invoke-MathSecrProductionStep','Test-MathSecrSearchAttemptContract','Invoke-MathSecrDbInference','Invoke-MathSecrUserSummaryLint')) {
  if (-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) { throw "Missing runtime function: $name" }
}
Write-Output 'PublicRuntimeModules PASS'
