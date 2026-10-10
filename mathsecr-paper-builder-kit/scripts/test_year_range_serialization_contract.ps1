param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$Case = "All"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

. (Join-Path $PSScriptRoot "year_range_serialization.ps1")

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)

  if ($Actual -cne $Expected) {
    throw "$Message. Expected '$Expected', got '$Actual'"
  }
}

function Assert-Payload {
  param(
    [pscustomobject]$Actual,
    [pscustomobject]$Expected,
    [string]$Message
  )

  if ($null -eq $Actual) {
    throw "$Message returned null instead of an empty payload object"
  }

  $actualNames = @($Actual.PSObject.Properties.Name | Where-Object { $null -ne $_ })
  $expectedNames = @($Expected.PSObject.Properties.Name | Where-Object { $null -ne $_ })
  Assert-Equal $actualNames.Count $expectedNames.Count "$Message field count"
  for ($index = 0; $index -lt $expectedNames.Count; $index++) {
    Assert-Equal $actualNames[$index] $expectedNames[$index] "$Message field name at index $index"
    Assert-Equal $Actual.($actualNames[$index]) $Expected.($expectedNames[$index]) "$Message field value for $($expectedNames[$index])"
  }
  if ($actualNames -contains "status") {
    throw "$Message returned a misleading status field instead of a payload-only result"
  }
}

function Assert-BaselineRejects {
  param(
    [string]$Name,
    [scriptblock]$Mutate,
    [string]$ExpectedText,
    [string]$TempDirectory
  )

  $sourceFixture = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\year-range-serialization\bundle-observation.json"
  $fixture = Get-Content -LiteralPath $sourceFixture -Raw -Encoding UTF8 | ConvertFrom-Json
  & $Mutate $fixture
  $tempFixture = Join-Path $TempDirectory "$Name.json"
  $fixture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempFixture -Encoding UTF8

  $baselinePath = Join-Path $PSScriptRoot "test_year_range_serialization_baseline.ps1"
  $priorErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $baselinePath -ProjectRoot $ProjectRoot -FixturePath $tempFixture 2>&1) -join "`n"
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $priorErrorAction
  }
  if ($exitCode -eq 0) {
    throw "Corrupt pinned-observation fixture unexpectedly passed: $Name"
  }
  if ($output -notlike "*$ExpectedText*") {
    throw "Corrupt pinned-observation fixture '$Name' failed for an unexpected reason: $output"
  }
}

$fixturePath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\year-range-serialization\cases.json"
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
$contract = $fixture.contract
Assert-Equal $fixture.schema_version 2 "Local adapter fixture schema"
Assert-Equal $contract.kind "conservative_local_cli_adapter" "Local adapter contract kind"
Assert-Equal $contract.product_behavior_evidence $false "Local adapter product-evidence flag"
if ([string]::IsNullOrWhiteSpace([string]$contract.scope)) { throw "Local adapter fixture must state its non-product scope" }
$cases = @($fixture.cases | Where-Object { $Case -eq "All" -or $_.name -eq $Case })
if ($cases.Count -eq 0) {
  throw "No year-range fixture matched case: $Case"
}

foreach ($fixtureCase in $cases) {
  $actual = ConvertTo-LocalYearRangePayload -StartYear $fixtureCase.input.start -EndYear $fixtureCase.input.end
  Assert-Payload $actual $fixtureCase.expect "local adapter $($fixtureCase.name)"
}

$warmPayload = ConvertTo-LocalYearRangePayload -StartYear 2002 -EndYear 2026
Assert-Payload $warmPayload ([pscustomobject]@{ sourceStartYear = 2002; sourceEndYear = 2026 }) "local adapter stale-state warm payload"
$stalePayload = ConvertTo-LocalYearRangePayload -StartYear "invalid" -EndYear 2026
Assert-Payload $stalePayload ([pscustomobject]@{}) "local adapter stale-state invalid payload"

