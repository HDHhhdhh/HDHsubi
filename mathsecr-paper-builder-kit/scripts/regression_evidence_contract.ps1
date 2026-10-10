function Invoke-MathSecrRegressionEvidenceFailure {
  param([string]$Message)
  throw "regression-evidence: $Message"
}

function Get-MathSecrRegressionEvidenceProperty {
  param($Object, [string]$Name, [string]$Label)

  if ($null -eq $Object) {
    Invoke-MathSecrRegressionEvidenceFailure "$Label is null."
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    Invoke-MathSecrRegressionEvidenceFailure "$Label is missing property '$Name'."
  }
  return $property
}

function Get-MathSecrRegressionEvidenceString {
  param($Object, [string]$Name, [string]$Label)

  $value = (Get-MathSecrRegressionEvidenceProperty $Object $Name $Label).Value
  if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
    Invoke-MathSecrRegressionEvidenceFailure "$Label.$Name must be a non-empty string."
  }
  return [string]$value
}

function Get-MathSecrRegressionEvidenceBoolean {
  param($Object, [string]$Name, [string]$Label)

  $value = (Get-MathSecrRegressionEvidenceProperty $Object $Name $Label).Value
  if ($value -isnot [bool]) {
    Invoke-MathSecrRegressionEvidenceFailure "$Label.$Name must be a strict Boolean."
  }
  return [bool]$value
}

function Resolve-MathSecrRegressionEvidencePath {
  param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Label,
    [switch]$AllowMissingLeaf
  )

  $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($RelativePath)) {
    Invoke-MathSecrRegressionEvidenceFailure "$Label must be a non-empty ProjectRoot-relative path."
  }
  $normalized = $RelativePath.Replace('/', '\')
  if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized -match '^[A-Za-z]:') {
    Invoke-MathSecrRegressionEvidenceFailure "$Label must be ProjectRoot-relative: $RelativePath"
  }
  $segments = @($normalized -split '\\+' | Where-Object { $_ -ne '' })
  foreach ($segment in $segments) {
    if ($segment -ceq '.' -or $segment -ceq '..') {
      Invoke-MathSecrRegressionEvidenceFailure "$Label contains a traversal segment: $RelativePath"
    }
  }
  try {
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootFull $normalized))
  } catch {
    Invoke-MathSecrRegressionEvidenceFailure "$Label is not a valid relative path: $RelativePath"
  }
  $rootPrefix = $rootFull + '\'
  if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Invoke-MathSecrRegressionEvidenceFailure "$Label resolves outside ProjectRoot: $RelativePath"
  }

  $currentPath = $rootFull
  foreach ($segment in $segments) {
    $currentPath = [System.IO.Path]::Combine($currentPath, [string]$segment)
    if (Test-Path -LiteralPath $currentPath) {
      $item = Get-Item -LiteralPath $currentPath -Force
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Invoke-MathSecrRegressionEvidenceFailure "$Label crosses a reparse point: $RelativePath"
      }
    }
  }
  if (-not $AllowMissingLeaf -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    Invoke-MathSecrRegressionEvidenceFailure "$Label does not exist: $RelativePath"
  }
  return $fullPath
}

