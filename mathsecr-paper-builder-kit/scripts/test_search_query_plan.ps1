param([string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'search_query_plan.ps1')

function Assert-QueryPlan {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "SearchQueryPlan: $Message" }
}

function Copy-QueryValue {
  param($Value)
  return $Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json
}

$fixturePath = Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/search-query-plan/source-order-input.json'
$fixtureHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
$inputDocument = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
$plan = New-MathSecrSearchQueryPlan $inputDocument
Assert-QueryPlan ($plan.status -ceq 'ready' -and $plan.readyTargetCount -eq 3) 'valid source input must prepare three rows'
Assert-QueryPlan ((Test-MathSecrSearchQueryPlan $plan).Valid) 'prepared plan must recompute'
Assert-QueryPlan (($plan.targets.targetBinding.sourceProblemNumber -join ',') -ceq '7,2,7') 'source order must not be numerically sorted or repeated numbers collapsed'
Assert-QueryPlan (($plan.targets.sourceOrder -join ',') -ceq '1,2,3') 'source-order indexes must be derived'
for ($index = 0; $index -lt $plan.targets.Count; $index++) {
  $row = $plan.targets[$index]
  Assert-QueryPlan ((Test-MathSecrSearchQueryTargetPlan $row $row.targetBinding ($index + 1)).Valid) 'row binding must recompute'
  Assert-QueryPlan ($row.requiresLiveScopeAndFreshness -and $row.recoveryHints.authority -ceq 'hint-only') 'prepared inputs must not claim live authority'
  foreach ($chip in @($row.initialChips)) {
    $normalized = $row.inputTarget.sourceBodyText.Normalize([System.Text.NormalizationForm]::FormKC)
    Assert-QueryPlan ($normalized.Substring($chip.sourceSpan.start, $chip.sourceSpan.length) -ceq $chip.sourceSpan.text) 'span must point to actual supplied text'
  }
}
Assert-QueryPlan ($plan.targets[0].initialChips[0].sourceSpan.start -eq 0) 'first literal starts at source offset zero'
Assert-QueryPlan ($plan.targets[0].initialChips[1].sourceSpan.start -eq 4) 'second literal span must retain Korean particle and space'
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
  $rawHash = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($inputDocument.targets[0].sourceBodyText)))).Replace('-', '')
} finally { $sha.Dispose() }
Assert-QueryPlan ($plan.targets[0].transcriptionSha256 -ceq $rawHash) 'receipt hash must bind exact supplied transcription bytes'
$roundTrip = Copy-QueryValue $plan
Assert-QueryPlan ((Test-MathSecrSearchQueryPlan $roundTrip).Valid) 'JSON round-trip must preserve ready plan'
$positive = 4
$negative = 0

