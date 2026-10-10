param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$Case = "All"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

. (Join-Path $PSScriptRoot "db_inference.ps1")

function Assert-DbInferenceEqual {
  param($Actual, $Expected, [string]$Message)

  if ($null -eq $Actual -and $null -eq $Expected) {
    return
  }
  if ($null -eq $Actual -or $null -eq $Expected -or $Actual -cne $Expected) {
    $expectedText = if ($null -eq $Expected) { "<null>" } else { [string]$Expected }
    $actualText = if ($null -eq $Actual) { "<null>" } else { [string]$Actual }
    throw "$Message. Expected '$expectedText', got '$actualText'."
  }
}

function Assert-DbInferenceBoolean {
  param($Value, [string]$Message)

  if ($Value -isnot [bool]) {
    throw "$Message. Expected a strict Boolean, got '$($Value.GetType().FullName)'."
  }
}

$fixturePath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\db-inference\cases.json"
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
Assert-DbInferenceEqual $fixture.schemaVersion 2 "Fixture schema version"
if ($fixture.cases -isnot [System.Array]) {
  throw "Fixture cases must be an array."
}

$cases = @($fixture.cases | Where-Object { $Case -eq "All" -or $_.name -ceq $Case })
if ($cases.Count -eq 0) {
  throw "No DB-inference fixture matched case: $Case"
}

foreach ($fixtureCase in $cases) {
  $hasExpectedError = $null -ne $fixtureCase.PSObject.Properties["expectError"]
  if ($hasExpectedError) {
    $caught = $null
    try {
      [void](Invoke-MathSecrDbInference $fixtureCase.input)
    } catch {
      $caught = $_
    }
    if ($null -eq $caught) {
      throw "$($fixtureCase.name) expected validation failure, but inference succeeded."
    }
    if ($caught.Exception.Message -cnotlike "*$($fixtureCase.expectError)*") {
      throw "$($fixtureCase.name) wrong validation error. Expected '*$($fixtureCase.expectError)*', got '$($caught.Exception.Message)'."
    }
    continue
  }

  if ($null -eq $fixtureCase.PSObject.Properties["expect"]) {
    throw "$($fixtureCase.name) must provide expect or expectError."
  }

  $result = Invoke-MathSecrDbInference $fixtureCase.input
  Assert-DbInferenceEqual $result.Status $fixtureCase.expect.status "$($fixtureCase.name) aggregate status"

  $expectedResults = @($fixtureCase.expect.results)
  $actualResults = @($result.Results)
  Assert-DbInferenceEqual $actualResults.Count $expectedResults.Count "$($fixtureCase.name) cluster result count"

  for ($resultIndex = 0; $resultIndex -lt $expectedResults.Count; $resultIndex++) {
    $expected = $expectedResults[$resultIndex]
    $actual = $actualResults[$resultIndex]
    $label = "$($fixtureCase.name) result[$resultIndex]"
    Assert-DbInferenceEqual $actual.ClusterId $expected.clusterId "$label clusterId"
    Assert-DbInferenceEqual $actual.Status $expected.status "$label status"
    Assert-DbInferenceEqual $actual.InferredScope $expected.inferredScope "$label inferred scope"
    Assert-DbInferenceEqual $actual.InferredCollection $expected.inferredCollection "$label inferred collection"
    Assert-DbInferenceEqual $actual.ScopeType $expected.scopeType "$label scope type"
    Assert-DbInferenceEqual $actual.Confidence $expected.confidence "$label confidence"
    Assert-DbInferenceEqual $actual.Reason $expected.reason "$label reason"
    Assert-DbInferenceBoolean $actual.Receipts.BlankProbe.ReadOnly "$label blank-probe read-only receipt type"
    Assert-DbInferenceBoolean $actual.Receipts.BlankProbe.Submitted "$label blank-probe submit receipt type"
    Assert-DbInferenceBoolean $actual.Receipts.BlankProbe.FreshResultVerified "$label blank-probe fresh receipt type"
    Assert-DbInferenceBoolean $actual.Receipts.BlankProbe.FreshSearchReceiptReady "$label blank-probe phase-ready type"
    Assert-DbInferenceBoolean $actual.Receipts.ScopeLock.SelectorSearchCleared "$label selector-clear receipt type"
    Assert-DbInferenceBoolean $actual.Receipts.ScopeLock.ScopeReceiptVerified "$label scope receipt type"
    Assert-DbInferenceBoolean $actual.Receipts.ScopeLock.ScopeIdentityMatches "$label scope identity type"
    Assert-DbInferenceBoolean $actual.Receipts.ScopedSearch.Submitted "$label scoped submit receipt type"
    Assert-DbInferenceBoolean $actual.Receipts.ScopedSearch.FreshResultVerified "$label scoped fresh receipt type"
    Assert-DbInferenceBoolean $actual.Receipts.ScopedSearch.ScopeIdentityMatches "$label scoped identity type"
    Assert-DbInferenceBoolean $actual.Receipts.ScopeLockReady "$label scope-lock receipt type"
    Assert-DbInferenceBoolean $actual.Receipts.FreshSearchReceiptReady "$label fresh-search receipt type"
    Assert-DbInferenceEqual $actual.Receipts.ScopeLockReady ([bool]$expected.scopeLockReady) "$label scope-lock receipt"
    Assert-DbInferenceEqual $actual.Receipts.FreshSearchReceiptReady ([bool]$expected.freshSearchReceiptReady) "$label fresh-search receipt"
  }

  Assert-DbInferenceBoolean $result.ScopeLockReady "$($fixtureCase.name) aggregate scope-lock receipt type"
  Assert-DbInferenceBoolean $result.FreshSearchReceiptReady "$($fixtureCase.name) aggregate fresh-search receipt type"
  $expectedAggregateScopeLockReady = ($fixtureCase.expect.status -ceq "inferred") -and @($expectedResults | Where-Object { -not [bool]$_.scopeLockReady }).Count -eq 0
  $expectedAggregateFreshSearchReady = $expectedAggregateScopeLockReady -and @($expectedResults | Where-Object { -not [bool]$_.freshSearchReceiptReady }).Count -eq 0
  Assert-DbInferenceEqual $result.ScopeLockReady $expectedAggregateScopeLockReady "$($fixtureCase.name) aggregate scope-lock receipt"
  Assert-DbInferenceEqual $result.FreshSearchReceiptReady $expectedAggregateFreshSearchReady "$($fixtureCase.name) aggregate fresh-search receipt"

  if ($actualResults.Count -eq 1) {
    Assert-DbInferenceEqual $result.InferredScope $actualResults[0].InferredScope "$($fixtureCase.name) top-level scope convenience"
    Assert-DbInferenceEqual $result.InferredCollection $actualResults[0].InferredCollection "$($fixtureCase.name) top-level collection convenience"
    Assert-DbInferenceEqual $result.Confidence $actualResults[0].Confidence "$($fixtureCase.name) top-level confidence convenience"
    Assert-DbInferenceEqual $result.Reason $actualResults[0].Reason "$($fixtureCase.name) top-level reason convenience"
    if ($null -eq $result.Receipts) {
      throw "$($fixtureCase.name) single-cluster output must expose receipts."
    }
  } else {
    Assert-DbInferenceEqual $result.InferredScope $null "$($fixtureCase.name) mixed top-level scope"
    Assert-DbInferenceEqual $result.InferredCollection $null "$($fixtureCase.name) mixed top-level collection"
    Assert-DbInferenceEqual $result.Confidence "mixed" "$($fixtureCase.name) mixed top-level confidence"
    Assert-DbInferenceEqual $result.Reason "per-cluster-results" "$($fixtureCase.name) mixed top-level reason"
    Assert-DbInferenceEqual $result.Receipts $null "$($fixtureCase.name) mixed top-level receipts"
  }
}

