[CmdletBinding()]
param(
  [string]$ProjectRoot = (Get-Location).Path,
  [Parameter(Mandatory = $true)]
  [string]$OutDir
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
$docsDir = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\docs"
$blindedPath = Join-Path $docsDir "body_exact_benchmark_blinded.json"
$manifestPath = Join-Path $docsDir "body_exact_benchmark_manifest.json"

if (-not (Test-Path -LiteralPath $blindedPath -PathType Leaf)) {
  throw "TASK8_EXPORT: missing blinded corpus: $blindedPath"
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "TASK8_EXPORT: missing scorer manifest: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$blinded = Get-Content -LiteralPath $blindedPath -Raw -Encoding UTF8 | ConvertFrom-Json
$blindedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $blindedPath).Hash.ToUpperInvariant()
if ($manifest.schema_version -ne 2 -or $blinded.schema_version -ne 2) {
  throw "TASK8_EXPORT: scorer manifest and blinded corpus must use schema_version 2."
}
if ($manifest.corpus_id -cne $blinded.corpus_id -or $manifest.blinded_sha256.ToUpperInvariant() -cne $blindedHash) {
  throw "TASK8_EXPORT: blinded corpus does not match the scorer manifest."
}

if (Test-Path -LiteralPath $OutDir) {
  if (@(Get-ChildItem -LiteralPath $OutDir -Force).Count -ne 0) {
    throw "TASK8_EXPORT: OutDir must be empty so scorer-only files cannot be mixed into the export."
  }
} else {
  New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$exportBlind = Join-Path $OutDir "body_exact_benchmark_blinded.json"
$exportManifest = Join-Path $OutDir "body_exact_benchmark_run_manifest.json"
Copy-Item -LiteralPath $blindedPath -Destination $exportBlind

$runManifest = [ordered]@{
  schema_version = 1
  corpus_schema_version = 2
  corpus_id = $blinded.corpus_id
  blinded_file = "body_exact_benchmark_blinded.json"
  blinded_sha256 = $blindedHash
  ordered_record_count = @($blinded.records).Count
  submission_contract = [ordered]@{
    required_top_level_fields = @("corpus_id", "blinded_sha256", "status", "records")
    forbidden_scorer_fields = @("gold_sha256", "expected_match_state", "expected_body_exact_ids")
    status_values = @("success", "partial", "no_match")
    record_fields = @("record_key", "selected_ids", "body_only_preflight_rationale")
  }
}
$runManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $exportManifest -Encoding UTF8

$exportedFiles = @(Get-ChildItem -LiteralPath $OutDir -File | Sort-Object Name)
if ($exportedFiles.Count -ne 2 -or
    $exportedFiles[0].Name -cne "body_exact_benchmark_blinded.json" -or
    $exportedFiles[1].Name -cne "body_exact_benchmark_run_manifest.json") {
  throw "TASK8_EXPORT: export contains files outside the blind-run contract."
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $exportBlind).Hash.ToUpperInvariant() -cne $blindedHash) {
  throw "TASK8_EXPORT: exported blind sheet hash changed."
}

Write-Output "TASK8_EXPORT: PASS corpus_id=$($blinded.corpus_id) records=$(@($blinded.records).Count) files=2 blinded_sha256=$blindedHash"
