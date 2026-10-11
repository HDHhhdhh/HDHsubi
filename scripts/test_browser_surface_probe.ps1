[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$kitScripts=Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/scripts'
. (Join-Path $kitScripts 'surface_probe.ps1')
. (Join-Path $kitScripts 'aside_preflight.ps1')
. (Join-Path $kitScripts 'read_contract_json.ps1')

function Assert-SurfaceProbeCase {
  param([bool]$Condition,[string]$Name,[string]$Kind)
  if (-not $Condition) { throw "SurfaceProbe case failed: $Name" }
  [pscustomobject]@{kind=$Kind;case=$Name;status='PASS'} | ConvertTo-Json -Compress
}
function Copy-SurfaceProbeTestValue {
  param($Value)
  return ConvertFrom-MathSecrContractJson (ConvertTo-Json -InputObject $Value -Depth 30 -Compress)
}
function New-SurfaceProbeTestAsideReceipt {
  return [pscustomobject]@{
    schemaVersion=1;probeCommand='skills-list-and-listBrowserTabs';checkId=('a'*32)
    startedAtUtc='2026-10-11T00:00:00.000Z';completedAtUtc='2026-10-11T00:00:01.000Z'
    executable='C:\synthetic\aside.exe';exitCode=0;timedOut=$false
    stdout='{"kind":"mathsecr-aside-preflight-v1","tabCount":1,"tabs":[{"targetId":"synthetic-tab","url":"https://www.mathsecr.com/mypaper/123","title":"Synthetic paper"}]}';stderr=''
  }
}
function New-SurfaceProbeTestToolReceipt {
  param([string]$Surface)
  $browser=if ($Surface -ceq 'codex-iab') {
    [pscustomobject]@{id='synthetic-iab';type='iab';metadata=[pscustomobject]@{codexSessionId='synthetic-session'}}
  } else {
    [pscustomobject]@{id='synthetic-extension';type='extension';family='chrome';name='Chrome';metadata=[pscustomobject]@{extensionInstanceId='synthetic-extension-instance'}}
  }
  return [pscustomobject]@{
    schemaVersion=1;tool='mcp__cua_repl';capturedAtUtc='2026-10-11T00:00:00.000Z';surface=$Surface;browser=$browser
    tab=[pscustomobject]@{id='synthetic-tab';url='https://www.mathsecr.com/mypaper/123';title='Synthetic paper'}
  }
}
function Invoke-SurfaceProbeTestCli {
  param([string[]]$Arguments,[string]$EmptyPath)
  $info=[Diagnostics.ProcessStartInfo]::new()
  $info.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  foreach ($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $kitScripts 'check_browser_surface.ps1'))+$Arguments) { $info.ArgumentList.Add($argument) }
  # No Aside executable can be discovered. Only this pwsh test child is started.
  $info.Environment['PATH']=$EmptyPath
  $process=[Diagnostics.Process]::new();$process.StartInfo=$info
  try {
    $null=$process.Start()
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill();$process.WaitForExit();throw 'SurfaceProbe test child timed out.' }
    return [pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
  } finally { $process.Dispose() }
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-surface-probe-'+[guid]::NewGuid().ToString('N'))
$root=[IO.Path]::GetFullPath($root)
$null=New-Item -ItemType Directory -Path $root
try {
  $url='https://www.mathsecr.com/mypaper/123'
  $artifact=[pscustomobject]@{path='synthetic-tool.json';sha256=('a'*64)}
  foreach ($reason in @('repl-reachable','cli-unavailable','probe-timeout','probe-auth-or-transport-failed','browser-not-running','probe-failed-or-unrecognized','invalid-probe-receipt')) {
    $raw=New-SurfaceProbeTestAsideReceipt
    switch ($reason) {
      'cli-unavailable' { $raw.executable='';$raw.exitCode=$null }
      'probe-timeout' { $raw.timedOut=$true }
      'probe-auth-or-transport-failed' { $raw.exitCode=1;$raw.stderr='Failed to request daemon auth challenge: fetch failed' }
      'browser-not-running' { $raw.exitCode=1;$raw.stdout='';$raw.stderr="Aside isn't running on this machine." }
      'probe-failed-or-unrecognized' { $raw.exitCode=1;$raw.stdout='';$raw.stderr='' }
      'invalid-probe-receipt' { $raw.schemaVersion=2 }
    }
    $availability=Get-MathSecrAsideAvailabilityFromProbe $raw
    $probe=ConvertFrom-MathSecrAsideProbeResult $raw $availability $url $null
    $expected=switch ($reason) { 'repl-reachable' {'none'}; 'cli-unavailable' {'install'}; {$_ -cin @('probe-timeout','probe-auth-or-transport-failed','browser-not-running')} {'connect'}; default {'read'} }
    Assert-SurfaceProbeCase ($availability.Reason -ceq $reason -and $probe.failureClass -ceq $expected -and
      $probe.browserOff -eq ($reason -ceq 'browser-not-running') -and (Test-MathSecrSurfaceProbeReceipt $probe).Valid) "aside-$reason" classification
  }
  $raw=New-SurfaceProbeTestAsideReceipt;$availability=Get-MathSecrAsideAvailabilityFromProbe $raw
  $probe=ConvertFrom-MathSecrAsideProbeResult $raw $availability $url 'synthetic-cli-version'
  Assert-SurfaceProbeCase ($probe.failureClass -ceq 'none' -and $probe.identity.tabId -ceq 'synthetic-tab' -and
    $probe.identity.url -ceq $url -and $null -eq $probe.identity.profileOrSessionId -and $probe.identity.identityBasis -ceq 'aside-session' -and
    $probe.identity.version -ceq 'synthetic-cli-version') aside-paper-tab classification
  $probe=ConvertFrom-MathSecrAsideProbeResult $raw $availability ($url+'/') $null
  Assert-SurfaceProbeCase ($probe.failureClass -ceq 'read' -and $probe.diagnostic -ceq 'paper-tab-not-listed') aside-paper-not-listed classification
  $probe=ConvertFrom-MathSecrAsideProbeResult $raw $availability '' $null
  Assert-SurfaceProbeCase ($probe.failureClass -ceq 'none' -and $null -eq $probe.identity.tabId -and $null -eq $probe.identity.url) aside-no-paper classification
  $raw.exitCode=1;$raw.stderr="Failed to request daemon auth challenge: fetch failed`nAside isn't running on this machine."
  $probe=ConvertFrom-MathSecrAsideProbeResult $raw (Get-MathSecrAsideAvailabilityFromProbe $raw) $url $null
  Assert-SurfaceProbeCase ($probe.failureClass -ceq 'connect' -and -not $probe.browserOff) aside-mixed-transport classification

  foreach ($surface in @('codex-iab','codex-chrome-ext')) {
    $tool=New-SurfaceProbeTestToolReceipt $surface
    $probe=ConvertFrom-MathSecrCodexToolReceipt $surface $tool $artifact $url
    $basis=if ($surface -ceq 'codex-iab') {'codex-session'} else {'extension-instance'}
    $id=if ($surface -ceq 'codex-iab') {'synthetic-session'} else {'synthetic-extension-instance'}
    Assert-SurfaceProbeCase ($probe.failureClass -ceq 'none' -and $probe.identity.identityBasis -ceq $basis -and
      $probe.identity.profileOrSessionId -ceq $id -and $null -eq $probe.identity.version -and
      (Test-MathSecrSurfaceProbeReceipt $probe).Valid) "$surface-identity" classification
    $probe=ConvertFrom-MathSecrCodexToolReceipt $surface $null $null $url
    Assert-SurfaceProbeCase ($probe.failureClass -ceq 'install' -and $probe.diagnostic -ceq 'standalone-probe-command-unverified; tool receipt required (R3 §3)') "$surface-missing-tool" classification
    foreach ($field in @('schemaVersion','tool','surface','browser','tab')) {
      $tool=New-SurfaceProbeTestToolReceipt $surface;$tool.PSObject.Properties.Remove($field)
      Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt $surface $tool $artifact $url).failureClass -ceq 'read') "$surface-missing-$field" classification
    }
    $tool=New-SurfaceProbeTestToolReceipt $surface;$tool.browser.type='mcpapps'
    Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt $surface $tool $artifact $url).failureClass -ceq 'connect') "$surface-browser-kind" classification
    $tool=New-SurfaceProbeTestToolReceipt $surface;$tool.browser.metadata=[pscustomobject]@{}
    Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt $surface $tool $artifact $url).failureClass -ceq 'read') "$surface-missing-identity" classification
    $tool=New-SurfaceProbeTestToolReceipt $surface;$tool.tab.PSObject.Properties.Remove('id')
    Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt $surface $tool $artifact $url).failureClass -ceq 'read') "$surface-missing-tab" classification
    $tool=New-SurfaceProbeTestToolReceipt $surface;$tool.tab.url=$url+'/'
    Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt $surface $tool $artifact $url).failureClass -ceq 'read') "$surface-url-ordinal" classification
  }
  $tool=New-SurfaceProbeTestToolReceipt codex-iab
  Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt codex-chrome-ext $tool $artifact $url).failureClass -ceq 'read') cross-surface-before-kind classification
  $tool=New-SurfaceProbeTestToolReceipt codex-chrome-ext;$tool.browser.type='iab'
  Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt codex-chrome-ext $tool $artifact $url).failureClass -ceq 'connect') cross-kind-with-matching-surface classification
  $tool=New-SurfaceProbeTestToolReceipt codex-chrome-ext;$tool.browser.family='aside'
  Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt codex-chrome-ext $tool $artifact $url).failureClass -ceq 'connect') chrome-family classification
  Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt codex-iab 'not JSON' $artifact $url).failureClass -ceq 'read') codex-invalid-shape classification
  Assert-SurfaceProbeCase ((ConvertFrom-MathSecrCodexToolReceipt codex-iab $null $artifact $url).failureClass -ceq 'read') codex-json-null classification

  $module=Join-Path $root 'module';$browser=Join-Path $root 'browser'
  $null=New-Item -ItemType Directory -Path $module;[IO.File]::WriteAllText($browser,'')
  Assert-SurfaceProbeCase ((Get-MathSecrOfflineSurfaceProbe $module $browser).failureClass -ceq 'none') offline-paths classification
  Assert-SurfaceProbeCase ((Get-MathSecrOfflineSurfaceProbe ($module+'-absent') $browser).failureClass -ceq 'install') offline-missing-module classification
  Assert-SurfaceProbeCase ((Get-MathSecrOfflineSurfaceProbe $module ($browser+'-absent')).failureClass -ceq 'install') offline-missing-browser classification

  $valid=ConvertFrom-MathSecrCodexToolReceipt codex-iab (New-SurfaceProbeTestToolReceipt codex-iab) $artifact $url
  foreach ($class in @('none','install','connect','read','input')) {
    $probe=Copy-SurfaceProbeTestValue $valid;$probe.failureClass=$class
    Assert-SurfaceProbeCase (Test-MathSecrSurfaceProbeReceipt $probe).Valid "failureClass-$class" format-positive
  }
  foreach ($class in @('off','',$null)) {
    $probe=Copy-SurfaceProbeTestValue $valid;$probe.failureClass=$class
    Assert-SurfaceProbeCase (-not (Test-MathSecrSurfaceProbeReceipt $probe).Valid) "invalid-failureClass-$class" format-negative
  }
  foreach ($field in @('schemaVersion','surface','browserFamily','probedAtUtc','failureClass','browserOff','diagnostic','source','identity')) {
    $probe=Copy-SurfaceProbeTestValue $valid;$probe.PSObject.Properties.Remove($field)
    Assert-SurfaceProbeCase (-not (Test-MathSecrSurfaceProbeReceipt $probe).Valid) "missing-probe-$field" format-negative
  }
  $probe=Copy-SurfaceProbeTestValue $valid;$probe.surface='chrome'
  Assert-SurfaceProbeCase (-not (Test-MathSecrSurfaceProbeReceipt $probe).Valid) unsupported-surface format-negative
  $probe=Copy-SurfaceProbeTestValue $valid;$probe.browserFamily='chrome'
  Assert-SurfaceProbeCase (-not (Test-MathSecrSurfaceProbeReceipt $probe).Valid) mismatched-browser-family format-negative
  $probe=Copy-SurfaceProbeTestValue $valid;$probe.browserOff=$true;$probe.failureClass='connect'
  Assert-SurfaceProbeCase (-not (Test-MathSecrSurfaceProbeReceipt $probe).Valid) non-aside-browser-off format-negative
  $probe=Copy-SurfaceProbeTestValue $valid;$probe.identity.version=$null
  Assert-SurfaceProbeCase (Test-MathSecrSurfaceProbeReceipt $probe).Valid null-version format-positive
  foreach ($stamp in @('2026-10-11T00:00:00+00:00','2026-02-30T00:00:00Z',' 2026-10-11T00:00:00Z','not-a-date',$null)) {
    $probe=Copy-SurfaceProbeTestValue $valid;$probe.probedAtUtc=$stamp
    Assert-SurfaceProbeCase (-not (Test-MathSecrSurfaceProbeReceipt $probe).Valid) "invalid-utc-$stamp" format-negative
  }
  $probe=Copy-SurfaceProbeTestValue $valid;$probe.browserOff='false'
  Assert-SurfaceProbeCase (-not (Test-MathSecrSurfaceProbeReceipt $probe).Valid) string-boolean format-negative
  $probe=Copy-SurfaceProbeTestValue $valid;$probe.schemaVersion=$true
  Assert-SurfaceProbeCase (-not (Test-MathSecrSurfaceProbeReceipt $probe).Valid) boolean-schema-version format-negative

  $outputPath=Join-Path $root 'probe.json'
  $cli=Invoke-SurfaceProbeTestCli @('-Surface','ASIDE-REPL','-ProbeReceiptPath',$outputPath) $root
  Assert-SurfaceProbeCase ($cli.exitCode -ne 0 -and -not (Test-Path -LiteralPath $outputPath)) surface-case-no-fallback cli-negative
  $cli=Invoke-SurfaceProbeTestCli @('-Surface','aside-repl','-ProbeReceiptPath',$outputPath) $root
  $probe=ConvertFrom-MathSecrContractJson ([IO.File]::ReadAllText($outputPath))
  $legacy=ConvertFrom-MathSecrContractJson $cli.stdout
  Assert-SurfaceProbeCase ($cli.exitCode -eq 1 -and $probe.failureClass -ceq 'install' -and
    $legacy.Availability.Reason -ceq 'cli-unavailable' -and $null -ne $legacy.ProbeReceipt -and
    (Test-MathSecrSurfaceProbeReceipt $probe).Valid) aside-missing-cli cli-negative
  $before=[IO.File]::ReadAllText($outputPath)
  $cli=Invoke-SurfaceProbeTestCli @('-Surface','aside-repl','-ProbeReceiptPath',$outputPath) $root
  Assert-SurfaceProbeCase ($cli.exitCode -ne 0 -and [IO.File]::ReadAllText($outputPath) -ceq $before) create-new-no-overwrite cli-negative
  $cli=Invoke-SurfaceProbeTestCli @('-Surface','codex-iab') $root
  Assert-SurfaceProbeCase ($cli.exitCode -eq 1 -and (ConvertFrom-MathSecrContractJson $cli.stdout).failureClass -ceq 'install') codex-missing-tool-path cli-negative
  $toolPath=Join-Path $root 'tool.json'
  [IO.File]::WriteAllText($toolPath,(ConvertTo-Json -InputObject (New-SurfaceProbeTestToolReceipt codex-chrome-ext) -Depth 8))
  $cli=Invoke-SurfaceProbeTestCli @('-Surface','codex-chrome-ext','-ToolReceiptPath',$toolPath,'-PaperUrl',$url) $root
  $probe=ConvertFrom-MathSecrContractJson $cli.stdout
  Assert-SurfaceProbeCase ($cli.exitCode -eq 0 -and $probe.identity.identityBasis -ceq 'extension-instance' -and
    $probe.source.artifact.sha256 -ceq (Get-FileHash -LiteralPath $toolPath).Hash.ToLowerInvariant()) codex-tool-file cli-positive
  $singletonTool='['+(ConvertTo-Json -InputObject (New-SurfaceProbeTestToolReceipt codex-iab) -Depth 8 -Compress)+']'
  foreach ($case in @(@{name='malformed';content='not JSON'},@{name='null';content='null'},@{name='singleton-array';content=$singletonTool})) {
    [IO.File]::WriteAllText($toolPath,$case.content)
    $cli=Invoke-SurfaceProbeTestCli @('-Surface','codex-iab','-ToolReceiptPath',$toolPath,'-PaperUrl',$url) $root
    Assert-SurfaceProbeCase ($cli.exitCode -eq 1 -and (ConvertFrom-MathSecrContractJson $cli.stdout).failureClass -ceq 'read') "codex-invalid-json-$($case.name)" cli-negative
  }
  $cli=Invoke-SurfaceProbeTestCli @('-Surface','offline-dom-test','-PlaywrightModule',$module,'-BrowserPath',$browser) $root
  Assert-SurfaceProbeCase ($cli.exitCode -eq 0 -and (ConvertFrom-MathSecrContractJson $cli.stdout).failureClass -ceq 'none') offline-cli cli-positive
  Write-Output 'SurfaceProbe PASS'
} finally {
  $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
  if (-not $root.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetFileName($root) -notmatch '^mathsecr-surface-probe-[a-f0-9]{32}$') { throw 'SurfaceProbe cleanup target is outside its owned temp directory.' }
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
