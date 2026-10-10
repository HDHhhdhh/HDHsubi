param(
  [string]$ProjectRoot = (Get-Location).Path,
  [ValidateSet("All", "Happy", "Red")]
  [string]$Case = "All"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -cne $Expected) {
    throw "$Message. Expected '$Expected', got '$Actual'."
  }
}

function Invoke-Python {
  param([string[]]$Arguments)

  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & python @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = @($output | ForEach-Object { [string]$_ })
  }
}

function Write-Manifest {
  param([string]$Path, $Manifest)
  $json = $Manifest | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText(
    $Path,
    $json,
    (New-Object System.Text.UTF8Encoding($false))
  )
}

function Get-PageCount {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
  return ([regex]::Matches($ascii, '/Type /Page\b')).Count
}

function Get-FontPair {
  $candidates = @(
    @{ Regular = 'C:\Windows\Fonts\malgun.ttf'; Bold = 'C:\Windows\Fonts\malgunbd.ttf' },
    @{ Regular = 'C:\Windows\Fonts\arial.ttf'; Bold = 'C:\Windows\Fonts\arialbd.ttf' }
  )
  foreach ($candidate in $candidates) {
    if ((Test-Path -LiteralPath $candidate.Regular -PathType Leaf) -and
        (Test-Path -LiteralPath $candidate.Bold -PathType Leaf)) {
      return $candidate
    }
  }
  throw 'No usable Windows TrueType regular/bold font pair was found for the crop-report contract test.'
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$generator = Join-Path $scriptRoot 'create_failed_problem_report.py'
$resolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
Assert-True ($null -ne $pythonCommand) 'Python is required for the failed-problem crop-report contract test.'
Assert-True (Test-Path -LiteralPath $generator -PathType Leaf) "Missing crop-report generator: $generator"

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mathsecr-failed-problem-report-' + [Guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $testRoot 'fixture'
$manifestPath = Join-Path $fixtureRoot 'manifest.json'
$imagePath = Join-Path $fixtureRoot 'fixture.png'
$outputPath = Join-Path $fixtureRoot 'out\failed-report.pdf'
$fontPair = Get-FontPair

# A fixed 2x2 PNG keeps this test local, deterministic, and independent of any
# source PDF or browser. The generator still exercises real image decoding and
# reportlab PDF writing.
$pngBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR42mNUTX7NwMDAxMDAwMDAAAAQyAF3w9z6AQAAAABJRU5ErkJggg==')

New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
try {
  [System.IO.File]::WriteAllBytes($imagePath, $pngBytes)

  if ($Case -in @('All', 'Happy')) {
    $manifest = [ordered]@{
      title = 'Deterministic failed crop report'
      source = 'local-fixture-source.pdf'
      items = @(
        [ordered]@{ problem_number = 6; image = 'fixture.png'; crop = @(0, 0, 2, 2) },
        [ordered]@{ problem_number = 8; image = 'fixture.png'; crop = @(0, 0, 2, 2) }
      )
    }
    Write-Manifest $manifestPath $manifest

    $result = Invoke-Python @(
      $generator,
      '--manifest', 'manifest.json',
      '--output', 'out\failed-report.pdf',
      '--project-root', $fixtureRoot,
      '--regular-font', $fontPair.Regular,
      '--bold-font', $fontPair.Bold
    )
    Assert-Equal $result.ExitCode 0 "Happy-path generator invocation failed: $($result.Output -join [Environment]::NewLine)"
    $resultText = $result.Output -join [Environment]::NewLine
    Assert-True ($resultText -like '*created=*failed-report.pdf*') "Happy-path output omitted created marker: $resultText"
    Assert-True ($resultText -like '*pages=2*') "Happy-path output omitted page count: $resultText"
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) "Happy-path PDF was not created: $outputPath"
    Assert-True ((Get-Item -LiteralPath $outputPath).Length -gt 0) 'Happy-path PDF is empty.'
    Assert-Equal (Get-PageCount $outputPath) 2 'Happy-path PDF page count'
  }

  if ($Case -in @('All', 'Red')) {
    $duplicateManifestPath = Join-Path $fixtureRoot 'duplicate.json'
    $duplicateOutputPath = Join-Path $fixtureRoot 'out\duplicate.pdf'
    $duplicateManifest = [ordered]@{
      title = 'Duplicate number red case'
      source = 'local-fixture-source.pdf'
      items = @(
        [ordered]@{ problem_number = 6; image = 'fixture.png'; crop = @(0, 0, 2, 2) },
        [ordered]@{ problem_number = 6; image = 'fixture.png'; crop = @(0, 0, 2, 2) }
      )
    }
    Write-Manifest $duplicateManifestPath $duplicateManifest
    $duplicateResult = Invoke-Python @(
      $generator,
      '--manifest', 'duplicate.json',
      '--output', 'out\duplicate.pdf',
      '--project-root', $fixtureRoot,
      '--regular-font', $fontPair.Regular,
      '--bold-font', $fontPair.Bold
    )
    Assert-True ($duplicateResult.ExitCode -ne 0) 'Duplicate problem-number manifest unexpectedly passed.'
    Assert-True (($duplicateResult.Output -join [Environment]::NewLine) -like '*duplicate problem number*') 'Duplicate red case omitted its validation error.'
    Assert-True (-not (Test-Path -LiteralPath $duplicateOutputPath)) 'Duplicate manifest created an output PDF before validation.'

    $boundsManifestPath = Join-Path $fixtureRoot 'bounds.json'
    $boundsOutputPath = Join-Path $fixtureRoot 'out\bounds.pdf'
    $boundsManifest = [ordered]@{
      title = 'Bounds red case'
      source = 'local-fixture-source.pdf'
      items = @([ordered]@{ problem_number = 9; image = 'fixture.png'; crop = @(0, 0, 3, 2) })
    }
    Write-Manifest $boundsManifestPath $boundsManifest
    $boundsResult = Invoke-Python @(
      $generator,
      '--manifest', 'bounds.json',
      '--output', 'out\bounds.pdf',
      '--project-root', $fixtureRoot,
      '--regular-font', $fontPair.Regular,
      '--bold-font', $fontPair.Bold
    )
    Assert-True ($boundsResult.ExitCode -ne 0) 'Out-of-bounds crop manifest unexpectedly passed.'
    Assert-True (($boundsResult.Output -join [Environment]::NewLine) -like '*exceeds image size*') 'Bounds red case omitted its validation error.'
  }

  switch ($Case) {
    'Happy' { Write-Host 'FailedProblemReport Happy PASS (pages=2; local_png=true; network=false)' }
    'Red' { Write-Host 'FailedProblemReport Red PASS (duplicate_number_rejected=true; out_of_bounds_rejected=true; network=false)' }
    default { Write-Host 'FailedProblemReport PASS (pages=2; duplicate_number_rejected=true; out_of_bounds_rejected=true; network=false)' }
  }
} finally {
  $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
  $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  $tempPrefix = $resolvedTempRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $resolvedTestRoot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing cleanup outside the system temp directory: $resolvedTestRoot"
  }
  if (Test-Path -LiteralPath $resolvedTestRoot) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
  Write-Host 'temp_cleanup=PASS'
}
