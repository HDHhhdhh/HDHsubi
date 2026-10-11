[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('aside-repl','codex-iab','codex-chrome-ext','offline-dom-test',IgnoreCase=$false)][string]$Surface,
  [string]$ProbeReceiptPath,
  [ValidateRange(1,30)][int]$TimeoutSeconds = 15,
  [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '[\x00-\x1F]' })][string]$HostId = 'local',
  [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '[\x00-\x1F]' })][string]$AccountId,
  [switch]$RemoteRequested,
  [string]$RemoteRequestEvidence,
  [string]$OutPath,
  [string]$PaperUrl,
  [string]$ToolReceiptPath,
  [string]$PlaywrightModule,
  [string]$BrowserPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aside_preflight.ps1')
. (Join-Path $PSScriptRoot 'surface_probe.ps1')
. (Join-Path $PSScriptRoot 'read_contract_json.ps1')

if ($Surface -ceq 'aside-repl') {
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
    $code = "const t=await listBrowserTabs();console.log(JSON.stringify({kind:'mathsecr-aside-preflight-v1',tabCount:t.length,tabs:t.map(x=>({targetId:x.targetId,url:x.url,title:x.title}))}));"
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
      $info.FileName = $command.Source
      if ($null -ne $info.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $probeCommand.ArgumentList) { $info.ArgumentList.Add($argument) }
      } else { $info.Arguments = $probeCommand.ArgumentString }
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

  $cliVersion=$null
  if ($availability.Status -ceq 'ready') {
    $versionInfo=[Diagnostics.ProcessStartInfo]::new()
    $versionInfo.FileName=$command.Source
    $versionArguments=@('--host',$probeCommands[0].HostId,'--version')
    if ($null -ne $versionInfo.PSObject.Properties['ArgumentList']) {
      foreach ($argument in $versionArguments) { $versionInfo.ArgumentList.Add($argument) }
    } else { $versionInfo.Arguments=ConvertTo-MathSecrAsideProcessArgumentString $versionArguments }
    $versionInfo.UseShellExecute=$false;$versionInfo.CreateNoWindow=$true
    $versionInfo.RedirectStandardOutput=$true;$versionInfo.RedirectStandardError=$true
    $versionProcess=[Diagnostics.Process]::new();$versionProcess.StartInfo=$versionInfo
    try {
      $null=$versionProcess.Start()
      $versionStdout=$versionProcess.StandardOutput.ReadToEndAsync()
      $versionStderr=$versionProcess.StandardError.ReadToEndAsync()
      $versionTimedOut=-not $versionProcess.WaitForExit($TimeoutSeconds*1000)
      if ($versionTimedOut) { $versionProcess.Kill();$versionProcess.WaitForExit() }
      $versionText=$versionStdout.GetAwaiter().GetResult()
      $null=$versionStderr.GetAwaiter().GetResult()
      if (-not $versionTimedOut -and $versionProcess.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($versionText)) {
        $cliVersion=$versionText.Trim()
      }
    } catch { $cliVersion=$null }
    finally { $versionProcess.Dispose() }
  }
  $surfaceProbe=ConvertFrom-MathSecrAsideProbeResult -ProbeReceipt $receipt -Availability $availability -PaperUrl $PaperUrl -CliVersion $cliVersion
  if ($OutPath) {
    $surfaceProbe.source.artifact=[pscustomobject]@{path=$OutPath;sha256=(Get-FileHash -LiteralPath $OutPath -Algorithm SHA256).Hash.ToLowerInvariant()}
  }
} elseif ($Surface -cin @('codex-iab','codex-chrome-ext')) {
  # Conditional required inputs are checked here, so a missing tool receipt
  # produces the specified install receipt instead of a parameter prompt.
  $toolReceipt=$null;$toolArtifact=$null
  if ($ToolReceiptPath -and (Test-Path -LiteralPath $ToolReceiptPath -PathType Leaf)) {
    try {
      $bytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($ToolReceiptPath))
      $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
      $toolArtifact=[pscustomobject]@{path=$ToolReceiptPath;sha256=$hash}
      if (Test-MathSecrSurfaceProbeJsonObject $bytes) {
        try { $toolReceipt=ConvertFrom-MathSecrArtifactBytes -Bytes $bytes } catch { $toolReceipt=[pscustomobject]@{} }
      } else { $toolReceipt=[pscustomobject]@{} }
    } catch { $toolReceipt=[pscustomobject]@{} }
  }
  $surfaceProbe=ConvertFrom-MathSecrCodexToolReceipt -Surface $Surface -ToolReceipt $toolReceipt -ToolReceiptArtifact $toolArtifact -PaperUrl $PaperUrl
} else {
  $surfaceProbe=Get-MathSecrOfflineSurfaceProbe -PlaywrightModule $PlaywrightModule -BrowserPath $BrowserPath
}
if ($ProbeReceiptPath) {
  $fullPath=[IO.Path]::GetFullPath($ProbeReceiptPath)
  $stream=[IO.File]::Open($fullPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try {
    $probeBytes=[Text.UTF8Encoding]::new($false).GetBytes(($surfaceProbe | ConvertTo-Json -Depth 8)+[Environment]::NewLine)
    $stream.Write($probeBytes,0,$probeBytes.Length)
  } finally { $stream.Dispose() }
}
if ($Surface -ceq 'aside-repl') {
  if ($availability.Status -ceq 'off') { Write-Output $availability.UserResponse;exit 2 }
  $result | ConvertTo-Json -Depth 8
  if ($availability.Status -cne 'ready') { exit 1 }
  exit 0
}
$surfaceProbe | ConvertTo-Json -Depth 8
if ($surfaceProbe.failureClass -cne 'none') { exit 1 }
exit 0
