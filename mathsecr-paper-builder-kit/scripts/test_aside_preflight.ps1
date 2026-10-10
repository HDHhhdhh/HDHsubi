$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'aside_preflight.ps1')
function New-TestAsideProbe {
  return [pscustomobject]@{
    schemaVersion=1; probeCommand='skills-list-and-listBrowserTabs'; checkId=('a' * 32)
    startedAtUtc='2026-10-07T01:00:00.000Z'; completedAtUtc='2026-10-07T01:00:01.000Z'
    executable='C:\synthetic\aside.exe'; exitCode=0; timedOut=$false
    stdout='{"kind":"mathsecr-aside-preflight-v1","tabCount":0}'; stderr=''
  }
}
function Assert-ProbeStatus($Probe, $Expected) {
  $value = Get-MathSecrAsideAvailabilityFromProbe $Probe
  if ($value.Status -cne $Expected) { throw "Expected $Expected, got $($value.Status)" }
  return $value
}
$ready = New-TestAsideProbe
$null = Assert-ProbeStatus $ready 'ready'
$off = New-TestAsideProbe
$off.exitCode = 1; $off.stdout = ''; $off.stderr = "Aside isn't running on this machine."
$offResult = Assert-ProbeStatus $off 'off'
if ((Get-MathSecrAsideUserResponse $off) -cne 'aside 키고 다시 오도록.') { throw 'Fixed user response differs.' }
$offWithAdvice = New-TestAsideProbe
$offWithAdvice.exitCode = 1; $offWithAdvice.stdout = ''
$offWithAdvice.stderr = "Aside isn't running on this machine.`n  - Start Aside Browser and retry, or`n  - run 'aside login' once, then 'aside exec --host <host>'.`n"
$null = Assert-ProbeStatus $offWithAdvice 'off'
if ((Get-MathSecrAsideUserResponse $offWithAdvice) -cne 'aside 키고 다시 오도록.') { throw 'CLI advice must not be mistaken for an auth failure.' }
foreach ($message in @('fetch failed','login required','timeout','paper title missing','profile u0 not connected')) {
  $unknown = New-TestAsideProbe
  $unknown.exitCode = 1; $unknown.stdout = ''; $unknown.stderr = $message
  $null = Assert-ProbeStatus $unknown 'unavailable'
  if ($null -ne (Get-MathSecrAsideUserResponse $unknown)) { throw 'Unknown failure must not claim browser off.' }
}
$mixedFixturePath = Join-Path $PSScriptRoot '..\test-fixtures\aside-preflight\daemon-auth-transport-2026-10-07.json'
$mixedFixture = Get-Content -LiteralPath $mixedFixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($mixedFixture.schemaVersion -ne 1 -or $mixedFixture.truthScope -cne 'offline-contract' -or
    $mixedFixture.expectedStatus -cne 'unavailable' -or $mixedFixture.expectedReason -cne 'probe-auth-or-transport-failed' -or
    $mixedFixture.stderr -isnot [string] -or -not $mixedFixture.stderr.Contains('Failed to request daemon auth challenge: fetch failed') -or
    -not $mixedFixture.stderr.Contains("Aside isn't running on this machine.")) { throw 'Mixed daemon failure fixture is invalid.' }
foreach ($outputStream in @('stderr','stdout')) {
  $mixed = New-TestAsideProbe
  $mixed.exitCode = 1; $mixed.stdout = ''; $mixed.stderr = ''
  $mixed.$outputStream = $mixedFixture.stderr
  $mixedResult = Assert-ProbeStatus $mixed $mixedFixture.expectedStatus
  if (-not $mixedResult.Valid -or $mixedResult.Reason -cne $mixedFixture.expectedReason -or
      $null -ne $mixedResult.UserResponse -or $null -ne (Get-MathSecrAsideUserResponse $mixed)) {
    throw 'Mixed daemon failure must not emit the browser-off response.'
  }
}
foreach ($message in @('Failed to request daemon auth challenge: permission denied', 'fetch failed')) {
  $mixed = New-TestAsideProbe
  $mixed.exitCode = 1; $mixed.stdout = $off.stderr; $mixed.stderr = $message
  $null = Assert-ProbeStatus $mixed 'unavailable'
  if ($null -ne (Get-MathSecrAsideUserResponse $mixed)) { throw 'Split-stream daemon failure must not claim browser off.' }
}
$timeout = New-TestAsideProbe
$timeout.timedOut = $true; $timeout.stderr = $off.stderr
$null = Assert-ProbeStatus $timeout 'unavailable'
$missing = New-TestAsideProbe
$missing.executable = ''; $missing.exitCode = $null
$null = Assert-ProbeStatus $missing 'unavailable'
$wrongCommand = New-TestAsideProbe
$wrongCommand.probeCommand = 'guessed-api'
if ((Get-MathSecrAsideAvailabilityFromProbe $wrongCommand).Valid) { throw 'Unknown command accepted.' }
$stringBoolean = New-TestAsideProbe
$stringBoolean.timedOut = 'false'
if ((Get-MathSecrAsideAvailabilityFromProbe $stringBoolean).Valid) { throw 'String Boolean accepted.' }
$duplicate = New-TestAsideProbe
$duplicate.stdout += "`n" + $duplicate.stdout
$null = Assert-ProbeStatus $duplicate 'unavailable'
$inconsistent = New-TestAsideProbe
$inconsistent.completedAtUtc = '2026-10-07T00:59:00.000Z'
if ((Get-MathSecrAsideAvailabilityFromProbe $inconsistent).Valid) { throw 'Reversed timestamps accepted.' }