function Get-MathSecrRegressionRelativePath {
  param([string]$ProjectRoot, [string]$FullPath, [string]$Label)

  $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
  $pathFull = [System.IO.Path]::GetFullPath($FullPath)
  $prefix = $rootFull + '\'
  if (-not $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Invoke-MathSecrRegressionEvidenceFailure "$Label must stay under ProjectRoot: $pathFull"
  }
  return $pathFull.Substring($prefix.Length).Replace('\', '/')
}

function Get-MathSecrRegressionBytesHash {
  param([byte[]]$Bytes)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

function Get-MathSecrRegressionEvidenceSidecarPath {
  param([Parameter(Mandatory = $true)][string]$EvidencePath)
  return "$EvidencePath.manifest.json"
}

function Add-MathSecrRegressionReferencedEvidencePath {
  param(
    [Parameter(Mandatory = $true)]$Paths,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$DeclaredPath,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $normalized = $DeclaredPath.Replace('\', '/')
  $prefix = '.omo/evidence/'
  if (-not $normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return
  }
  $leaf = $normalized.Substring($prefix.Length)
  if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf.Contains('/')) {
    Invoke-MathSecrRegressionEvidenceFailure "$Label must reference a direct .omo/evidence child: $DeclaredPath"
  }
  if ($leaf -ceq '.' -or $leaf -ceq '..') {
    Invoke-MathSecrRegressionEvidenceFailure "$Label contains a traversal segment: $DeclaredPath"
  }
  $relativePath = "$prefix$leaf"
  $null = Resolve-MathSecrRegressionEvidencePath $ProjectRoot $relativePath $Label
  [void]$Paths.Add($relativePath)
}

function Get-MathSecrRegressionReferencedEvidencePaths {
  param([Parameter(Mandatory = $true)][string]$ProjectRoot)

  $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
  $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  # The installer owns the baseline evidence list.  Parse only the static
  # RequiredEvidenceNames initializer; do not execute the installer.
  $installerRelative = 'mathsecr-paper-builder-kit/scripts/install.ps1'
  $installerPath = Resolve-MathSecrRegressionEvidencePath $rootFull $installerRelative 'installer declaration'
  $tokens = $null
  $parseErrors = $null
  try {
    $installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
  } catch {
    Invoke-MathSecrRegressionEvidenceFailure "installer declaration is not parseable: $($_.Exception.Message)"
  }
  if (@($parseErrors).Count -gt 0) {
    Invoke-MathSecrRegressionEvidenceFailure 'installer declaration contains PowerShell parse errors.'
  }
  $assignmentType = [System.Management.Automation.Language.AssignmentStatementAst]
  $variableType = [System.Management.Automation.Language.VariableExpressionAst]
  $arrayExpressionType = [System.Management.Automation.Language.ArrayExpressionAst]
  $arrayLiteralType = [System.Management.Automation.Language.ArrayLiteralAst]
  $stringType = [System.Management.Automation.Language.StringConstantExpressionAst]
  $assignments = @($installerAst.FindAll({ param($node)
      $node -is $assignmentType -and
      $node.Left -is $variableType -and
      $node.Left.VariablePath.UserPath -ceq 'RequiredEvidenceNames'
    }, $true))
  $initializers = @($assignments | Where-Object {
      $expression = $_.Right.Expression
      if ($expression -isnot $arrayExpressionType -and $expression -isnot $arrayLiteralType) {
        return $false
      }
      $variableNodes = @($expression.FindAll({ param($node) $node -is $variableType }, $true))
      $commandNodes = @($expression.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
      return $variableNodes.Count -eq 0 -and $commandNodes.Count -eq 0
    })
  if ($initializers.Count -ne 1) {
    Invoke-MathSecrRegressionEvidenceFailure 'installer must contain exactly one static RequiredEvidenceNames initializer.'
  }
  $installerEvidenceNames = @($initializers[0].Right.FindAll({ param($node) $node -is $stringType }, $true) |
    ForEach-Object { [string]$_.Value })
  if ($installerEvidenceNames.Count -eq 0) {
    Invoke-MathSecrRegressionEvidenceFailure 'installer RequiredEvidenceNames initializer must not be empty.'
  }
  foreach ($name in $installerEvidenceNames) {
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('/') -or $name.Contains('\') -or
        $name -ceq '.' -or $name -ceq '..') {
      Invoke-MathSecrRegressionEvidenceFailure "installer evidence name must be a direct filename: $name"
    }
    Add-MathSecrRegressionReferencedEvidencePath $paths $rootFull ".omo/evidence/$name" 'installer evidence'
  }

  $re0Relative = 'mathsecr-paper-builder-kit/test-fixtures/lessons/re0-memo-registry.json'
  $re0Path = Resolve-MathSecrRegressionEvidencePath $rootFull $re0Relative 're0-memo registry'
  try {
    $re0Registry = Get-Content -LiteralPath $re0Path -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Invoke-MathSecrRegressionEvidenceFailure "re0-memo registry is not valid JSON: $($_.Exception.Message)"
  }
  $lessonsProperty = Get-MathSecrRegressionEvidenceProperty $re0Registry 'lessons' 're0-memo registry'
  foreach ($lesson in @($lessonsProperty.Value)) {
    $evidenceProperty = Get-MathSecrRegressionEvidenceProperty $lesson 'evidence' 're0-memo lesson'
    foreach ($declaredPath in @($evidenceProperty.Value)) {
      if ($declaredPath -isnot [string]) {
        Invoke-MathSecrRegressionEvidenceFailure 're0-memo evidence paths must be strings.'
      }
      Add-MathSecrRegressionReferencedEvidencePath $paths $rootFull ([string]$declaredPath) 're0-memo evidence'
      $normalized = ([string]$declaredPath).Replace('\', '/')
      if (-not $normalized.StartsWith('.omo/evidence/', [System.StringComparison]::OrdinalIgnoreCase)) {
        Invoke-MathSecrRegressionEvidenceFailure "re0-memo evidence must stay under .omo/evidence: $declaredPath"
      }
    }
  }

  $groundTruthRelative = 'mathsecr-paper-builder-kit/test-fixtures/evaluation/ground-truth-claims.json'
  $groundTruthPath = Resolve-MathSecrRegressionEvidencePath $rootFull $groundTruthRelative 'ground-truth registry'
  try {
    $groundTruthRegistry = Get-Content -LiteralPath $groundTruthPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Invoke-MathSecrRegressionEvidenceFailure "ground-truth registry is not valid JSON: $($_.Exception.Message)"
  }
  $claimsProperty = Get-MathSecrRegressionEvidenceProperty $groundTruthRegistry 'claims' 'ground-truth registry'
  foreach ($claim in @($claimsProperty.Value)) {
    $designProperty = Get-MathSecrRegressionEvidenceProperty $claim 'designArtifacts' 'ground-truth claim'
    foreach ($declaredPath in @($designProperty.Value)) {
      if ($declaredPath -isnot [string]) {
        Invoke-MathSecrRegressionEvidenceFailure 'ground-truth design artifact paths must be strings.'
      }
      Add-MathSecrRegressionReferencedEvidencePath $paths $rootFull ([string]$declaredPath) 'ground-truth design evidence'
    }
    $oracleProperty = Get-MathSecrRegressionEvidenceProperty $claim 'oracleArtifacts' 'ground-truth claim'
    foreach ($oracle in @($oracleProperty.Value)) {
      $oraclePathProperty = Get-MathSecrRegressionEvidenceProperty $oracle 'path' 'ground-truth oracle artifact'
      $declaredPath = $oraclePathProperty.Value
      if ($declaredPath -isnot [string]) {
        Invoke-MathSecrRegressionEvidenceFailure 'ground-truth oracle artifact paths must be strings.'
      }
      Add-MathSecrRegressionReferencedEvidencePath $paths $rootFull ([string]$declaredPath) 'ground-truth oracle evidence'
    }
  }

  return [string[]]@($paths | Sort-Object)
}

function Get-MathSecrRegressionInputSnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$EvidencePath
  )

  $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
  $evidenceRelative = Get-MathSecrRegressionRelativePath $rootFull $EvidencePath 'EvidencePath'
  $null = Resolve-MathSecrRegressionEvidencePath $rootFull $evidenceRelative 'EvidencePath' -AllowMissingLeaf
  $sidecarPath = Get-MathSecrRegressionEvidenceSidecarPath $EvidencePath
  $sidecarRelative = Get-MathSecrRegressionRelativePath $rootFull $sidecarPath 'Evidence sidecar path'
  $null = Resolve-MathSecrRegressionEvidencePath $rootFull $sidecarRelative 'Evidence sidecar path' -AllowMissingLeaf

  $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  [void]$excluded.Add([System.IO.Path]::GetFullPath($EvidencePath))
  [void]$excluded.Add([System.IO.Path]::GetFullPath($sidecarPath))

  $candidateFiles = New-Object 'System.Collections.Generic.List[string]'
  $agentsPath = Join-Path $rootFull 'AGENTS.md'
  if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
    Invoke-MathSecrRegressionEvidenceFailure 'ProjectRoot/AGENTS.md is required for the validation input manifest.'
  }
  [void]$candidateFiles.Add($agentsPath)

  foreach ($relativeRoot in @('mathsecr-paper-builder-kit', '.omo\prompts')) {
    $inputRoot = Join-Path $rootFull $relativeRoot
    if (-not (Test-Path -LiteralPath $inputRoot -PathType Container)) {
      if ($relativeRoot -ceq 'mathsecr-paper-builder-kit') {
        Invoke-MathSecrRegressionEvidenceFailure "Missing validation input root: $relativeRoot"
      }
      continue
    }
    $rootItem = Get-Item -LiteralPath $inputRoot -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      Invoke-MathSecrRegressionEvidenceFailure "Validation input root is a reparse point: $relativeRoot"
    }
    foreach ($item in Get-ChildItem -LiteralPath $inputRoot -Force -Recurse) {
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Invoke-MathSecrRegressionEvidenceFailure "Validation input crosses a reparse point: $($item.FullName)"
      }
      if (-not $item.PSIsContainer) {
        $itemFull = [System.IO.Path]::GetFullPath($item.FullName)
        if ($excluded.Contains($itemFull)) { continue }
        [void]$candidateFiles.Add($itemFull)
      }
    }
  }

  foreach ($relativePath in @(Get-MathSecrRegressionReferencedEvidencePaths $rootFull)) {
    $referencedPath = Resolve-MathSecrRegressionEvidencePath $rootFull $relativePath 'referenced evidence'
    $referencedFull = [System.IO.Path]::GetFullPath($referencedPath)
    if ($excluded.Contains($referencedFull)) {
      Invoke-MathSecrRegressionEvidenceFailure 'a declared validation input cannot reference the regression output or its sidecar.'
    }
    [void]$candidateFiles.Add($referencedFull)
  }

  $relativePaths = [string[]]@($candidateFiles | ForEach-Object {
      Get-MathSecrRegressionRelativePath $rootFull $_ 'validation input'
    } | Select-Object -Unique)
  [System.Array]::Sort($relativePaths, [System.StringComparer]::Ordinal)

  $manifestLines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($relativePath in $relativePaths) {
    $fullPath = Resolve-MathSecrRegressionEvidencePath $rootFull $relativePath 'validation input'
    $fileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToUpperInvariant()
    [void]$manifestLines.Add("$relativePath|$fileHash")
  }
  $manifestText = (($manifestLines -join "`n") + "`n")
  $manifestBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($manifestText)
  $runnerRelative = 'mathsecr-paper-builder-kit/scripts/run_mathsecr_regression.ps1'
  $runnerPath = Resolve-MathSecrRegressionEvidencePath $rootFull $runnerRelative 'regression runner'

  return [pscustomobject]@{
    FileCount = [int]$relativePaths.Count
    InputManifestSha256 = Get-MathSecrRegressionBytesHash $manifestBytes
    RunnerSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $runnerPath).Hash.ToUpperInvariant()
  }
}