$inputAttacks = @(
  @{ Name = 'boolean schema'; Edit = { param($x) $x.schemaVersion = $true } },
  @{ Name = 'scalar target'; Edit = { param($x) $x.targets = $x.targets[0] } },
  @{ Name = 'empty targets'; Edit = { param($x) $x.targets = @() } },
  @{ Name = 'numeric source number'; Edit = { param($x) $x.targets[0].sourceProblemNumber = 7 } },
  @{ Name = 'reserved occurrence'; Edit = { param($x) $x.targets[0].occurrenceKey = '없음' } },
  @{ Name = 'duplicate occurrence'; Edit = { param($x) $x.targets[2].occurrenceKey = $x.targets[0].occurrenceKey } },
  @{ Name = 'empty source'; Edit = { param($x) $x.targets[0].sourceBodyText = ' ' } },
  @{ Name = 'one chip'; Edit = { param($x) $x.targets[0].proposedChips = @($x.targets[0].proposedChips[0]) } },
  @{ Name = 'scalar chip'; Edit = { param($x) $x.targets[0].proposedChips = $x.targets[0].proposedChips[0] } },
  @{ Name = 'semantic provenance'; Edit = { param($x) $x.targets[0].proposedChips[0].provenance = 'semantic-inference' } },
  @{ Name = 'translated symbol'; Edit = { param($x) $x.targets[0].proposedChips[0].value = '양수' } },
  @{ Name = 'source whitespace removed'; Edit = { param($x) $x.targets[0].sourceBodyText = '직 선과 곡선'; } },
  @{ Name = 'sentence chip'; Edit = { param($x) $x.targets[0].proposedChips[0].value = '만나는 두 점' } },
  @{ Name = 'collapsed clause'; Edit = { param($x) $x.targets[0].proposedChips[0].value = '실수에대하여'; $x.targets[0].sourceBodyText = '실수에대하여 곡선' } },
  @{ Name = 'formula chip'; Edit = { param($x) $x.targets[0].proposedChips[0].value = 't>0' } },
  @{ Name = 'duplicate normalized chip'; Edit = { param($x) $x.targets[0].proposedChips[1].value = $x.targets[0].proposedChips[0].value } },
  @{ Name = 'unicode normalized duplicate'; Edit = { param($x) $x.targets[0].sourceBodyText = '２차함수'; $x.targets[0].proposedChips[0].value = '２차함수'; $x.targets[0].proposedChips[1].value = '2차함수' } },
  @{ Name = 'fake confidence'; Edit = { param($x) $x.targets[0] | Add-Member -NotePropertyName confidence -NotePropertyValue 'high' } },
  @{ Name = 'selected ID in input'; Edit = { param($x) $x.targets[0] | Add-Member -NotePropertyName selectedId -NotePropertyValue 'hint-10' } },
  @{ Name = 'missing hint declaration'; Edit = { param($x) $x.targets[0].PSObject.Properties.Remove('recoveryHints') } },
  @{ Name = 'numeric candidate hint'; Edit = { param($x) $x.targets[0].recoveryHints.candidateIds = @(10) } },
  @{ Name = 'duplicate candidate hints'; Edit = { param($x) $x.targets[0].recoveryHints.candidateIds = @('hint-10', 'hint-10') } },
  @{ Name = 'scalar selector hint'; Edit = { param($x) $x.targets[0].recoveryHints.sourcePaperSelectors = 'DB' } },
  @{ Name = 'metadata evidence mismatch'; Edit = { param($x) $x.targets[0].recoveryHints.printedMetadata[0].value = '평가원' } },
  @{ Name = 'metadata evidence missing'; Edit = { param($x) $x.targets[0].recoveryHints.printedMetadata[0].PSObject.Properties.Remove('sourceText') } }
)
foreach ($attack in $inputAttacks) {
  $changed = Copy-QueryValue $inputDocument
  & $attack.Edit $changed
  $rejected = New-MathSecrSearchQueryPlan $changed
  Assert-QueryPlan ($rejected.status -ceq 'blocked' -and $rejected.errors.Count -gt 0) "$($attack.Name) must block preparation"
  Assert-QueryPlan (-not (Test-MathSecrSearchQueryPlan $rejected).Valid) "$($attack.Name) cannot become an accepted prepared plan"
  foreach ($row in @($rejected.targets | Where-Object { $_.status -ceq 'blocked' })) {
    Assert-QueryPlan ($row.initialChips -is [System.Array] -and $row.initialChips.Count -eq 0) 'blocked row must expose no initial UI chips'
  }
  $negative++
}

