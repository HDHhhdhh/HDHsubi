param(
  [Parameter(Mandatory = $true)][string]$InputPath,
  [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$OutPath,
  [ValidateSet('BeforeNext','AfterReload')][string]$Phase = 'AfterReload'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'state_machine.ps1')
. (Join-Path $PSScriptRoot 'read_contract_json.ps1')
$snapshot = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8)
$result = Invoke-MathSecrStateMachine -Snapshot $snapshot -ProjectRoot $ProjectRoot -Phase $Phase
$json = $result | ConvertTo-Json -Depth 80
if ($OutPath) {
  if (Test-Path -LiteralPath $OutPath) { throw 'OutPath already exists; choose a new result path.' }
  [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutPath), $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
} else { $json }
if ($Phase -ceq 'BeforeNext') {
  if ($result.State -cne 'PRE_NEXT_GATE' -or $result.Status -cne 'ready-for-next' -or -not $result.CanNextStep) { exit 1 }
} elseif ($result.State -cne 'REPORT' -or $result.Status -cnotin @('완료', '부분 완료', '검색 완료/0선택')) { exit 1 }
