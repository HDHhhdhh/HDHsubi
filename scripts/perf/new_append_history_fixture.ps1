[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateRange(1,1000)][int]$ProblemCount,
  [Parameter(Mandatory)][ValidateRange(0,63)][int]$HistoryDepth,
  [Parameter(Mandatory)][string]$OutRoot
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'append_history_support.ps1')
$fixture = New-MathSecrAppendHistoryFixture @PSBoundParameters
[ordered]@{status='PASS';truthScope='offline-contract';liveProductBehavior=$false;root=$fixture.Root;
  problemCount=$ProblemCount;historyDepth=$HistoryDepth;sessionCount=$fixture.Manifest.sessions.Count;
  finalSession=$fixture.Manifest.finalSessionArtifact.path} | ConvertTo-Json -Compress
