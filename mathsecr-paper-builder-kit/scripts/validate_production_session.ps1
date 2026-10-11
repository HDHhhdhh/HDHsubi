[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
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

while ($null -ne ($line=[Console]::ReadLine())) {
  $step=$null
  try {
    if (-not $line.TrimStart().StartsWith('{',[StringComparison]::Ordinal)) {throw 'Command must be a JSON object.'}
    $command=ConvertFrom-MathSecrContractJson $line
    if ($command -isnot [pscustomobject] -or $null -eq $command.PSObject.Properties['step'] -or
        $command.step -isnot [string] -or [string]::IsNullOrWhiteSpace($command.step)) {
      throw 'Command requires a step.'
    }
    $step=$command.step
    if ($step -ceq 'exit') { break }
    if ($step -cnotin @('Select','BeforeNext','AfterReload')) { throw 'Step must be Select, BeforeNext, or AfterReload.' }
    if ($null -eq $command.PSObject.Properties['inputPath'] -or $command.inputPath -isnot [string]) {
      throw 'Command requires an inputPath string.'
    }
    $options=@{}
    foreach ($name in @('outPath','summaryPath','targetOccurrenceKey')) {
      $property=$command.PSObject.Properties[$name]
      if ($null -ne $property -and $null -ne $property.Value -and $property.Value -isnot [string]) {
        throw "Command $name must be a string."
      }
      $options[$name]=if ($null -ne $property) {$property.Value} else {$null}
    }
    $inputFull=Resolve-ProductionCliPath $command.inputPath '.json'
    $outputFull=if ($options.outPath) {Resolve-ProductionCliPath $options.outPath '.json' -Output} else {$null}
    if ($options.summaryPath -and $step -cne 'AfterReload') { throw 'SummaryPath is allowed only for AfterReload.' }
    $summaryFull=if ($options.summaryPath) {Resolve-ProductionCliPath $options.summaryPath '.md' -Output} else {$null}
    $inputHash=(Get-FileHash -LiteralPath $inputFull -Algorithm SHA256).Hash
    $inputObject=ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $inputFull -Raw -Encoding UTF8)
    # Each command is a new top-level validation. Only loaded code is shared.
    $result=Invoke-MathSecrProductionStep -Step $step -InputObject $inputObject -ProjectRoot $ProjectRoot -TargetOccurrenceKey $options.targetOccurrenceKey
    if ((Get-FileHash -LiteralPath $inputFull -Algorithm SHA256).Hash -cne $inputHash) {throw 'Input JSON changed during validation.'}
    $json=ConvertTo-Json -InputObject $result -Depth 80
    if ($outputFull) {$null=Resolve-ProductionCliPath $options.outPath '.json' -Output;Write-ProductionCliNewFile $outputFull $json}
    if ($summaryFull) {$null=Resolve-ProductionCliPath $options.summaryPath '.md' -Output;Write-ProductionCliNewFile $summaryFull $result.UserSummary}
    [Console]::WriteLine((ConvertTo-Json -InputObject $result -Depth 80 -Compress))
  } catch {
    [Console]::WriteLine(([pscustomobject]@{Valid=$false;Step=$step;Error=$_.Exception.Message} | ConvertTo-Json -Compress))
  }
}
exit 0
