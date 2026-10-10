param(
  [string]$ProjectRoot = (Get-Location).Path,
  [ValidateSet("All", "Evidence", "Red")]
  [string]$Case = "All",
  [switch]$RequireSourcePdfs
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

function As-Array {
  param($Value)
  if ($null -eq $Value) { return @() }
  return @($Value)
}

function Assert-Sha256 {
  param([string]$Hash, [string]$Label)
  Assert-True ($Hash -cmatch '^[0-9A-Fa-f]{64}$') "$Label must be a 64-character SHA-256 hex string."
}

function Get-ArtifactFullPath {
  param([string]$FixtureRoot, [string]$RelativePath)
  Assert-True (-not [string]::IsNullOrWhiteSpace($RelativePath)) "Artifact path cannot be blank."
  Assert-True (-not [IO.Path]::IsPathRooted($RelativePath)) "Artifact path must be relative to the fixture root: $RelativePath"
  $full = [IO.Path]::GetFullPath((Join-Path $FixtureRoot $RelativePath))
  $rootWithSeparator = $FixtureRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  Assert-True $full.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase) "Artifact escaped fixture root: $RelativePath"
  return $full
}

function Find-Artifact {
  param($Artifacts, [string]$RelativePath)
  $matches = @($Artifacts | Where-Object { [string]$_.path -ceq $RelativePath })
  Assert-Equal $matches.Count 1 "Artifact manifest entry count for $RelativePath"
  return $matches[0]
}

function Find-Source {
  param($Sources, [string]$SourceId)
  $matches = @($Sources | Where-Object { [string]$_.id -ceq $SourceId })
  Assert-Equal $matches.Count 1 "Source manifest entry count for $SourceId"
  return $matches[0]
}

function Test-IntArrayEqual {
  param([int[]]$Actual, [int[]]$Expected, [string]$Message)
  Assert-Equal $Actual.Count $Expected.Count $Message
  for ($i = 0; $i -lt $Expected.Count; $i++) {
    Assert-Equal ([int]$Actual[$i]) ([int]$Expected[$i]) "$Message at index $i"
  }
}

