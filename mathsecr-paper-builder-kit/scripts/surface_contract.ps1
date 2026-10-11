# Session-declared surfaces. Probe artifacts reuse the state contract's safe
# path resolver and the call-local validation context; no browser is inferred.
$MathSecrSupportedSurfaces = @('aside-repl','codex-iab','codex-chrome-ext','offline-dom-test')
$MathSecrSurfaceBrowserFamilies = @{
  'aside-repl'='aside'; 'codex-iab'='codex'; 'codex-chrome-ext'='chrome'; 'offline-dom-test'='playwright'
}

function Test-MathSecrSupportedSurface {
  param($Surface)
  return $Surface -is [string] -and $MathSecrSupportedSurfaces -ccontains $Surface
}

function Test-MathSecrSurfacePaperUrl {
  param($Surface, $Url)
  if (-not (Test-MathSecrSupportedSurface $Surface) -or $Url -isnot [string]) { return $false }
  if ($Surface -cne 'offline-dom-test') {
    return $Url -cmatch '\Ahttps://www\.mathsecr\.com/mypaper/[0-9]+\z'
  }
  $uri = $null
  return [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and
    $uri.IsFile -and $uri.Host -ceq '' -and
    $uri.LocalPath.Replace('\','/').EndsWith('/test-fixtures/iab-simulator/index.html', [StringComparison]::Ordinal)
}

function Get-MathSecrSurfacePropertyValue {
  param($Value, [string]$Name)
  if ($null -eq $Value) { return $null }
  $property = $Value.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Test-MathSecrSurfaceIdentityReceipt {
  param($Receipt, $PaperUrl, [string]$ProjectRoot, $Context)
  $errors = [Collections.Generic.List[string]]::new()
  $required = @('schemaVersion','surface','browserFamily','profileOrSessionId','tabId','url','observedAtUtc')
  if ($Receipt -isnot [pscustomobject] -or @($required | Where-Object {
      @($Receipt.PSObject.Properties.Name) -cnotcontains $_
    }).Count -gt 0) {
    return [pscustomobject]@{Valid=$false;Surface=$null;Errors=@('surface-identity-invalid')}
  }
  $surface = $Receipt.surface
  if (-not (Test-MathSecrSupportedSurface $surface)) { $errors.Add('surface-unsupported') }
  elseif ($Receipt.browserFamily -isnot [string] -or $Receipt.browserFamily -cne $MathSecrSurfaceBrowserFamilies[$surface]) {
    $errors.Add('surface-browser-family')
  }
  if ($Receipt.url -isnot [string] -or $PaperUrl -isnot [string] -or
      -not [string]::Equals($Receipt.url,$PaperUrl,[StringComparison]::Ordinal) -or
      -not (Test-MathSecrSurfacePaperUrl -Surface $surface -Url $Receipt.url)) { $errors.Add('surface-url') }
  $version = $Receipt.schemaVersion
  $integerVersion = $version -is [byte] -or $version -is [sbyte] -or $version -is [int16] -or
    $version -is [uint16] -or $version -is [int32] -or $version -is [uint32] -or
    $version -is [int64] -or $version -is [uint64]
  $observedAt = [DateTimeOffset]::MinValue
  if (-not $integerVersion -or $version -ne 1 -or
      $Receipt.profileOrSessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.profileOrSessionId) -or
      $Receipt.profileOrSessionId -cne $Receipt.profileOrSessionId.Trim() -or
      $Receipt.tabId -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.tabId) -or $Receipt.tabId -cne $Receipt.tabId.Trim() -or
      $Receipt.observedAtUtc -isnot [string] -or
      $Receipt.observedAtUtc -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z\z' -or
      -not [DateTimeOffset]::TryParse($Receipt.observedAtUtc,[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$observedAt) -or
      $observedAt.Offset -ne [TimeSpan]::Zero) { $errors.Add('surface-identity-invalid') }
  $probeProperty = $Receipt.PSObject.Properties['probeArtifact']
  if ($null -ne $probeProperty) {
    try {
      $probe = $probeProperty.Value
      if ($probe -isnot [pscustomobject] -or $probe.PSObject.Properties['path'] -eq $null -or
          $probe.PSObject.Properties['sha256'] -eq $null -or $probe.sha256 -isnot [string] -or
          $probe.sha256 -cnotmatch '\A[0-9a-fA-F]{64}\z') { throw 'Invalid probe artifact shape.' }
      $path = Resolve-MathSecrStateArtifactPath $ProjectRoot $probe.path
      if ($null -eq $path) { throw 'Invalid probe artifact path.' }
      $null = Get-MathSecrValidationArtifact -Path $path -ExpectedSha256 $probe.sha256 -Context $Context
    } catch {
      if (-not $errors.Contains('surface-identity-invalid')) { $errors.Add('surface-identity-invalid') }
    }
  }
  return [pscustomobject]@{Valid=($errors.Count -eq 0);Surface=$surface;Errors=$errors.ToArray()}
}

function Get-MathSecrSessionSurface {
  param($Session, $Context)
  if ($null -eq $Context -or $Context.ActiveDepth -le 0) {
    throw 'surface-identity-invalid: validation context must be active'
  }
  if ($null -eq $Session -or $Session.PSObject.Properties['surfaceIdentity'] -eq $null) { return 'aside-repl' }
  $paper = Get-MathSecrSurfacePropertyValue $Session 'paper'
  $url = Get-MathSecrSurfacePropertyValue $paper 'url'
  $identity = Test-MathSecrSurfaceIdentityReceipt -Receipt $Session.surfaceIdentity -PaperUrl $url -ProjectRoot $Context.ProjectRoot -Context $Context
  if (-not $identity.Valid) { throw "surface-identity-invalid: $($identity.Errors -join '; ')" }
  return $identity.Surface
}

function Test-MathSecrTargetObservationSurfaces {
  param($Target, [string]$Surface = 'aside-repl')
  $search = Get-MathSecrSurfacePropertyValue $Target 'searchAttemptReceipt'
  $metadata = Get-MathSecrSurfacePropertyValue $Target 'metadataRescue'
  $containers = @(Get-MathSecrSurfacePropertyValue $search 'attempts') +
    @(Get-MathSecrSurfacePropertyValue $search 'phrasePrepass') +
    @(Get-MathSecrSurfacePropertyValue $metadata 'buckets')
  foreach ($container in $containers) {
    if ($null -eq $container) { continue }
    $property = $container.PSObject.Properties['observationReceipt']
    if ($null -eq $property) { continue }
    $submission = Get-MathSecrSurfacePropertyValue $property.Value 'submission'
    $observedSurface = Get-MathSecrSurfacePropertyValue $submission 'surface'
    if ($observedSurface -isnot [string] -or $observedSurface -cne $Surface) { return $false }
  }
  return $true
}
