[CmdletBinding()]
param(
  [ValidateRange(1,30)][int]$TimeoutSeconds = 15,
  [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '[\x00-\x1F]' })][string]$HostId = 'local',
  [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '[\x00-\x1F]' })][string]$AccountId,
  [switch]$RemoteRequested,
  [string]$RemoteRequestEvidence,
  [string]$OutPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aside_preflight.ps1')

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

# Read-only service/skill handshake, then inventory; no tab mutation.
# Resolve and reject unauthorized routes before any CLI lookup or invocation.
$executionMachineName = [Environment]::MachineName
$probeCommands = @(Get-MathSecrAsideProbeCommands -HostId $HostId -AccountId $AccountId -RemoteRequested:$RemoteRequested -RemoteRequestEvidence $RemoteRequestEvidence)
$command = Get-Command aside -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$receipt = [pscustomobject]@{
  schemaVersion=1; probeCommand='skills-list-and-listBrowserTabs'; checkId=[guid]::NewGuid().ToString('N')
  startedAtUtc=[DateTime]::UtcNow.ToString('o'); completedAtUtc=''; executable=''
  exitCode=$null; timedOut=$false; stdout=''; stderr=''
  requestedHostId=$HostId; requestedAccountId=$AccountId; invocations=@()
  executionMachineName=$executionMachineName; effectiveHostId=$probeCommands[0].HostId
  hostSelectionBasis=$probeCommands[0].HostSelectionBasis
  remoteRequestEvidence=$(if ($probeCommands[0].HostSelectionBasis -ceq 'explicit-remote-request') { $RemoteRequestEvidence } else { '' })
}
if ($null -eq $command) {
  $receipt.stderr = 'Aside CLI was not found on PATH.'
} else {
  $receipt.executable = $command.Source
  foreach ($probeCommand in $probeCommands) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $command.Source; $info.Arguments = $probeCommand.ArgumentString
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    try {
      $null = $process.Start()
      $receipt.invocations += [pscustomobject]@{ argumentList=$probeCommand.ArgumentList }
      $stdoutTask = $process.StandardOutput.ReadToEndAsync()
      $stderrTask = $process.StandardError.ReadToEndAsync()
      if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $receipt.timedOut = $true
        # Stop only this probe client, never the user's Aside Browser.
        $process.Kill(); $process.WaitForExit()
      }
      $receipt.stdout += $stdoutTask.GetAwaiter().GetResult()
      $receipt.stderr += $stderrTask.GetAwaiter().GetResult()
      $receipt.exitCode = $process.ExitCode
    } catch { $receipt.stderr += $_.Exception.Message }
    finally { $process.Dispose() }
    if ($receipt.timedOut -or $null -eq $receipt.exitCode -or $receipt.exitCode -ne 0) { break }
  }
}
$receipt.completedAtUtc = [DateTime]::UtcNow.ToString('o')
$availability = Get-MathSecrAsideAvailabilityFromProbe $receipt
$result = [pscustomobject]@{ ProbeReceipt=$receipt; Availability=$availability }
if ($OutPath) {
  $fullPath = [IO.Path]::GetFullPath($OutPath)
  $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($result | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    $stream.Write($bytes,0,$bytes.Length)
  } finally { $stream.Dispose() }
}
if ($availability.Status -ceq 'off') {
  Write-Output $availability.UserResponse
  exit 2
}
$result | ConvertTo-Json -Depth 8
if ($availability.Status -cne 'ready') { exit 1 }