$preparedAttacks = @(
  @{ Name = 'changed transcription hash'; Edit = { param($x) $x.transcriptionSha256 = '0' * 64 } },
  @{ Name = 'changed span offset'; Edit = { param($x) $x.initialChips[0].sourceSpan.start = 1 } },
  @{ Name = 'changed span text'; Edit = { param($x) $x.initialChips[0].sourceSpan.text = 'other' } },
  @{ Name = 'changed chip'; Edit = { param($x) $x.initialChips[0].value = 'other' } },
  @{ Name = 'changed provenance'; Edit = { param($x) $x.initialChips[0].provenance = 'semantic-inference' } },
  @{ Name = 'changed raw body'; Edit = { param($x) $x.inputTarget.sourceBodyText += ' Changed.' } },
  @{ Name = 'forged metadata scope authority'; Edit = { param($x) $x.recoveryHints.authority = 'verified-scope' } },
  @{ Name = 'freshness bypass'; Edit = { param($x) $x.requiresLiveScopeAndFreshness = $false } },
  @{ Name = 'unknown verdict'; Edit = { param($x) $x | Add-Member -NotePropertyName exactFound -NotePropertyValue $true } },
  @{ Name = 'boolean order'; Edit = { param($x) $x.sourceOrder = $true } }
)
foreach ($attack in $preparedAttacks) {
  $row = Copy-QueryValue $plan.targets[0]
  & $attack.Edit $row
  Assert-QueryPlan (-not (Test-MathSecrSearchQueryTargetPlan $row $plan.targets[0].targetBinding 1).Valid) "$($attack.Name) must fail recomputation"
  $negative++
}
$wrongBinding = Copy-QueryValue $plan.targets[0].targetBinding
$wrongBinding.occurrenceKey = $plan.targets[2].targetBinding.occurrenceKey
Assert-QueryPlan (-not (Test-MathSecrSearchQueryTargetPlan $plan.targets[0] $wrongBinding 1).Valid) 'same source text cannot bypass occurrence binding'
Assert-QueryPlan (-not (Test-MathSecrSearchQueryTargetPlan $plan.targets[0] $plan.targets[0].targetBinding 2).Valid) 'source-order mismatch must reject'
$reordered = Copy-QueryValue $plan
$reordered.targets = @($reordered.targets[1], $reordered.targets[0], $reordered.targets[2])
Assert-QueryPlan (-not (Test-MathSecrSearchQueryPlan $reordered).Valid) 'reordered output must fail recomputation'
$negative += 3

$nfkc = Copy-QueryValue $inputDocument
$nfkc.targets[0].sourceBodyText = '２차함수와 곡선'
$nfkc.targets[0].proposedChips[0].value = '2차함수'
$nfkcPlan = New-MathSecrSearchQueryPlan $nfkc
Assert-QueryPlan ((Test-MathSecrSearchQueryPlan $nfkcPlan).Valid) 'NFKC-equivalent literal must remain supported by canonical policy'
Assert-QueryPlan ($nfkcPlan.targets[0].initialChips[0].sourceSpan.text -ceq '2차함수') 'NFKC span must explicitly describe normalized source'
$positive++

$taskTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('mathsecr-query-plan-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskTemp | Out-Null
try {
  $outFile = Join-Path $taskTemp 'prepared.json'
  $hostExe = if ($PSVersionTable.PSEdition -ceq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
  $cliOutput = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'search_query_plan.ps1') -InputPath $fixturePath -OutPath $outFile 2>&1)
  Assert-QueryPlan ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $outFile -PathType Leaf)) 'CLI must write a ready plan'
  $cliPlan = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-QueryPlan ((Test-MathSecrSearchQueryPlan $cliPlan).Valid) 'CLI artifact must recompute after JSON read'
  Assert-QueryPlan ((Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash -ceq $fixtureHashBefore) 'CLI must preserve supplied source fixture'
  $positive++
} finally {
  $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
  $testRoot = [System.IO.Path]::GetFullPath($taskTemp).TrimEnd('\', '/')
  Assert-QueryPlan ([string]::Equals((Split-Path -Parent $testRoot), $tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $testRoot) -cmatch '^mathsecr-query-plan-[0-9a-f]{32}$') 'cleanup must stay in owned temp directory'
  if (Test-Path -LiteralPath $testRoot) {
    $items = @((Get-Item -LiteralPath $testRoot -Force)) + @(Get-ChildItem -LiteralPath $testRoot -Force -Recurse)
    Assert-QueryPlan (@($items | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -eq 0) 'cleanup must not traverse reparse points'
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}
Write-Host "SearchQueryPlan PASS positive_cases=$positive intentional_red_cases=$negative source_order_preserved=true spans_and_hashes_recomputed=true truth_scope=transcription-query-preparation-only live_scope_or_exact_proof=false"