function Write-MathSecrRegressionEvidenceSidecar {
  param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$EvidencePath,
    [Parameter(Mandatory = $true)]$StartSnapshot,
    [Parameter(Mandatory = $true)][DateTimeOffset]$StartedAtUtc,
    [Parameter(Mandatory = $true)][DateTimeOffset]$CompletedAtUtc
  )

  if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
    Invoke-MathSecrRegressionEvidenceFailure "PASS evidence does not exist: $EvidencePath"
  }
  $current = Get-MathSecrRegressionInputSnapshot -ProjectRoot $ProjectRoot -EvidencePath $EvidencePath
  if ($current.FileCount -ne $StartSnapshot.FileCount -or
      $current.InputManifestSha256 -cne $StartSnapshot.InputManifestSha256 -or
      $current.RunnerSha256 -cne $StartSnapshot.RunnerSha256) {
    Invoke-MathSecrRegressionEvidenceFailure 'validation inputs changed while the regression pack was running.'
  }
  $evidenceRelative = Get-MathSecrRegressionRelativePath $ProjectRoot $EvidencePath 'EvidencePath'
  $sidecarPath = Get-MathSecrRegressionEvidenceSidecarPath $EvidencePath
  $sidecar = [ordered]@{
    schemaVersion = 1
    truthScope = 'offline-contract'
    productBehavior = $false
    result = 'PASS'
    evidencePath = $evidenceRelative
    evidenceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $EvidencePath).Hash.ToUpperInvariant()
    inputFileCount = [int]$current.FileCount
    inputManifestSha256 = [string]$current.InputManifestSha256
    runnerSha256 = [string]$current.RunnerSha256
    startedAtUtc = 'UTC|' + $StartedAtUtc.ToUniversalTime().ToString('o')
    completedAtUtc = 'UTC|' + $CompletedAtUtc.ToUniversalTime().ToString('o')
  }
  $json = $sidecar | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText($sidecarPath, ($json + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  return $sidecarPath
}

function Test-MathSecrRegressionEvidenceSidecar {
  param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$EvidencePath
  )

  $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
  $evidenceRelative = Get-MathSecrRegressionRelativePath $rootFull $EvidencePath 'EvidencePath'
  $evidenceFull = Resolve-MathSecrRegressionEvidencePath $rootFull $evidenceRelative 'EvidencePath'
  $sidecarPath = Get-MathSecrRegressionEvidenceSidecarPath $evidenceFull
  $sidecarRelative = Get-MathSecrRegressionRelativePath $rootFull $sidecarPath 'Evidence sidecar path'
  $sidecarFull = Resolve-MathSecrRegressionEvidencePath $rootFull $sidecarRelative 'Evidence sidecar path'

  try {
    $document = Get-Content -LiteralPath $sidecarFull -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Invoke-MathSecrRegressionEvidenceFailure "sidecar is not valid JSON: $($_.Exception.Message)"
  }
  $expectedProperties = [string[]]@(
    'schemaVersion', 'truthScope', 'productBehavior', 'result', 'evidencePath',
    'evidenceSha256', 'inputFileCount', 'inputManifestSha256', 'runnerSha256',
    'startedAtUtc', 'completedAtUtc'
  )
  $actualProperties = [string[]]@($document.PSObject.Properties.Name)
  [System.Array]::Sort($expectedProperties, [System.StringComparer]::Ordinal)
  [System.Array]::Sort($actualProperties, [System.StringComparer]::Ordinal)
  if (($expectedProperties -join "`n") -cne ($actualProperties -join "`n")) {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar properties must match the exact schema.'
  }
  $schemaVersion = (Get-MathSecrRegressionEvidenceProperty $document 'schemaVersion' 'sidecar').Value
  if ($schemaVersion -ne 1 -or
      ($schemaVersion -isnot [System.Int32] -and $schemaVersion -isnot [System.Int64])) {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar.schemaVersion must be integer 1.'
  }
  if ((Get-MathSecrRegressionEvidenceString $document 'truthScope' 'sidecar') -cne 'offline-contract') {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar.truthScope must be offline-contract.'
  }
  if ((Get-MathSecrRegressionEvidenceBoolean $document 'productBehavior' 'sidecar') -ne $false) {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar.productBehavior must be false.'
  }
  if ((Get-MathSecrRegressionEvidenceString $document 'result' 'sidecar') -cne 'PASS') {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar.result must be PASS.'
  }
  $declaredEvidence = Get-MathSecrRegressionEvidenceString $document 'evidencePath' 'sidecar'
  if ($declaredEvidence -cne $evidenceRelative) {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar.evidencePath does not bind the requested evidence file.'
  }
  $null = Resolve-MathSecrRegressionEvidencePath $rootFull $declaredEvidence 'sidecar.evidencePath'
  $evidenceHash = Get-MathSecrRegressionEvidenceString $document 'evidenceSha256' 'sidecar'
  if ($evidenceHash -notmatch '^[0-9A-F]{64}$' -or
      $evidenceHash -cne (Get-FileHash -Algorithm SHA256 -LiteralPath $evidenceFull).Hash.ToUpperInvariant()) {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar.evidenceSha256 does not match current evidence bytes.'
  }
  $inputFileCount = (Get-MathSecrRegressionEvidenceProperty $document 'inputFileCount' 'sidecar').Value
  if (($inputFileCount -isnot [System.Int32] -and $inputFileCount -isnot [System.Int64]) -or $inputFileCount -lt 1) {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar.inputFileCount must be a positive integer.'
  }
  foreach ($hashName in @('inputManifestSha256', 'runnerSha256')) {
    $hash = Get-MathSecrRegressionEvidenceString $document $hashName 'sidecar'
    if ($hash -notmatch '^[0-9A-F]{64}$') {
      Invoke-MathSecrRegressionEvidenceFailure "sidecar.$hashName must be an uppercase SHA-256."
    }
  }
  $startedText = Get-MathSecrRegressionEvidenceString $document 'startedAtUtc' 'sidecar'
  $completedText = Get-MathSecrRegressionEvidenceString $document 'completedAtUtc' 'sidecar'
  $started = [DateTimeOffset]::MinValue
  $completed = [DateTimeOffset]::MinValue
  if (-not $startedText.StartsWith('UTC|', [System.StringComparison]::Ordinal) -or
      -not $completedText.StartsWith('UTC|', [System.StringComparison]::Ordinal) -or
      -not [DateTimeOffset]::TryParseExact($startedText.Substring(4), 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$started) -or
      -not [DateTimeOffset]::TryParseExact($completedText.Substring(4), 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$completed) -or
      $completed -lt $started) {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar timestamps must be ordered ISO-8601 round-trip values.'
  }
  $evidenceLines = @(Get-Content -LiteralPath $evidenceFull -Encoding UTF8)
  if ($evidenceLines -cnotcontains 'REGRESSION PACK RESULT: PASS') {
    Invoke-MathSecrRegressionEvidenceFailure 'evidence does not contain the exact regression PASS line.'
  }

  $current = Get-MathSecrRegressionInputSnapshot -ProjectRoot $rootFull -EvidencePath $evidenceFull
  if ($current.FileCount -ne $inputFileCount -or
      $current.InputManifestSha256 -cne [string]$document.inputManifestSha256 -or
      $current.RunnerSha256 -cne [string]$document.runnerSha256) {
    Invoke-MathSecrRegressionEvidenceFailure 'sidecar does not match the current validation input bytes.'
  }
  return [pscustomobject]@{
    InputFileCount = [int]$current.FileCount
    InputManifestSha256 = [string]$current.InputManifestSha256
    EvidenceSha256 = [string]$evidenceHash
  }
}
