param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$OutDir
)

$ErrorActionPreference = "Stop"

if (-not $OutDir) {
  $OutDir = Join-Path $ProjectRoot ".omo\tmp\test-fixtures"
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$fixtures = @(
  @{
    Name = "goguk2_print2_from_pages.pdf"
    SourceDir = "mathsecr-paper-builder-kit\test-fixtures\pdf-pages\goguk2-print2"
    Pattern = "page-*.png"
    ExpectedPages = 8
  },
  @{
    Name = "baekyang2_geometry_print1_from_pages.pdf"
    SourceDir = "mathsecr-paper-builder-kit\test-fixtures\pdf-pages\baekyang2-geometry-print1"
    Pattern = "page-*.png"
    ExpectedPages = 3
  }
)

$pythonCode = @'
from PIL import Image
import sys
import time

out_path = sys.argv[1]
files = sys.argv[2:]
if not files:
    raise SystemExit(2)
rgb = chr(82) + chr(71) + chr(66)
pdf = chr(80) + chr(68) + chr(70)

images = []
for path in files:
    img = Image.open(path)
    if img.mode != rgb:
        img = img.convert(rgb)
    images.append(img)

first, rest = images[0], images[1:]
fixed_date = time.gmtime(0)
producer = chr(77) + chr(97) + chr(116) + chr(104) + chr(83) + chr(101) + chr(99) + chr(114) + chr(32) + chr(115) + chr(121) + chr(110) + chr(116) + chr(104) + chr(101) + chr(116) + chr(105) + chr(99) + chr(32) + chr(102) + chr(105) + chr(120) + chr(116) + chr(117) + chr(114) + chr(101) + chr(32) + chr(103) + chr(101) + chr(110) + chr(101) + chr(114) + chr(97) + chr(116) + chr(111) + chr(114)
first.save(out_path, pdf, save_all=True, append_images=rest, creationDate=fixed_date, modDate=fixed_date, producer=producer, creator=producer)
'@

$results = @()
foreach ($fixture in $fixtures) {
  $sourceDir = Join-Path $ProjectRoot $fixture.SourceDir
  if (-not (Test-Path -LiteralPath $sourceDir)) {
    throw "Missing fixture source directory: $sourceDir"
  }

  $images = Get-ChildItem -LiteralPath $sourceDir -File -Filter $fixture.Pattern | Sort-Object Name
  if ($images.Count -ne $fixture.ExpectedPages) {
    throw "Fixture $($fixture.Name) expected $($fixture.ExpectedPages) pages but found $($images.Count) in $sourceDir"
  }

  $outPath = Join-Path $OutDir $fixture.Name
  $pythonArgs = @("-c", $pythonCode, $outPath) + @($images.FullName)
  & python @pythonArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Python PDF generation failed for $($fixture.Name)"
  }

  $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $outPath
  $results += [pscustomobject]@{
    Name = $fixture.Name
    Output = $outPath
    SourceDir = $sourceDir
    Pages = $images.Count
    Length = (Get-Item -LiteralPath $outPath).Length
    Sha256 = $hash.Hash
    Synthetic = $true
  }
}

Write-Output ($results | ConvertTo-Json -Depth 3)
