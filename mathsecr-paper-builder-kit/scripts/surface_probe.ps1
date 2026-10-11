# Pure conversion and format checks. No CLI, tool API or browser is invoked.
function Test-MathSecrSurfaceProbeJsonObject {
  param([AllowEmptyCollection()][byte[]]$Bytes)
  if ($null -eq $Bytes) { return $false }
  $offset=if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {3} else {0}
  try {
    $document=[System.Text.Json.JsonDocument]::Parse([Text.Encoding]::UTF8.GetString($Bytes,$offset,$Bytes.Length-$offset))
    try { return $document.RootElement.ValueKind -eq [System.Text.Json.JsonValueKind]::Object }
    finally { $document.Dispose() }
  } catch { return $false }
}

function Get-MathSecrProbeProperty {
  param($Value,[string]$Name)
  if ($null -eq $Value) { return $null }
  $property=$Value.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-MathSecrProbeBrowserFamily {
  param($Surface)
  switch -CaseSensitive ($Surface) {
    'aside-repl' { return 'aside' }
    'codex-iab' { return 'codex' }
    'codex-chrome-ext' { return 'chrome' }
    'offline-dom-test' { return 'playwright' }
    default { return $null }
  }
}

function Test-MathSecrProbeFields {
  param($Value,[string[]]$Names)
  return $Value -is [pscustomobject] -and @($Names | Where-Object {
    @($Value.PSObject.Properties.Name) -cnotcontains $_
  }).Count -eq 0
}

function New-MathSecrSurfaceProbeReceipt {
  param([string]$Surface,[string]$SourceKind)
  return [pscustomobject]@{
    schemaVersion=1;surface=$Surface;browserFamily=(Get-MathSecrProbeBrowserFamily $Surface)
    probedAtUtc=[DateTime]::UtcNow.ToString('o');failureClass='read';browserOff=$false;diagnostic=''
    source=[pscustomobject]@{kind=$SourceKind;artifact=$null}
    identity=[pscustomobject]@{identityBasis=$null;profileOrSessionId=$null;tabId=$null;url=$null;version=$null}
  }
}

function ConvertFrom-MathSecrAsideProbeResult {
  param($ProbeReceipt,$Availability,[string]$PaperUrl,$CliVersion)
  $result=New-MathSecrSurfaceProbeReceipt aside-repl aside-cli
  $result.identity.identityBasis='aside-session'
  if ($CliVersion -is [string] -and -not [string]::IsNullOrWhiteSpace($CliVersion)) { $result.identity.version=$CliVersion }
  $reason=Get-MathSecrProbeProperty $Availability 'Reason'
  if ($reason -is [string]) { $result.diagnostic=$reason }
  switch -CaseSensitive ($reason) {
    'repl-reachable' { $result.failureClass='none' }
    'cli-unavailable' { $result.failureClass='install' }
    'probe-timeout' { $result.failureClass='connect' }
    'probe-auth-or-transport-failed' { $result.failureClass='connect' }
    'browser-not-running' { $result.failureClass='connect';$result.browserOff=$true }
    default { $result.failureClass='read' }
  }
  if ($reason -ceq 'repl-reachable' -and $PaperUrl) {
    $rows=@(foreach ($line in @((Get-MathSecrProbeProperty $ProbeReceipt 'stdout') -split '\r?\n')) {
      try { $value=ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
      if ((Get-MathSecrProbeProperty $value 'kind') -ceq 'mathsecr-aside-preflight-v1') {
        @(Get-MathSecrProbeProperty $value 'tabs')
      }
    })
    $row=@($rows | Where-Object {
      [string]::Equals((Get-MathSecrProbeProperty $_ 'url'),$PaperUrl,[StringComparison]::Ordinal)
    } | Select-Object -First 1)
    if ($row.Count -eq 0) {
      $result.failureClass='read';$result.diagnostic='paper-tab-not-listed'
    } else {
      $tabId=Get-MathSecrProbeProperty $row[0] 'targetId'
      if ($tabId -is [string] -and -not [string]::IsNullOrWhiteSpace($tabId)) {
        $result.identity.tabId=$tabId;$result.identity.url=Get-MathSecrProbeProperty $row[0] 'url'
      } else { $result.failureClass='read' }
    }
  }
  return $result
}

function ConvertFrom-MathSecrCodexToolReceipt {
  param([ValidateSet('codex-iab','codex-chrome-ext',IgnoreCase=$false)][string]$Surface,$ToolReceipt,$ToolReceiptArtifact,[string]$PaperUrl)
  $result=New-MathSecrSurfaceProbeReceipt $Surface codex-tool-receipt
  $result.source.artifact=$ToolReceiptArtifact
  if ($null -eq $ToolReceipt) {
    if ($null -ne $ToolReceiptArtifact) { return $result }
    $result.failureClass='install'
    $result.diagnostic='standalone-probe-command-unverified; tool receipt required (R3 §3)'
    return $result
  }
  # Ordered classification: header/surface, browser kind, identity, tab binding.
  if (-not (Test-MathSecrProbeFields $ToolReceipt @('schemaVersion','tool','surface','browser','tab')) -or
      ($ToolReceipt.schemaVersion -isnot [int] -and $ToolReceipt.schemaVersion -isnot [long]) -or $ToolReceipt.schemaVersion -ne 1 -or
      $ToolReceipt.tool -cne 'mcp__cua_repl' -or $ToolReceipt.surface -cne $Surface -or
      $ToolReceipt.browser -isnot [pscustomobject] -or $ToolReceipt.tab -isnot [pscustomobject]) { return $result }
  $type=Get-MathSecrProbeProperty $ToolReceipt.browser 'type'
  $family=Get-MathSecrProbeProperty $ToolReceipt.browser 'family'
  if (($Surface -ceq 'codex-iab' -and $type -cne 'iab') -or
      ($Surface -ceq 'codex-chrome-ext' -and ($type -cne 'extension' -or $family -cne 'chrome'))) {
    $result.failureClass='connect';return $result
  }
  $metadata=Get-MathSecrProbeProperty $ToolReceipt.browser 'metadata'
  $idName=if ($Surface -ceq 'codex-iab') { 'codexSessionId' } else { 'extensionInstanceId' }
  $sessionId=Get-MathSecrProbeProperty $metadata $idName
  if ($sessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($sessionId)) { return $result }
  $tabId=Get-MathSecrProbeProperty $ToolReceipt.tab 'id'
  $url=Get-MathSecrProbeProperty $ToolReceipt.tab 'url'
  if ($tabId -isnot [string] -or [string]::IsNullOrWhiteSpace($tabId) -or $url -isnot [string] -or
      [string]::IsNullOrWhiteSpace($PaperUrl) -or -not [string]::Equals($url,$PaperUrl,[StringComparison]::Ordinal)) { return $result }
  $result.identity.identityBasis=if ($Surface -ceq 'codex-iab') { 'codex-session' } else { 'extension-instance' }
  $result.identity.profileOrSessionId=$sessionId;$result.identity.tabId=$tabId;$result.identity.url=$url
  $result.failureClass='none'
  return $result
}

function Get-MathSecrOfflineSurfaceProbe {
  param([string]$PlaywrightModule,[string]$BrowserPath)
  $result=New-MathSecrSurfaceProbeReceipt offline-dom-test offline-check
  $result.failureClass=if ($PlaywrightModule -and $BrowserPath -and
    (Test-Path -LiteralPath $PlaywrightModule) -and (Test-Path -LiteralPath $BrowserPath)) { 'none' } else { 'install' }
  return $result
}

function Test-MathSecrSurfaceProbeReceipt {
  param($Receipt)
  $errors=[Collections.Generic.List[string]]::new()
  if (-not (Test-MathSecrProbeFields $Receipt @('schemaVersion','surface','browserFamily','probedAtUtc','failureClass','browserOff','diagnostic','source','identity'))) {
    return [pscustomobject]@{Valid=$false;Errors=@('surface-identity-invalid')}
  }
  $family=Get-MathSecrProbeBrowserFamily $Receipt.surface
  if ($Receipt.surface -isnot [string] -or $null -eq $family) { $errors.Add('surface-unsupported') }
  elseif ($Receipt.browserFamily -isnot [string] -or $Receipt.browserFamily -cne $family) { $errors.Add('surface-browser-family') }
  $version=$Receipt.schemaVersion
  $integerVersion=$version -is [byte] -or $version -is [sbyte] -or $version -is [int16] -or
    $version -is [uint16] -or $version -is [int32] -or $version -is [uint32] -or $version -is [int64] -or $version -is [uint64]
  $time=[DateTimeOffset]::MinValue
  $invalid=-not $integerVersion -or $version -ne 1 -or
    $Receipt.failureClass -isnot [string] -or @('none','install','connect','read','input') -cnotcontains $Receipt.failureClass -or
    $Receipt.browserOff -isnot [bool] -or ($Receipt.browserOff -and ($Receipt.surface -cne 'aside-repl' -or $Receipt.failureClass -cne 'connect')) -or
    $Receipt.diagnostic -isnot [string] -or $Receipt.probedAtUtc -isnot [string] -or
    $Receipt.probedAtUtc -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z\z' -or
    -not [DateTimeOffset]::TryParse($Receipt.probedAtUtc,[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$time) -or $time.Offset -ne [TimeSpan]::Zero
  if (-not (Test-MathSecrProbeFields $Receipt.source @('kind','artifact')) -or
      $Receipt.source.kind -isnot [string] -or @('aside-cli','codex-tool-receipt','offline-check') -cnotcontains $Receipt.source.kind) { $invalid=$true }
  else {
    $artifact=$Receipt.source.artifact
    if ($null -ne $artifact -and (-not (Test-MathSecrProbeFields $artifact @('path','sha256')) -or
        $artifact.path -isnot [string] -or [string]::IsNullOrWhiteSpace($artifact.path) -or
        $artifact.sha256 -isnot [string] -or $artifact.sha256 -cnotmatch '\A[0-9a-fA-F]{64}\z')) { $invalid=$true }
  }
  if (-not (Test-MathSecrProbeFields $Receipt.identity @('identityBasis','profileOrSessionId','tabId','url','version'))) { $invalid=$true }
  else {
    $basis=$Receipt.identity.identityBasis
    if ($null -ne $basis -and ($basis -isnot [string] -or @('aside-session','codex-session','extension-instance') -cnotcontains $basis)) { $invalid=$true }
    foreach ($name in @('profileOrSessionId','tabId','url','version')) {
      $value=$Receipt.identity.$name
      if ($null -ne $value -and $value -isnot [string]) { $invalid=$true }
    }
  }
  if ($invalid) { $errors.Add('surface-identity-invalid') }
  return [pscustomobject]@{Valid=($errors.Count -eq 0);Errors=$errors.ToArray()}
}