$nonFiniteCases = [ordered]@{
  nan = [double]::NaN
  positive_infinity = [double]::PositiveInfinity
  negative_infinity = [double]::NegativeInfinity
}
foreach ($name in $nonFiniteCases.Keys) {
  Assert-Payload (ConvertTo-LocalYearRangePayload -StartYear $nonFiniteCases[$name] -EndYear 2026) ([pscustomobject]@{}) "local adapter non-finite lower $name"
  Assert-Payload (ConvertTo-LocalYearRangePayload -StartYear 2002 -EndYear $nonFiniteCases[$name]) ([pscustomobject]@{}) "local adapter non-finite upper $name"
}

$serializerPath = Join-Path $PSScriptRoot "year_range_serialization.ps1"
$validJson = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $serializerPath -StartYear 2002 -EndYear 2026) -join "`n").Trim()
$reversedJson = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $serializerPath -StartYear 2026 -EndYear 2002) -join "`n").Trim()
$nonnumericJson = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$serializerPath' -StartYear invalid -EndYear 2026" 2>&1) -join "`n").Trim()
$blankJson = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$serializerPath' -StartYear '' -EndYear 2026" 2>&1) -join "`n").Trim()
$partialJson = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $serializerPath -EndYear 2026) -join "`n").Trim()
$partialUpperJson = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $serializerPath -StartYear 2002) -join "`n").Trim()
Assert-Equal $validJson '{"sourceStartYear":2002,"sourceEndYear":2026}' "CLI valid range JSON"
Assert-Equal $reversedJson '{}' "CLI reversed range JSON"
Assert-Equal $nonnumericJson '{}' "CLI nonnumeric range JSON"
Assert-Equal $blankJson '{}' "CLI blank range JSON"
Assert-Equal $partialJson '{}' "CLI partial range JSON"
Assert-Equal $partialUpperJson '{}' "CLI partial upper range JSON"
Assert-Payload ($validJson | ConvertFrom-Json) ([pscustomobject]@{ sourceStartYear = 2002; sourceEndYear = 2026 }) "CLI valid parsed payload"
Assert-Payload ($reversedJson | ConvertFrom-Json) ([pscustomobject]@{}) "CLI reversed parsed payload"
Assert-Payload ($nonnumericJson | ConvertFrom-Json) ([pscustomobject]@{}) "CLI nonnumeric parsed payload"
Assert-Payload ($blankJson | ConvertFrom-Json) ([pscustomobject]@{}) "CLI blank parsed payload"
Assert-Payload ($partialJson | ConvertFrom-Json) ([pscustomobject]@{}) "CLI partial parsed payload"
Assert-Payload ($partialUpperJson | ConvertFrom-Json) ([pscustomobject]@{}) "CLI partial upper parsed payload"

$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("mathsecr-year-contract-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDirectory | Out-Null
try {
  Assert-BaselineRejects -Name "foreign-url" -TempDirectory $tempDirectory -ExpectedText "sourceUrl must identify" -Mutate {
    param($Fixture)
    $Fixture.provenance.sourceUrl = "https://example.invalid/bundle.js"
  }
  Assert-BaselineRejects -Name "malformed-digest" -TempDirectory $tempDirectory -ExpectedText "bundleSha256 must be" -Mutate {
    param($Fixture)
    $Fixture.provenance.bundleSha256 = "not-a-sha256"
  }
  Assert-BaselineRejects -Name "false-live-proof" -TempDirectory $tempDirectory -ExpectedText "live-proof flag" -Mutate {
    param($Fixture)
    $Fixture.provenance.reproducibleLiveProof = $true
  }
  Assert-BaselineRejects -Name "false-upstream-normalization-proof" -TempDirectory $tempDirectory -ExpectedText "Upstream normalization pin flag" -Mutate {
    param($Fixture)
    $Fixture.claimScope.upstreamNormalizationPinned = $true
  }
  Assert-BaselineRejects -Name "missing-field-fragment" -TempDirectory $tempDirectory -ExpectedText "Captured bundle year-range guard" -Mutate {
    param($Fixture)
    $Fixture.observedSerialization.sourceFragment = "sourceStartYear"
  }
} finally {
  Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "YearRangeLocalAdapter PASS fixtures=$($cases.Count) nonfinite_direct_probes=6 invalid_input_policy=conservative_local_only product_behavior_evidence=false"
Write-Host "YearRangeSerializerGuardFixture PASS corrupt_scope_or_provenance_rejections=5"
