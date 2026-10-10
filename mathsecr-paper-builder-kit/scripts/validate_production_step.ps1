[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('Select','BeforeNext','AfterReload')][string]$Step,
  [Parameter(Mandatory=$true)][string]$InputPath,
  [string]$ProjectRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$OutPath,
  [string]$SummaryPath,
  [string]$TargetOccurrenceKey
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'production_validation.ps1')
$ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
function Resolve-ProductionCliPath {
  param([string]$Path,[string]$Extension,[switch]$Output)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path -cne $Path.Trim()) { throw 'A canonical project path is required.' }
  $full=[IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Path)) {$Path} else {Join-Path $ProjectRoot $Path}))
  $prefix=$ProjectRoot+[IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($full).ToLowerInvariant() -cne $Extension) { throw 'Input and output must be files inside ProjectRoot of the required type.' }
  $relative=$full.Substring($prefix.Length)
  if ($relative.Contains(':')) { throw 'Alternate data streams are not supported.' }
  $cursor=$ProjectRoot
  foreach ($part in $relative.Split([char[]]@('\','/'))) {
    $cursor=Join-Path $cursor $part
    if ((Test-Path -LiteralPath $cursor) -and (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Reparse points are not supported.' }
  }
  if ($Output) {
    if (Test-Path -LiteralPath $full) { throw 'Output already exists; choose a new path.' }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $full) -PathType Container)) { throw 'Output parent must exist.' }
  } elseif (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'Input JSON does not exist.' }
  return $full
}
function Write-ProductionCliNewFile {
  param([string]$Path,[string]$Text)
  $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text+[Environment]::NewLine);$stream.Write($bytes,0,$bytes.Length) } finally {$stream.Dispose()}
}
try {
  $inputFull=Resolve-ProductionCliPath $InputPath '.json'
  $outputFull=if ($OutPath) {Resolve-ProductionCliPath $OutPath '.json' -Output} else {$null}
  if ($SummaryPath -and $Step -cne 'AfterReload') { throw 'SummaryPath is allowed only for AfterReload.' }
  $summaryFull=if ($SummaryPath) {Resolve-ProductionCliPath $SummaryPath '.md' -Output} else {$null}
  $inputHash=(Get-FileHash -LiteralPath $inputFull -Algorithm SHA256).Hash
  $inputObject=ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $inputFull -Raw -Encoding UTF8)
  $result=Invoke-MathSecrProductionStep -Step $Step -InputObject $inputObject -ProjectRoot $ProjectRoot -TargetOccurrenceKey $TargetOccurrenceKey
  if ((Get-FileHash -LiteralPath $inputFull -Algorithm SHA256).Hash -cne $inputHash) {throw 'Input JSON changed during validation.'}
  $json=ConvertTo-Json -InputObject $result -Depth 80
  if ($outputFull) {$null=Resolve-ProductionCliPath $OutPath '.json' -Output;Write-ProductionCliNewFile $outputFull $json}
  if ($summaryFull) {$null=Resolve-ProductionCliPath $SummaryPath '.md' -Output;Write-ProductionCliNewFile $summaryFull $result.UserSummary}
  if (-not $outputFull) {$json}
} catch {
  [pscustomobject]@{Valid=$false;Step=$Step;Error=$_.Exception.Message} | ConvertTo-Json -Compress
  exit 1
}
