param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$FixturePath,
  [string]$BundlePath
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -cne $Expected) {
    throw "$Message. Expected '$Expected', got '$Actual'"
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

$fixturePath = if ($FixturePath) {
  [System.IO.Path]::GetFullPath($FixturePath)
} else {
  Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\year-range-serialization\bundle-observation.json"
}
$fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
$provenance = $fixture.provenance
$claimScope = $fixture.claimScope
$observed = $fixture.observedSerialization

Assert-Equal $fixture.schema_version 3 "Pinned serializer-guard schema"
Assert-Equal $provenance.kind "pinned_serializer_guard_observation" "Pinned serializer-guard kind"
Assert-True ($provenance.sourceUrl -match "^https://www\.mathsecr\.com/_next/static/chunks/[A-Za-z0-9._-]+\.js$") "Pinned observation sourceUrl must identify a MathSecr static JavaScript bundle"
$capturedAt = [System.DateTimeOffset]::MinValue
Assert-True ([System.DateTimeOffset]::TryParse([string]$provenance.capturedAt, [ref]$capturedAt)) "Pinned observation capturedAt must be an ISO-compatible timestamp"
Assert-True ($capturedAt.Offset -ne [System.TimeSpan]::Zero) "Pinned observation capturedAt must preserve the observed timezone offset"
Assert-True ([long]$provenance.bundleLength -gt 0) "Pinned observation bundleLength must be positive"
Assert-True ([string]$provenance.bundleSha256 -match "^[A-Fa-f0-9]{64}$") "Pinned observation bundleSha256 must be a SHA-256 hexadecimal digest"
Assert-Equal $provenance.bundleIncludedInFixture $false "Pinned observation bundled-source flag"
Assert-Equal $provenance.reproducibleLiveProof $false "Pinned observation live-proof flag"
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$provenance.scopeNote)) "Pinned observation scopeNote must explain its non-live limitation"

Assert-Equal $claimScope.productContract "pinned_serializer_guard_for_already_normalized_numeric_tuple_input" "Pinned product-contract scope"
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$claimScope.inputAssumption)) "Pinned serializer guard must state its input assumption"
Assert-Equal $claimScope.upstreamNormalizationPinned $false "Upstream normalization pin flag"
Assert-Equal @($claimScope.proves).Count 1 "Pinned serializer-guard proof count"
Assert-Equal $claimScope.proves[0] "the observed serializer guard requires two defined ordered tuple values before assigning sourceStartYear and sourceEndYear" "Pinned serializer-guard proof"
Assert-Equal @($claimScope.doesNotProve).Count 3 "Pinned serializer-guard exclusion count"
Assert-Equal $claimScope.doesNotProve[0] "raw string, blank, null, partial, NaN, or Infinity rejection by MathSecr" "Pinned serializer-guard raw-input exclusion"
Assert-Equal $claimScope.doesNotProve[1] "the current live site's upstream year normalization" "Pinned serializer-guard live-normalization exclusion"
Assert-Equal $claimScope.doesNotProve[2] "UI-level year filter semantics" "Pinned serializer-guard UI exclusion"

Assert-Equal $observed.sourceFragment "n&&2===n.length){let[e,r]=n;void 0!==e&&void 0!==r&&e<=r&&(t.sourceStartYear=e,t.sourceEndYear=r)" "Captured bundle year-range guard"
Assert-Equal @($observed.fields).Count 2 "Captured bundle serialized field count"
Assert-Equal $observed.fields[0] "sourceStartYear" "Captured bundle first serialized field"
Assert-Equal $observed.fields[1] "sourceEndYear" "Captured bundle second serialized field"
Assert-True ($observed.sourceFragment.Contains([string]$observed.fields[0]) -and $observed.sourceFragment.Contains([string]$observed.fields[1])) "Pinned fragment must contain both serialized fields"

$bundleVerified = $false
if ($BundlePath) {
  $resolvedBundle = [System.IO.Path]::GetFullPath($BundlePath)
  Assert-True (Test-Path -LiteralPath $resolvedBundle -PathType Leaf) "Observed bundle path does not exist: $resolvedBundle"
  Assert-Equal (Get-Item -LiteralPath $resolvedBundle).Length ([long]$provenance.bundleLength) "Observed bundle byte length"
  Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedBundle).Hash.ToUpperInvariant() ([string]$provenance.bundleSha256).ToUpperInvariant() "Observed bundle SHA-256"
  $bundleText = Get-Content -LiteralPath $resolvedBundle -Raw -Encoding UTF8
  Assert-True ($bundleText.Contains([string]$observed.sourceFragment)) "Observed bundle does not contain the pinned year-range fragment"
  $bundleVerified = $true
}

Write-Host "YearRangeSerializerGuard PASS assumption=already_normalized_numeric_tuple proves=defined_ordered_field_emission upstream_normalization_pinned=false live_reproducible=false bundle_verified=$($bundleVerified.ToString().ToLowerInvariant())"