# Load only the pure argv builders; do not execute the live probe in this test.
$probePath = Join-Path $PSScriptRoot 'check_aside_repl.ps1'
$parseErrors = $null; $tokens = $null
$probeAst = [Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Aside probe has parser errors.' }
foreach ($name in @('ConvertTo-MathSecrAsideProcessArgumentString','Get-MathSecrAsideProbeCommands')) {
  $definition = @($probeAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object Name -CEQ $name)
  if ($definition.Count -ne 1) { throw "Missing or duplicated argv builder: $name" }
  Invoke-Expression $definition[0].Extent.Text
}
$cases = @(
  @{ Parameters=@{}; Prefix=@('--host','local') },
  @{ Parameters=@{HostId=''; AccountId=''}; Prefix=@('--host','local') },
  @{ Parameters=@{HostId='local'; AccountId='u0'}; Prefix=@('--host','local','--account','u0') },
  @{ Parameters=@{HostId='합성로컬표시명 작업'; AccountId='u0'; RemoteRequested=$true; RemoteRequestEvidence='원격 PC에서 작업해 주세요. (오프라인 테스트 입력)'}; Prefix=@('--host','합성로컬표시명 작업','--account','u0') },
  @{ Parameters=@{HostId='device "name"\'; AccountId='u1'; RemoteRequested=$true; RemoteRequestEvidence='Use the remote PC. (Offline test input)'}; Prefix=@('--host','device "name"\','--account','u1') },
  @{ Parameters=@{HostId='literal $(throw "unsafe") & ;'; AccountId='u0'; RemoteRequested=$true; RemoteRequestEvidence='Use the remote PC. (Offline test input)'}; Prefix=@('--host','literal $(throw "unsafe") & ;','--account','u0') },
  @{ Parameters=@{HostId='LOCAL'; AccountId=''}; Prefix=@('--host','local') },
  @{ Parameters=@{HostId=''; AccountId='u0'}; Prefix=@('--host','local','--account','u0') }
)
# Shadow CLI discovery inside this assertion. A missing route guard must fail
# without looking up or starting the user's real Aside process.
function Assert-RemoteRouteRejected {
  param([hashtable]$Parameters)
  function Get-Command { throw 'UnexpectedLiveCliLookup: route rejection must precede CLI discovery.' }
  $rejected = $false
  try { & $probePath @Parameters | Out-Null } catch {
    if ($_.Exception.Message -notlike 'ExplicitRemoteRequestRequired:*') { throw }
    $rejected = $true
  }
  if (-not $rejected) { throw 'Non-local route without an explicit request was accepted.' }
}
foreach ($parameters in @(
  @{HostId='합성로컬표시명'},
  @{HostId='remote:synthetic-host'},
  @{HostId='remote:synthetic-host'; RemoteRequested=$true},
  @{HostId='remote:synthetic-host'; RemoteRequestEvidence='합성로컬표시명'},
  @{HostId='remote:synthetic-host'; RemoteRequested=$true; RemoteRequestEvidence='   '}
)) {
  Assert-RemoteRouteRejected $parameters
}
$argvRoot = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-aside-argv-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $argvRoot
$argvScript = Join-Path $argvRoot 'argv.ps1'
Set-Content -LiteralPath $argvScript -Value 'ConvertTo-Json -InputObject @($args) -Compress' -Encoding UTF8
$shellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
try {
  foreach ($case in $cases) {
    $parameters = $case.Parameters
    $commands = @(Get-MathSecrAsideProbeCommands @parameters)
    if ($commands.Count -ne 2) { throw 'Probe must retain exactly two commands.' }
    for ($index=0; $index -lt 2; $index++) {
      $expectedTail = if ($index -eq 0) { @('skills','list') } else { @('repl',"console.log(JSON.stringify({kind:'mathsecr-aside-preflight-v1',tabCount:(await listBrowserTabs()).length}));") }
      $expected = @($case.Prefix + $expectedTail)
      if (($commands[$index].ArgumentList | ConvertTo-Json -Compress) -cne ($expected | ConvertTo-Json -Compress)) { throw 'Wrong host/account command vector.' }
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.FileName = $shellPath
      $info.Arguments = ConvertTo-MathSecrAsideProcessArgumentString (@('-NoProfile','-NonInteractive','-File',$argvScript) + $commands[$index].ArgumentList)
      $info.UseShellExecute = $false; $info.CreateNoWindow = $true
      $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
      $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
      try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $actual = ConvertFrom-Json -InputObject $stdoutTask.GetAwaiter().GetResult()
        $actual = @($actual)
        if ($process.ExitCode -ne 0) { throw $stderrTask.GetAwaiter().GetResult() }
        if ($actual.Count -ne $expected.Count) { throw "Process argv cardinality changed: $($actual | ConvertTo-Json -Compress)." }
        for ($position=0; $position -lt $expected.Count; $position++) {
          if ($actual[$position] -cne $expected[$position]) { throw "Process argv changed at position $position." }
        }
      } finally { $process.Dispose() }
    }
  }
  foreach ($invalidValue in @('   ', "bad`nhost", ('bad' + [char]0 + 'host'))) {
    foreach ($parameterName in @('HostId','AccountId')) {
      $rejected = $false
      try { & $probePath @{$parameterName=$invalidValue} | Out-Null } catch [Management.Automation.ParameterBindingException] { $rejected = $true }
      if (-not $rejected) { throw "Invalid $parameterName passed parameter validation." }
    }
  }
} finally {
  Remove-Item -LiteralPath $argvScript -Force
  Remove-Item -LiteralPath $argvRoot -Force
}
Write-Output 'Aside preflight contract PASS (offline receipts, captured mixed daemon failure, local default, remote rejection before CLI lookup and 16 argv process round-trips; not live browser availability).'