function Copy-Document {
  param($Document)
  return ($Document | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
}

function Invoke-PdfSegmentationValidation {
  param($Document, [string]$Root, [bool]$RequireSources)

  Assert-Equal ([string]$Document.schemaVersion) "mathsecr-pdf-segmentation/1.0" "schemaVersion"
  Assert-Equal ([string]$Document.generatedDate) "2026-07-31" "generatedDate"
  Assert-Equal ([string]$Document.render.engine) "PyMuPDF" "render engine"
  Assert-Equal ([string]$Document.render.engineVersion) "1.27.2.3" "render engine version"
  Assert-Equal ([double]$Document.render.matrixScale) 2.0 "render matrix scale"
  Assert-Equal ([int]$Document.render.nominalDpi) 144 "render nominal DPI"
  Assert-True ([string]$Document.render.inspectionBatches -match 'four-page') "Four-page review batching must be recorded."

  $fixtureRoot = [IO.Path]::GetFullPath((Join-Path $Root "mathsecr-paper-builder-kit\test-fixtures\pdf-segmentation"))
  Assert-True (Test-Path -LiteralPath $fixtureRoot -PathType Container) "Missing PDF segmentation fixture root: $fixtureRoot"

  $sources = @(As-Array $Document.sources)
  Assert-Equal $sources.Count 2 "Real source PDF count"
  $sourceIds = @($sources | ForEach-Object { [string]$_.id })
  Assert-Equal (@($sourceIds | Sort-Object -Unique).Count) $sourceIds.Count "Source IDs must be unique."

  foreach ($source in $sources) {
    $sourceId = [string]$source.id
    Assert-True (-not [string]::IsNullOrWhiteSpace($sourceId)) "Source id cannot be blank."
    Assert-Sha256 ([string]$source.sha256) "Source $sourceId hash"
    $sourcePathText = [string]$source.path
    Assert-True (-not [string]::IsNullOrWhiteSpace($sourcePathText)) "Source path cannot be blank for $sourceId"
    $sourcePath = [IO.Path]::GetFullPath($sourcePathText)
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
      $observedSourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash
      Assert-Equal $observedSourceHash.ToUpperInvariant() ([string]$source.sha256).ToUpperInvariant() "Source SHA-256 for $sourceId"
    } elseif ($RequireSources) {
      throw "Missing pinned source PDF for $sourceId`: $sourcePath"
    }
    Assert-True ([int]$source.pageCount -gt 0) "Source page count must be positive for $sourceId"

    $problemPages = @((As-Array $source.problemPages) | ForEach-Object { [int]$_ })
    Assert-True ($problemPages.Count -gt 0) "Problem-page list cannot be empty for $sourceId"
    Assert-Equal (@($problemPages | Sort-Object -Unique).Count) $problemPages.Count "Duplicate problem page for $sourceId"
    Assert-True (@($problemPages | Where-Object { $_ -lt 1 -or $_ -gt [int]$source.pageCount }).Count -eq 0) "Problem page outside source page range for $sourceId"
    $excludedPages = @((As-Array $source.excludedPages) | ForEach-Object { [int]$_ })
    Assert-True (@($excludedPages | Where-Object { $_ -lt 1 -or $_ -gt [int]$source.pageCount }).Count -eq 0) "Excluded page outside source page range for $sourceId"
    $classifiedPages = @($problemPages + $excludedPages)
    Assert-Equal $classifiedPages.Count ([int]$source.pageCount) "Problem/excluded page entry count for $sourceId"
    Assert-Equal (@($classifiedPages | Sort-Object -Unique).Count) ([int]$source.pageCount) "Problem/excluded pages must classify each source page exactly once for $sourceId"
    Test-IntArrayEqual @($classifiedPages | Sort-Object) @(1..[int]$source.pageCount) "Problem/excluded pages must cover the exact source page range for $sourceId"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$source.excludedPageReason)) "Excluded-page reason required for $sourceId"

    $batches = @(As-Array $source.reviewBatches)
    Assert-True ($batches.Count -gt 0) "Review batches required for $sourceId"
    $coveredPages = @()
    foreach ($batch in $batches) {
      $values = @($batch | ForEach-Object { [int]$_ })
      Assert-Equal $values.Count 2 "Review batch must contain [start,end] for $sourceId"
      Assert-True ($values[0] -ge 1 -and $values[1] -ge $values[0] -and $values[1] -le [int]$source.pageCount) "Invalid review batch for $sourceId"
      $coveredPages += @($values[0]..$values[1])
    }
    $allPages = @(1..[int]$source.pageCount)
    Assert-Equal $coveredPages.Count $allPages.Count "Review batches must not overlap for $sourceId"
    Test-IntArrayEqual @($coveredPages | Sort-Object) $allPages "Review batches must cover every source page exactly once for $sourceId"
  }

  $artifacts = @(As-Array $Document.artifacts)
  $expectedArtifactCount = 0
  foreach ($source in $sources) { $expectedArtifactCount += @(As-Array $source.problemPageMap).Count }
  Assert-Equal $artifacts.Count $expectedArtifactCount "Rendered problem-page artifact count"
  $artifactPaths = @($artifacts | ForEach-Object { [string]$_.path })
  Assert-Equal (@($artifactPaths | Sort-Object -Unique).Count) $artifactPaths.Count "Artifact paths must be unique."

  foreach ($artifact in $artifacts) {
    $relativePath = [string]$artifact.path
    $fullPath = Get-ArtifactFullPath $fixtureRoot $relativePath
    Assert-True (Test-Path -LiteralPath $fullPath -PathType Leaf) "Missing rendered artifact: $relativePath"
    Assert-Sha256 ([string]$artifact.sha256) "Rendered artifact $relativePath hash"
    $observedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash
    Assert-Equal $observedHash.ToUpperInvariant() ([string]$artifact.sha256).ToUpperInvariant() "Rendered artifact SHA-256 for $relativePath"
    Assert-True ([int]$artifact.width -gt 0 -and [int]$artifact.height -gt 0) "Rendered dimensions must be positive for $relativePath"
    Assert-Equal ([string]$artifact.role) "problem-page-render" "Rendered artifact role for $relativePath"
    $source = Find-Source $sources ([string]$artifact.sourceId)
    $pageRows = @(As-Array $source.problemPageMap | Where-Object { [int]$_.page -eq [int]$artifact.page })
    Assert-Equal $pageRows.Count 1 "Rendered page-map row for $relativePath"
    Assert-Equal ([string]$pageRows[0].artifact) $relativePath "Rendered artifact page-map binding for $relativePath"
  }

  foreach ($source in $sources) {
    $pageRows = @(As-Array $source.problemPageMap)
    $problemPages = @((As-Array $source.problemPages) | ForEach-Object { [int]$_ })
    Assert-Equal $pageRows.Count $problemPages.Count "Problem-page map count for $($source.id)"
    $mappedPages = @($pageRows | ForEach-Object { [int]$_.page } | Sort-Object)
    Test-IntArrayEqual $mappedPages (@($problemPages | Sort-Object)) "Problem-page map pages for $($source.id)"
    $allNumbers = @()
    foreach ($row in $pageRows) {
      $numbers = @((As-Array $row.printedProblemNumbers) | ForEach-Object { [int]$_ })
      Assert-True ($numbers.Count -gt 0) "Printed problem numbers required for $($source.id) page $($row.page)"
      Assert-Equal (@($numbers | Sort-Object -Unique).Count) $numbers.Count "Duplicate printed problem number on $($source.id) page $($row.page)"
      $allNumbers += $numbers
      $artifact = Find-Artifact $artifacts ([string]$row.artifact)
      Assert-Equal ([string]$artifact.sourceId) ([string]$source.id) "Page-map source binding for $($source.id) page $($row.page)"
      Assert-Equal ([int]$artifact.page) ([int]$row.page) "Page-map page binding for $($source.id) page $($row.page)"
    }
    $allNumbers = @($allNumbers | Sort-Object)
    $expectedNumbers = @(1..([int]($allNumbers | Measure-Object -Maximum).Maximum))
    Test-IntArrayEqual $allNumbers $expectedNumbers "Printed problem-number sequence for $($source.id)"
  }

  $coverage = @(As-Array $Document.coverage)
  Assert-Equal $coverage.Count 4 "Segmentation class count"
  $coverageClasses = @($coverage | ForEach-Object { [string]$_.class })
  Assert-Equal (@($coverageClasses | Sort-Object -Unique).Count) $coverageClasses.Count "Segmentation class IDs must be unique."
  $requiredClasses = @("two_column_ordering", "diagram_heavy", "common_passage_subquestions", "page_spanning_problem")
  foreach ($required in $requiredClasses) { Assert-True ($coverageClasses -ccontains $required) "Missing segmentation class $required" }

  $twoColumn = @($coverage | Where-Object { $_.class -ceq "two_column_ordering" })[0]
  Assert-Equal ([string]$twoColumn.status) "present" "Two-column status"
  $twoEvidence = @(As-Array $twoColumn.evidence)
  Assert-Equal $twoEvidence.Count 1 "Two-column evidence count"
  $two = $twoEvidence[0]
  Assert-Equal ([string]$two.sourceId) "daejin2" "Two-column source"
  Assert-Equal ([int]$two.page) 1 "Two-column page"
  Assert-Equal ([string]$two.readingOrder) "printed_problem_number" "Two-column reading order contract"
  Test-IntArrayEqual @((As-Array $two.printedProblemNumbers) | ForEach-Object { [int]$_ }) @(1, 2, 3, 4) "Two-column printed order"
  $twoSegments = @(As-Array $two.segments)
  Assert-Equal $twoSegments.Count 4 "Two-column segment count"
  $twoOrder = @($twoSegments | Sort-Object orderIndex | ForEach-Object { [int]$_.problemNumber })
  Test-IntArrayEqual $twoOrder @(1, 2, 3, 4) "Two-column segment order"
  foreach ($segment in $twoSegments) {
    Assert-True ([int]$segment.orderIndex -ge 1 -and [int]$segment.orderIndex -le 4) "Two-column order index out of range"
    $bbox = @($segment.bbox | ForEach-Object { [int]$_ })
    Assert-Equal $bbox.Count 4 "Two-column bounding-box arity"
    Assert-True ($bbox[0] -ge 0 -and $bbox[1] -ge 0 -and $bbox[2] -gt $bbox[0] -and $bbox[3] -gt $bbox[1] -and $bbox[2] -le 1458 -and $bbox[3] -le 2064) "Two-column bounding box outside daejin2 page bounds"
  }
  $twoSource = Find-Source $sources ([string]$two.sourceId)
  $twoPageRow = @(As-Array $twoSource.problemPageMap | Where-Object { [int]$_.page -eq [int]$two.page })
  Assert-Equal $twoPageRow.Count 1 "Two-column page-map binding"
  Assert-Equal ([string]$twoPageRow[0].artifact) ([string]$two.artifact) "Two-column evidence artifact binding"
  $twoArtifact = Find-Artifact $artifacts ([string]$two.artifact)
  Assert-Equal ([string]$twoArtifact.sourceId) ([string]$two.sourceId) "Two-column artifact source"
  Assert-Equal ([int]$twoArtifact.page) 1 "Two-column artifact page"

  $diagram = @($coverage | Where-Object { $_.class -ceq "diagram_heavy" })[0]
  Assert-Equal ([string]$diagram.status) "present" "Diagram-heavy status"
  $diagramEvidence = @(As-Array $diagram.evidence)
  Assert-True ($diagramEvidence.Count -ge 2) "At least two diagram-heavy real-PDF examples are required"
  foreach ($item in $diagramEvidence) {
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$item.diagramType)) "Diagram type required"
    Assert-True ([int]$item.problemNumber -gt 0) "Diagram-heavy problem number required"
    $source = Find-Source $sources ([string]$item.sourceId)
    $row = @(As-Array $source.problemPageMap | Where-Object { [int]$_.page -eq [int]$item.page })
    Assert-Equal $row.Count 1 "Diagram page-map binding"
    $pageNumbers = @((As-Array $row[0].printedProblemNumbers) | ForEach-Object { [int]$_ })
    Assert-True ($pageNumbers -contains [int]$item.problemNumber) "Diagram problem number is not on its cited page"
    Assert-Equal ([string]$row[0].artifact) ([string]$item.artifact) "Diagram evidence artifact binding"
    $artifact = Find-Artifact $artifacts ([string]$item.artifact)
    Assert-Equal ([string]$artifact.sourceId) ([string]$item.sourceId) "Diagram artifact source binding"
    Assert-Equal ([int]$artifact.page) ([int]$item.page) "Diagram artifact page binding"
    $bbox = @($item.diagramBbox | ForEach-Object { [int]$_ })
    Assert-Equal $bbox.Count 4 "Diagram bounding-box arity"
    Assert-True ($bbox[0] -ge 0 -and $bbox[1] -ge 0 -and $bbox[2] -gt $bbox[0] -and $bbox[3] -gt $bbox[1] -and $bbox[2] -le [int]$artifact.width -and $bbox[3] -le [int]$artifact.height) "Diagram bounding box outside render bounds"
  }

  foreach ($absentClass in @("common_passage_subquestions", "page_spanning_problem")) {
    $entry = @($coverage | Where-Object { $_.class -ceq $absentClass })[0]
    Assert-Equal ([string]$entry.status) "absent" "$absentClass status"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.reason)) "$absentClass must include an honest absence reason"
    Test-IntArrayEqual @((As-Array $entry.auditedSourceIds | ForEach-Object { [int]([array]::IndexOf(@($sourceIds), [string]$_)) })) @((0..($sourceIds.Count - 1))) "$absentClass audited sources"
  }

  Assert-True ([bool]$Document.safety.sourcePagesOnly) "Corpus must be source-problem-pages only"
  Assert-True (-not [bool]$Document.safety.answerOrSolutionPagesIncluded) "Answer/solution pages must not be included"
  Assert-True (-not [bool]$Document.safety.liveBrowserActions) "Segmentation corpus must not use live browser actions"
  Assert-True (-not [bool]$Document.safety.'출제하기Clicked') "출제하기 must remain unclicked"
}