if ($Case -eq "All") {
  $blankProbeCombinationCount = 0
  $blankPhaseStates = @(
    [pscustomobject]@{ Submitted = $false; Fresh = $false; Chips = @(); Signature = "" },
    [pscustomobject]@{ Submitted = $true; Fresh = $false; Chips = @( "조건", "개수" ); Signature = "submitted|stable" },
    [pscustomobject]@{ Submitted = $true; Fresh = $true; Chips = @( "조건", "개수" ); Signature = "3|1,2,3" }
  )
  foreach ($blankReadOnly in @( $false, $true )) {
    foreach ($phaseState in $blankPhaseStates) {
      foreach ($allRowsReadOnly in @( $false, $true )) {
        $probeRows = @(
          foreach ($problemNumber in 1..3) {
            [pscustomobject]@{
              problemNumber = [string]$problemNumber
              bodyExact = $true
              readOnly = [bool]$allRowsReadOnly
              scope = if ($problemNumber -eq 1) { "교재 > 확통 > truth-table" } else { "교재>확통>truth-table" }
              scopeKind = "leaf"
            }
          }
        )
        $truthTableInput = [pscustomobject]@{
          clusters = @(
            [pscustomobject]@{
              clusterId = "blank-probe-truth-table"
              collectionComplete = $true
              printedMetadata = @()
              probeHits = $probeRows
              receipts = [pscustomobject]@{
                blankProbe = [pscustomobject]@{
                  readOnly = [bool]$blankReadOnly
                  chips = @($phaseState.Chips)
                  submitted = [bool]$phaseState.Submitted
                  freshResultVerified = [bool]$phaseState.Fresh
                  resultSignature = [string]$phaseState.Signature
                }
                scopeLock = [pscustomobject]@{
                  selectorSearchCleared = $false
                  scopeReceiptVerified = $false
                  selectedScope = ""
                }
                scopedSearch = [pscustomobject]@{
                  selectedScope = ""
                  chips = @()
                  submitted = $false
                  freshResultVerified = $false
                  resultSignature = ""
                }
              }
            }
          )
        }
        $truthTableResult = Invoke-MathSecrDbInference $truthTableInput
        $shouldInfer = $blankReadOnly -and $phaseState.Submitted -and $phaseState.Fresh -and $allRowsReadOnly
        if ($shouldInfer -xor ($truthTableResult.Status -ceq "inferred")) {
          throw "Blank-probe truth table mismatch: blankReadOnly=$blankReadOnly submitted=$($phaseState.Submitted) fresh=$($phaseState.Fresh) allRowsReadOnly=$allRowsReadOnly status=$($truthTableResult.Status)"
        }
        $blankProbeCombinationCount++
      }
    }
  }
  if ($blankProbeCombinationCount -ne 12) {
    throw "Blank-probe truth table must test exactly 12 combinations."
  }

  $scopeStates = @(
    [pscustomobject]@{ Selector = $false; Receipt = $false; Selected = ""; Ready = $false },
    [pscustomobject]@{ Selector = $true; Receipt = $false; Selected = ""; Ready = $false },
    [pscustomobject]@{ Selector = $false; Receipt = $true; Selected = "DB A"; Ready = $false },
    [pscustomobject]@{ Selector = $true; Receipt = $true; Selected = "DB B"; Ready = $false },
    [pscustomobject]@{ Selector = $true; Receipt = $true; Selected = " db   a "; Ready = $true }
  )
  $scopedStates = @(
    [pscustomobject]@{ Selected = ""; Submitted = $false; Fresh = $false; Chips = @(); Signature = ""; Ready = $false },
    [pscustomobject]@{ Selected = "DB A"; Submitted = $true; Fresh = $false; Chips = @( "조건", "개수" ); Signature = "submitted"; Ready = $false },
    [pscustomobject]@{ Selected = "DB B"; Submitted = $true; Fresh = $true; Chips = @( "조건", "개수" ); Signature = "2|9,10"; Ready = $false },
    [pscustomobject]@{ Selected = "DB A"; Submitted = $true; Fresh = $true; Chips = @( "조건", "개수" ); Signature = "2|9,10"; Ready = $true }
  )
  $scopeCombinationCount = 0
  foreach ($scopeState in $scopeStates) {
    foreach ($scopedState in $scopedStates) {
      $scopeInput = [pscustomobject]@{
        clusters = @(
          [pscustomobject]@{
            clusterId = "scope-truth-table"
            collectionComplete = $true
            printedMetadata = @(
              [pscustomobject]@{ problemNumber = "1"; sourceType = "textbook"; scope = "DB A"; scopeKind = "leaf"; exact = $true },
              [pscustomobject]@{ problemNumber = "2"; sourceType = "textbook"; scope = "DB A"; scopeKind = "leaf"; exact = $true }
            )
            probeHits = @()
            receipts = [pscustomobject]@{
              blankProbe = [pscustomobject]@{ readOnly = $false; chips = @(); submitted = $false; freshResultVerified = $false; resultSignature = "" }
              scopeLock = [pscustomobject]@{
                selectorSearchCleared = [bool]$scopeState.Selector
                scopeReceiptVerified = [bool]$scopeState.Receipt
                selectedScope = [string]$scopeState.Selected
              }
              scopedSearch = [pscustomobject]@{
                selectedScope = [string]$scopedState.Selected
                chips = @($scopedState.Chips)
                submitted = [bool]$scopedState.Submitted
                freshResultVerified = [bool]$scopedState.Fresh
                resultSignature = [string]$scopedState.Signature
              }
            }
          }
        )
      }
      $scopeResult = Invoke-MathSecrDbInference $scopeInput
      Assert-DbInferenceEqual $scopeResult.ScopeLockReady ([bool]$scopeState.Ready) "Scope identity truth table scope readiness"
      $expectedFreshReady = [bool]($scopeState.Ready -and $scopedState.Ready)
      Assert-DbInferenceEqual $scopeResult.FreshSearchReceiptReady $expectedFreshReady "Scope identity truth table fresh readiness"
      $scopeCombinationCount++
    }
  }
  if ($scopeCombinationCount -ne 20) {
    throw "Scope/scoped-search truth table must test exactly 20 combinations."
  }
}

$truthTableCount = if ($Case -eq "All") { 32 } else { 0 }
Write-Host "DbInference PASS ($($cases.Count) cases; receipt truth tables=$truthTableCount; truth_scope=offline-contract product_behavior=false)"
