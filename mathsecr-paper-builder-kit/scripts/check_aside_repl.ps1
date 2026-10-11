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

# Preserve the original pure argv definitions for existing AST consumers.
function ConvertTo-MathSecrAsideProcessArgumentString {
  param([Parameter(Mandatory)][string[]]$Arguments)
  # ProcessStartInfo.Arguments uses Windows argv quoting, not shell quoting.
  return (@(foreach ($argument in $Arguments) {
    '"' + [regex]::Replace([regex]::Replace($argument, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
  }) -join ' ')
}

function Get-MathSecrAsideProbeCommands {
  param([string]$HostId = 'local', [string]$AccountId, [switch]$RemoteRequested, [string]$RemoteRequestEvidence)
  if ([string]::IsNullOrEmpty($HostId)) { $HostId = 'local' }
  $isLocal = [string]::Equals($HostId, 'local', [StringComparison]::OrdinalIgnoreCase)
  if ($isLocal) {
    $HostId = 'local'
  } elseif (-not $RemoteRequested -or [string]::IsNullOrWhiteSpace($RemoteRequestEvidence)) {
    throw 'ExplicitRemoteRequestRequired: non-local Aside probes require -RemoteRequested and the actual user instruction in -RemoteRequestEvidence. A device name alone is not a remote request.'
  }
  $basis = if ($isLocal) { 'local' } else { 'explicit-remote-request' }
  $prefix = @('--host', $HostId)
  if ($AccountId) { $prefix += @('--account', $AccountId) }
  $code = "console.log(JSON.stringify({kind:'mathsecr-aside-preflight-v1',tabCount:(await listBrowserTabs()).length}));"
  foreach ($commandArguments in @(@('skills', 'list'), @('repl', $code))) {
    $arguments = @($prefix + $commandArguments)
    [pscustomobject]@{
      ArgumentList=$arguments; ArgumentString=(ConvertTo-MathSecrAsideProcessArgumentString $arguments)
      HostId=$HostId; HostSelectionBasis=$basis
    }
  }
}

& (Join-Path $PSScriptRoot 'check_browser_surface.ps1') -Surface aside-repl @PSBoundParameters
exit $LASTEXITCODE