$fixturePath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\pdf-segmentation\segmentation-corpus-2026-07-31.json"
Assert-True (Test-Path -LiteralPath $fixturePath -PathType Leaf) "Missing PDF segmentation corpus fixture: $fixturePath"
$fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Case -cin @("All", "Evidence")) {
  Invoke-PdfSegmentationValidation $fixture $ProjectRoot ([bool]$RequireSourcePdfs)

  # The installed kit does not ship user-owned PDFs. Exercise that portable
  # mode even on the evidence machine where both pinned originals are present.
  $packagedOnlyFixture = Copy-Document $fixture
  $missingSourceRoot = Join-Path ([IO.Path]::GetTempPath()) ("mathsecr-pdf-segmentation-missing-" + [Guid]::NewGuid().ToString("N"))
  foreach ($source in @($packagedOnlyFixture.sources)) {
    $source.path = Join-Path $missingSourceRoot ("$($source.id).pdf")
  }
  Invoke-PdfSegmentationValidation $packagedOnlyFixture $ProjectRoot $false
}

if ($Case -cin @("All", "Red")) {
  $redCases = @()

  $wrongArtifactHash = Copy-Document $fixture
  $wrongArtifactHash.artifacts[0].sha256 = ('A' * 64)
  $redCases += @{ Name = "wrong rendered-artifact hash"; Document = $wrongArtifactHash }

  $forgedAbsentClass = Copy-Document $fixture
  $forgedAbsentClass.coverage[2].status = "present"
  $redCases += @{ Name = "forged common-passage presence"; Document = $forgedAbsentClass }

  $brokenColumnOrder = Copy-Document $fixture
  $brokenColumnOrder.coverage[0].evidence[0].segments[2].orderIndex = 1
  $redCases += @{ Name = "duplicate two-column order index"; Document = $brokenColumnOrder }

  $outOfBoundsDiagram = Copy-Document $fixture
  $outOfBoundsDiagram.coverage[1].evidence[0].diagramBbox[2] = 2000
  $redCases += @{ Name = "out-of-bounds diagram box"; Document = $outOfBoundsDiagram }

  $outOfRangeExcludedPage = Copy-Document $fixture
  $outOfRangeExcludedPage.sources[0].excludedPages[0] = 99
  $redCases += @{ Name = "out-of-range excluded page"; Document = $outOfRangeExcludedPage }

  $overlappingReviewBatch = Copy-Document $fixture
  $overlappingReviewBatch.sources[0].reviewBatches[3][0] = 12
  $redCases += @{ Name = "overlapping review batch"; Document = $overlappingReviewBatch }

  $misboundTwoColumnArtifact = Copy-Document $fixture
  $misboundTwoColumnArtifact.coverage[0].evidence[0].artifact = "rendered-pages/juyeop1-page-01.png"
  $redCases += @{ Name = "misbound two-column artifact"; Document = $misboundTwoColumnArtifact }

  $misboundDiagramArtifact = Copy-Document $fixture
  $misboundDiagramArtifact.coverage[1].evidence[0].artifact = "rendered-pages/juyeop1-page-03.png"
  $redCases += @{ Name = "misbound diagram artifact"; Document = $misboundDiagramArtifact }

  foreach ($redCase in $redCases) {
    $rejected = $false
    try { Invoke-PdfSegmentationValidation $redCase.Document $ProjectRoot ([bool]$RequireSourcePdfs) } catch { $rejected = $true }
    Assert-True $rejected "Red case '$($redCase.Name)' unexpectedly passed."
  }
}

$missingSourcePdfCount = @($fixture.sources | Where-Object { -not (Test-Path -LiteralPath ([string]$_.path) -PathType Leaf) }).Count
$sourceMode = if ($RequireSourcePdfs) { "required" } elseif ($missingSourcePdfCount -eq 0) { "available" } else { "packaged-only" }
switch ($Case) {
  "Evidence" { Write-Host "PdfSegmentation Evidence PASS (2 pinned source records; source_mode=$sourceMode; truth_scope=dated-characterization; packaged_missing_source_case=true; 13 rendered problem pages; 2 present classes; 2 honest gaps)" }
  "Red" { Write-Host "PdfSegmentation Red PASS (8 intentional rejection cases; source_mode=$sourceMode; truth_scope=dated-characterization)" }
  default { Write-Host "PdfSegmentation PASS (2 pinned source records; source_mode=$sourceMode; truth_scope=dated-characterization; packaged_missing_source_case=true; 13 rendered problem pages; 2 present classes; 2 honest gaps; 8 red cases)" }
}
