[CmdletBinding()]
param(
  [ValidateRange(1,30)][int]$TimeoutSeconds = 15,
  [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '[\x00-\x1F]' })][string]$HostId = 'local',
  [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '[\x00-\x1F]' })][string]$AccountId,
  [switch]$RemoteRequested,
  [string]$RemoteRequestEvidence,
  [string]$OutPath,
  [string]$PaperUrl,
  [string]$ProbeReceiptPath
)
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'check_browser_surface.ps1') -Surface aside-repl @PSBoundParameters
exit $LASTEXITCODE
