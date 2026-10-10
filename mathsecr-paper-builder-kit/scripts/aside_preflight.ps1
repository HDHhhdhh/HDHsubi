# Receipt validation only. The CLI probe records actual execution separately.
function Get-MathSecrAsideAvailabilityFromProbe {
  param($ProbeReceipt)
  $invalid = [pscustomobject]@{ Valid=$false; Status='unavailable'; UserResponse=$null; Reason='invalid-probe-receipt' }
  if ($null -eq $ProbeReceipt -or $ProbeReceipt -isnot [pscustomobject]) { return $invalid }
  foreach ($name in @('schemaVersion','probeCommand','checkId','startedAtUtc','completedAtUtc','executable','exitCode','timedOut','stdout','stderr')) {
    if ($null -eq $ProbeReceipt.PSObject.Properties[$name]) { return $invalid }
  }
  if (($ProbeReceipt.schemaVersion -isnot [int] -and $ProbeReceipt.schemaVersion -isnot [long]) -or $ProbeReceipt.schemaVersion -ne 1 -or
      $ProbeReceipt.probeCommand -cne 'skills-list-and-listBrowserTabs' -or
      $ProbeReceipt.checkId -isnot [string] -or $ProbeReceipt.checkId -cnotmatch '^[0-9a-f]{32}$' -or
      $ProbeReceipt.executable -isnot [string] -or $ProbeReceipt.timedOut -isnot [bool] -or
      $ProbeReceipt.stdout -isnot [string] -or $ProbeReceipt.stderr -isnot [string]) { return $invalid }
  foreach ($name in @('startedAtUtc','completedAtUtc')) {
    $time = [DateTimeOffset]::MinValue
    if ($ProbeReceipt.$name -isnot [string] -or $ProbeReceipt.$name -cnotmatch 'Z$' -or
        -not [DateTimeOffset]::TryParse($ProbeReceipt.$name, [ref]$time)) { return $invalid }
  }
  if ([DateTimeOffset]::Parse($ProbeReceipt.startedAtUtc) -gt [DateTimeOffset]::Parse($ProbeReceipt.completedAtUtc) -or
      ($null -ne $ProbeReceipt.exitCode -and $ProbeReceipt.exitCode -isnot [int] -and $ProbeReceipt.exitCode -isnot [long])) { return $invalid }
  if ($ProbeReceipt.timedOut) {
    return [pscustomobject]@{ Valid=$true; Status='unavailable'; UserResponse=$null; Reason='probe-timeout' }
  }
  if ([string]::IsNullOrWhiteSpace($ProbeReceipt.executable) -or $null -eq $ProbeReceipt.exitCode) {
    return [pscustomobject]@{ Valid=$true; Status='unavailable'; UserResponse=$null; Reason='cli-unavailable' }
  }
  # The CLI can append its not-running diagnostic after a failed daemon
  # handshake. Such mixed output establishes a probe failure, not browser exit.
  $diagnostics = $ProbeReceipt.stdout + "`n" + $ProbeReceipt.stderr
  if ($ProbeReceipt.exitCode -ne 0 -and
      ($diagnostics.Contains('Failed to request daemon auth challenge:') -or $diagnostics.Contains('fetch failed'))) {
    return [pscustomobject]@{ Valid=$true; Status='unavailable'; UserResponse=$null; Reason='probe-auth-or-transport-failed' }
  }
  # This branch recognizes the CLI diagnostic only; it does not independently
  # verify an OS window's lifecycle.
  if ($ProbeReceipt.exitCode -ne 0 -and ($ProbeReceipt.stderr.Contains("Aside isn't running on this machine.") -or
      $ProbeReceipt.stdout.Contains("Aside isn't running on this machine."))) {
    return [pscustomobject]@{ Valid=$true; Status='off'; UserResponse='aside 키고 다시 오도록.'; Reason='browser-not-running' }
  }
  if ($ProbeReceipt.exitCode -eq 0) {
    $matches = @()
    foreach ($line in @($ProbeReceipt.stdout -split '\r?\n')) {
      try { $value = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
      if ($value -is [pscustomobject] -and $null -ne $value.PSObject.Properties['kind'] -and
          $value.kind -ceq 'mathsecr-aside-preflight-v1') { $matches += $value }
    }
    if ($matches.Count -eq 1 -and $null -ne $matches[0].PSObject.Properties['tabCount'] -and
        ($matches[0].tabCount -is [int] -or $matches[0].tabCount -is [long]) -and $matches[0].tabCount -ge 0) {
      return [pscustomobject]@{ Valid=$true; Status='ready'; UserResponse=$null; Reason='repl-reachable' }
    }
  }
  return [pscustomobject]@{ Valid=$true; Status='unavailable'; UserResponse=$null; Reason='probe-failed-or-unrecognized' }
}

function Get-MathSecrAsideUserResponse {
  param($ProbeReceipt)
  $result = Get-MathSecrAsideAvailabilityFromProbe $ProbeReceipt
  if ($result.Valid -and $result.Status -ceq 'off') { return $result.UserResponse }
  return $null
}
