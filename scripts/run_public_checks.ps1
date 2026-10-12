[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$publicationRoot = Split-Path -Parent $PSScriptRoot
$publicationPython = (Get-Command python -ErrorAction Stop).Source
& $publicationPython (Join-Path $PSScriptRoot 'validate_publication.py')
if ($LASTEXITCODE -ne 0) { throw 'Publication file checks failed.' }

$started = [DateTime]::UtcNow
$checks = @()
foreach ($suite in @('test_selection_journal.ps1', 'test_search_query_plan.ps1', 'test_filter_contract.ps1')) {
    $suitePath = Join-Path $publicationRoot (Join-Path 'mathsecr-paper-builder-kit/scripts' $suite)
    & $suitePath -ProjectRoot $publicationRoot
    if (-not $?) { throw "Public synthetic suite failed: $suite" }
    $checks += [pscustomobject]@{ name = $suite; status = 'PASS'; scope = 'offline-contract'; liveProductBehavior = $false }
}
foreach ($case in @('Contract', 'CuaRestricted')) {
    & (Join-Path $publicationRoot 'mathsecr-paper-builder-kit/scripts/test_search_observation.ps1') -ProjectRoot $publicationRoot -Case $case
    if (-not $?) { throw "Search observation suite failed: $case" }
    $checks += [pscustomobject]@{ name = "test_search_observation.ps1/$case"; status = 'PASS'; scope = 'offline-contract'; liveProductBehavior = $false }
}

$result = [ordered]@{
    schemaVersion = 1
    startedAtUtc = $started.ToString('o')
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
    host = $PSVersionTable.PSVersion.ToString()
    publicationFiles = 'PASS'
    checks = $checks
    fullRegressionRun = $false
    browserConnectionTest = $false
    bodyExactGroundTruthTest = $false
}
$reportPath = Join-Path $publicationRoot 'docs/evidence/publication-checks.json'
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($reportPath, (($result | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8)
& $publicationPython (Join-Path $PSScriptRoot 'validate_publication.py')
if ($LASTEXITCODE -ne 0) { throw 'Final publication file checks failed.' }
Write-Output 'Public snapshot checks PASS. Full regression and live production were not run.'
