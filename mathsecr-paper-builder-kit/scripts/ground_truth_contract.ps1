function Invoke-MathSecrGroundTruthFailure {
  param([string]$Message)
  throw "ground-truth: $Message"
}

function Get-MathSecrGroundTruthProperty {
  param($Object, [string]$Name, [string]$Label)

  if ($null -eq $Object) {
    Invoke-MathSecrGroundTruthFailure "$Label is null."
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    Invoke-MathSecrGroundTruthFailure "$Label is missing property '$Name'."
  }
  return $property
}

function Get-MathSecrGroundTruthString {
  param($Object, [string]$Name, [string]$Label)

  $value = (Get-MathSecrGroundTruthProperty $Object $Name $Label).Value
  if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
    Invoke-MathSecrGroundTruthFailure "$Label.$Name must be a non-empty string."
  }
  return [string]$value
}

function Get-MathSecrGroundTruthArray {
  param($Object, [string]$Name, [string]$Label)

  $value = (Get-MathSecrGroundTruthProperty $Object $Name $Label).Value
  if ($value -isnot [System.Array]) {
    Invoke-MathSecrGroundTruthFailure "$Label.$Name must be an array."
  }
  return $value
}

function Get-MathSecrGroundTruthBoolean {
  param($Object, [string]$Name, [string]$Label)

  $value = (Get-MathSecrGroundTruthProperty $Object $Name $Label).Value
  if ($value -isnot [bool]) {
    Invoke-MathSecrGroundTruthFailure "$Label.$Name must be a strict Boolean."
  }
  return [bool]$value
}

function Resolve-MathSecrGroundTruthPath {
  param([string]$ProjectRoot, [string]$RelativePath, [string]$Label)

  if ([string]::IsNullOrWhiteSpace($RelativePath)) {
    Invoke-MathSecrGroundTruthFailure "$Label must be a non-empty ProjectRoot-relative path."
  }
  $normalized = $RelativePath.Replace('/', '\')
  if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized -match '^[A-Za-z]:') {
    Invoke-MathSecrGroundTruthFailure "$Label must be ProjectRoot-relative: $RelativePath"
  }
  $segments = @($normalized -split '\\+' | Where-Object { $_ -ne '' })
  foreach ($segment in $segments) {
    if ($segment -ceq '.' -or $segment -ceq '..') {
      Invoke-MathSecrGroundTruthFailure "$Label contains a traversal segment: $RelativePath"
    }
  }
  try {
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $normalized))
  } catch {
    Invoke-MathSecrGroundTruthFailure "$Label is not a valid relative path: $RelativePath"
  }
  $rootPrefix = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\'
  if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Invoke-MathSecrGroundTruthFailure "$Label resolves outside ProjectRoot: $RelativePath"
  }
  $currentPath = [System.IO.Path]::GetFullPath($ProjectRoot)
  $pathsToInspect = New-Object 'System.Collections.Generic.List[string]'
  [void]$pathsToInspect.Add($currentPath)
  foreach ($segment in $segments) {
    $currentPath = [System.IO.Path]::Combine($currentPath, [string]$segment)
    [void]$pathsToInspect.Add($currentPath)
  }
  foreach ($candidatePath in $pathsToInspect) {
    if (Test-Path -LiteralPath $candidatePath) {
      $item = Get-Item -LiteralPath $candidatePath -Force
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Invoke-MathSecrGroundTruthFailure "$Label crosses a reparse point: $RelativePath"
      }
    }
  }
  return $fullPath
}

function Assert-MathSecrGroundTruthStringArray {
  param([object[]]$Values, [string]$Label, [switch]$AllowEmpty)

  if (-not $AllowEmpty -and $Values.Count -eq 0) {
    Invoke-MathSecrGroundTruthFailure "$Label must not be empty."
  }
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
  foreach ($value in $Values) {
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
      Invoke-MathSecrGroundTruthFailure "$Label must contain only non-empty strings."
    }
    if (-not $seen.Add([string]$value)) {
      Invoke-MathSecrGroundTruthFailure "$Label repeats '$value'."
    }
  }
}

function Assert-MathSecrGroundTruthSet {
  param([object[]]$Actual, [string[]]$Expected, [string]$Label)

  Assert-MathSecrGroundTruthStringArray $Actual $Label -AllowEmpty
  $actualSorted = @($Actual | Sort-Object -CaseSensitive)
  $expectedSorted = @($Expected | Sort-Object -CaseSensitive)
  if ($actualSorted.Count -ne $expectedSorted.Count) {
    Invoke-MathSecrGroundTruthFailure "$Label must be the exact set [$($expectedSorted -join ', ')]."
  }
  for ($index = 0; $index -lt $expectedSorted.Count; $index++) {
    if ($actualSorted[$index] -cne $expectedSorted[$index]) {
      Invoke-MathSecrGroundTruthFailure "$Label must be the exact set [$($expectedSorted -join ', ')]."
    }
  }
}

function Get-MathSecrGroundTruthRunnerGates {
  param([string]$RunnerPath)

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($RunnerPath, [ref]$tokens, [ref]$errors)
  if (@($errors).Count -gt 0) {
    Invoke-MathSecrGroundTruthFailure "runner is not valid PowerShell: $($errors[0].Message)"
  }
  $gates = New-Object 'System.Collections.Generic.List[object]'
  foreach ($command in @($ast.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-Logged'
        }, $true))) {
    $elements = @($command.CommandElements)
    if ($elements.Count -ge 2 -and $elements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
      $scriptBlocks = @($elements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] })
      $dispatches = @()
      if ($scriptBlocks.Count -eq 1) {
        $statements = @($scriptBlocks[0].ScriptBlock.EndBlock.Statements)
        if ($statements.Count -eq 1 -and
            $statements[0] -is [System.Management.Automation.Language.PipelineAst] -and
            @($statements[0].PipelineElements).Count -eq 1 -and
            $statements[0].PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
            $statements[0].PipelineElements[0].GetCommandName() -ceq 'Invoke-Script') {
          $dispatches = @($statements[0].PipelineElements[0])
        }
      }
      $relativePath = $null
      $runnerCase = $null
      if ($dispatches.Count -eq 1) {
        $dispatchElements = @($dispatches[0].CommandElements)
        for ($index = 0; $index -lt ($dispatchElements.Count - 1); $index++) {
          if ($dispatchElements[$index] -is [System.Management.Automation.Language.CommandParameterAst] -and
              $dispatchElements[$index].ParameterName -ceq 'RelativePath' -and
              $dispatchElements[$index + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $relativePath = [string]$dispatchElements[$index + 1].Value
          }
        }
        $runnerCase = 'default'
        $parameterTables = @($dispatchElements | Where-Object { $_ -is [System.Management.Automation.Language.HashtableAst] })
        if ($parameterTables.Count -gt 1) {
          $runnerCase = $null
        } elseif ($parameterTables.Count -eq 1) {
          $casePairs = @($parameterTables[0].KeyValuePairs | Where-Object {
                $_.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Item1.Value -ceq 'Case'
              })
          if ($casePairs.Count -gt 1) {
            $runnerCase = $null
          } elseif ($casePairs.Count -eq 1) {
            $valuePipeline = $casePairs[0].Item2
            $pipelineElements = @($valuePipeline.PipelineElements)
            if ($pipelineElements.Count -eq 1 -and
                $pipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $pipelineElements[0].Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
              $runnerCase = [string]$pipelineElements[0].Expression.Value
            } else {
              $runnerCase = $null
            }
          }
        }
      }
      [void]$gates.Add([pscustomobject]@{
          Label = [string]$elements[1].Value
          DispatchCount = $dispatches.Count
          RelativePath = $relativePath
          RunnerCase = $runnerCase
        })
    }
  }
  return @($gates | ForEach-Object { $_ })
}

function Assert-MathSecrGroundTruthOutputMarker {
  param([string]$EvaluatorPath, [string]$OutputMarker, [string]$Label)

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($EvaluatorPath, [ref]$tokens, [ref]$errors)
  if (@($errors).Count -gt 0) {
    Invoke-MathSecrGroundTruthFailure "$Label evaluator is not valid PowerShell: $($errors[0].Message)"
  }
  foreach ($command in @($ast.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cin @('Write-Host', 'Write-Output')
        }, $true))) {
    foreach ($stringNode in @($command.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
              $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
          }, $true))) {
      if (([string]$stringNode.Value).Contains($OutputMarker)) {
        return
      }
    }
  }
  Invoke-MathSecrGroundTruthFailure "$Label evaluator must emit its truth-scope output marker through Write-Host or Write-Output: $OutputMarker"
}

function Test-MathSecrGroundTruthRegistryDocument {
  param(
    [Parameter(Mandatory = $true)]$Document,
    [Parameter(Mandatory = $true)][string]$ProjectRoot
  )

  $ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
  if ((Get-MathSecrGroundTruthProperty $Document 'schemaVersion' 'registry').Value -ne 1) {
    Invoke-MathSecrGroundTruthFailure 'registry.schemaVersion must be 1.'
  }
  $contract = (Get-MathSecrGroundTruthProperty $Document 'contract' 'registry').Value
  $runnerRelative = Get-MathSecrGroundTruthString $contract 'runner' 'registry.contract'
  if ($runnerRelative -cne 'mathsecr-paper-builder-kit/scripts/run_mathsecr_regression.ps1') {
    Invoke-MathSecrGroundTruthFailure 'registry.contract.runner must point to the full regression runner.'
  }
  $runnerPath = Resolve-MathSecrGroundTruthPath $ProjectRoot $runnerRelative 'registry.contract.runner'
  if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
    Invoke-MathSecrGroundTruthFailure 'registry.contract.runner does not exist.'
  }

  $allowedClasses = @(Get-MathSecrGroundTruthArray $contract 'allowedClaimClasses' 'registry.contract')
  Assert-MathSecrGroundTruthSet $allowedClasses @('external-ground-truth', 'dated-characterization', 'offline-contract') 'registry.contract.allowedClaimClasses'
  $allowedProvenance = @(Get-MathSecrGroundTruthArray $contract 'allowedOracleProvenance' 'registry.contract')
  Assert-MathSecrGroundTruthSet $allowedProvenance @('original-source-bytes', 'source-derived-render', 'captured-live-body', 'raw-live-trace', 'independent-adjudication') 'registry.contract.allowedOracleProvenance'
  $boundary = Get-MathSecrGroundTruthString $contract 'claimBoundary' 'registry.contract'
  if ($boundary -cne 'independence-first; hashes prove identity, not truth; incomplete oracles cannot claim external ground truth') {
    Invoke-MathSecrGroundTruthFailure 'registry.contract.claimBoundary must preserve the independence-first boundary.'
  }
  $externalBodyExactPolicy = Get-MathSecrGroundTruthString $contract 'externalBodyExactPolicy' 'registry.contract'
  if ($externalBodyExactPolicy -cne 'forbidden-until-typed-adjudication-receipt') {
    Invoke-MathSecrGroundTruthFailure 'registry.contract.externalBodyExactPolicy must forbid promotion until a typed adjudication receipt is implemented.'
  }

  $runnerGates = @(Get-MathSecrGroundTruthRunnerGates $runnerPath)
  $claims = @(Get-MathSecrGroundTruthArray $Document 'claims' 'registry')
  if ($claims.Count -lt 7) {
    Invoke-MathSecrGroundTruthFailure "registry.claims must preserve at least seven audited claims; got $($claims.Count)."
  }

  $claimIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
  $summaries = New-Object 'System.Collections.Generic.List[object]'
  foreach ($claim in $claims) {
    $id = Get-MathSecrGroundTruthString $claim 'id' 'claim'
    if (-not $claimIds.Add($id)) {
      Invoke-MathSecrGroundTruthFailure "registry repeats claim id '$id'."
    }
    $label = "claim '$id'"
    $claimClass = Get-MathSecrGroundTruthString $claim 'claimClass' $label
    if ($allowedClasses -cnotcontains $claimClass) {
      Invoke-MathSecrGroundTruthFailure "$label.claimClass is unsupported: $claimClass"
    }
    $relationKind = Get-MathSecrGroundTruthString $claim 'relationKind' $label
    if ($relationKind -ceq 'body-exact' -and $claimClass -ceq 'external-ground-truth') {
      Invoke-MathSecrGroundTruthFailure "$label external body-exact promotion is disabled until a typed adjudication receipt binds exact source/candidate hashes."
    }
    $evaluatorRelative = Get-MathSecrGroundTruthString $claim 'evaluator' $label
    if (-not $evaluatorRelative.StartsWith('mathsecr-paper-builder-kit/scripts/', [System.StringComparison]::Ordinal)) {
      Invoke-MathSecrGroundTruthFailure "$label.evaluator must be under mathsecr-paper-builder-kit/scripts/."
    }
    $evaluatorPath = Resolve-MathSecrGroundTruthPath $ProjectRoot $evaluatorRelative "$label.evaluator"
    if (-not (Test-Path -LiteralPath $evaluatorPath -PathType Leaf)) {
      Invoke-MathSecrGroundTruthFailure "$label.evaluator does not exist: $evaluatorRelative"
    }
    $evaluatorProducerId = Get-MathSecrGroundTruthString $claim 'evaluatorProducerId' $label
    $runnerLabel = Get-MathSecrGroundTruthString $claim 'runnerLabel' $label
    $runnerCase = Get-MathSecrGroundTruthString $claim 'runnerCase' $label
    $runnerMatches = @($runnerGates | Where-Object { $_.Label -ceq $runnerLabel })
    if ($runnerMatches.Count -ne 1) {
      Invoke-MathSecrGroundTruthFailure "$label.runnerLabel must map to exactly one direct full-runner gate; got $($runnerMatches.Count)."
    }
    if ($runnerMatches[0].DispatchCount -ne 1 -or [string]::IsNullOrWhiteSpace([string]$runnerMatches[0].RelativePath)) {
      Invoke-MathSecrGroundTruthFailure "$label.runnerLabel must dispatch exactly one literal Invoke-Script evaluator."
    }
    $normalizedRunnerEvaluator = ([string]$runnerMatches[0].RelativePath).Replace('\', '/')
    if ($normalizedRunnerEvaluator -cne $evaluatorRelative.Replace('\', '/')) {
      Invoke-MathSecrGroundTruthFailure "$label.runnerLabel dispatches '$normalizedRunnerEvaluator', not declared evaluator '$evaluatorRelative'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$runnerMatches[0].RunnerCase) -or $runnerMatches[0].RunnerCase -cne $runnerCase) {
      Invoke-MathSecrGroundTruthFailure "$label.runnerLabel runner case mismatch: expected '$runnerCase', got '$($runnerMatches[0].RunnerCase)'."
    }
    $designArtifacts = @(Get-MathSecrGroundTruthArray $claim 'designArtifacts' $label)
    Assert-MathSecrGroundTruthStringArray $designArtifacts "$label.designArtifacts"
    $designPathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $designArtifacts) {
      $full = Resolve-MathSecrGroundTruthPath $ProjectRoot ([string]$relative) "$label.designArtifacts"
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Invoke-MathSecrGroundTruthFailure "$label design artifact does not exist: $relative"
      }
      [void]$designPathSet.Add($full)
    }

    $requiredSides = @(Get-MathSecrGroundTruthArray $claim 'requiredOracleSides' $label)
    Assert-MathSecrGroundTruthStringArray $requiredSides "$label.requiredOracleSides" -AllowEmpty
    if ($relationKind -ceq 'body-exact') {
      Assert-MathSecrGroundTruthSet $requiredSides @('source-body', 'candidate-body', 'independent-adjudication') "$label.requiredOracleSides"
    }
    $missingSides = @(Get-MathSecrGroundTruthArray $claim 'missingOracleSides' $label)
    Assert-MathSecrGroundTruthStringArray $missingSides "$label.missingOracleSides" -AllowEmpty
    $complete = Get-MathSecrGroundTruthBoolean $claim 'independentOracleComplete' $label
    $oracleArtifacts = @(Get-MathSecrGroundTruthArray $claim 'oracleArtifacts' $label)
    $observedSides = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $bodyPathSides = @{}
    $bodyHashSides = @{}
    $bodyProducerSides = @{}
    foreach ($artifact in $oracleArtifacts) {
      $side = Get-MathSecrGroundTruthString $artifact 'side' "$label.oracleArtifact"
      if ($requiredSides -cnotcontains $side) {
        Invoke-MathSecrGroundTruthFailure "$label oracle artifact uses undeclared side '$side'."
      }
      [void]$observedSides.Add($side)
      $relative = Get-MathSecrGroundTruthString $artifact 'path' "$label.oracleArtifact"
      $full = Resolve-MathSecrGroundTruthPath $ProjectRoot $relative "$label.oracleArtifact.path"
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Invoke-MathSecrGroundTruthFailure "$label oracle artifact does not exist: $relative"
      }
      if ($designPathSet.Contains($full)) {
        Invoke-MathSecrGroundTruthFailure "$label independent oracle cannot reuse a design artifact: $relative"
      }
      if ([string]::Equals($full, $evaluatorPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Invoke-MathSecrGroundTruthFailure "$label evaluator cannot serve as its own oracle."
      }
      $expectedHash = Get-MathSecrGroundTruthString $artifact 'sha256' "$label.oracleArtifact"
      if ($expectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
        Invoke-MathSecrGroundTruthFailure "$label oracle SHA-256 is malformed: $relative"
      }
      $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash
      if ($actualHash -cne $expectedHash.ToUpperInvariant()) {
        Invoke-MathSecrGroundTruthFailure "$label oracle SHA-256 mismatch: $relative"
      }
      $provenance = Get-MathSecrGroundTruthString $artifact 'provenanceType' "$label.oracleArtifact"
      if ($allowedProvenance -cnotcontains $provenance) {
        Invoke-MathSecrGroundTruthFailure "$label oracle provenance is unsupported: $provenance"
      }
      $producerId = Get-MathSecrGroundTruthString $artifact 'producerId' "$label.oracleArtifact"
      $independent = Get-MathSecrGroundTruthBoolean $artifact 'independentOfEvaluator' "$label.oracleArtifact"
      if (-not $independent) {
        Invoke-MathSecrGroundTruthFailure "$label oracle artifact must be independent of the evaluator: $relative"
      }
      if ($producerId -ceq $evaluatorProducerId) {
        Invoke-MathSecrGroundTruthFailure "$label oracle claims independence but shares evaluator producer '$producerId'."
      }
      if ($relationKind -ceq 'body-exact') {
        $allowedSideProvenance = switch ($side) {
          'source-body' { @('original-source-bytes', 'source-derived-render') }
          'candidate-body' { @('captured-live-body') }
          'independent-adjudication' { @('independent-adjudication') }
        }
        if ($allowedSideProvenance -cnotcontains $provenance) {
          Invoke-MathSecrGroundTruthFailure "$label body-exact side '$side' cannot use provenance '$provenance'."
        }
        if ($bodyPathSides.ContainsKey($full) -and $bodyPathSides[$full] -cne $side) {
          Invoke-MathSecrGroundTruthFailure "$label reuses one canonical path across oracle sides '$($bodyPathSides[$full])' and '$side': $relative"
        }
        if ($bodyHashSides.ContainsKey($actualHash) -and $bodyHashSides[$actualHash] -cne $side) {
          Invoke-MathSecrGroundTruthFailure "$label reuses identical bytes across oracle sides '$($bodyHashSides[$actualHash])' and '$side': $relative"
        }
        if ($bodyProducerSides.ContainsKey($producerId) -and $bodyProducerSides[$producerId] -cne $side) {
          Invoke-MathSecrGroundTruthFailure "$label reuses producer '$producerId' across oracle sides '$($bodyProducerSides[$producerId])' and '$side'."
        }
        $bodyPathSides[$full] = $side
        $bodyHashSides[$actualHash] = $side
        $bodyProducerSides[$producerId] = $side
      }
    }

    $observedSideArray = @($observedSides | ForEach-Object { [string]$_ })
    foreach ($side in $missingSides) {
      if ($requiredSides -cnotcontains $side) {
        Invoke-MathSecrGroundTruthFailure "$label missingOracleSides contains undeclared side '$side'."
      }
      if ($observedSides.Contains([string]$side)) {
        Invoke-MathSecrGroundTruthFailure "$label side '$side' cannot be both observed and missing."
      }
    }
    Assert-MathSecrGroundTruthSet @($observedSideArray + $missingSides) $requiredSides "$label oracle side partition"

    if ($claimClass -ceq 'external-ground-truth') {
      if (-not $complete -or $requiredSides.Count -eq 0 -or $missingSides.Count -ne 0) {
        Invoke-MathSecrGroundTruthFailure "$label external-ground-truth requires a complete independent oracle with no missing sides."
      }
    } elseif ($complete) {
      Invoke-MathSecrGroundTruthFailure "$label cannot mark an independent oracle complete while claimClass is '$claimClass'."
    }
    if ($claimClass -ceq 'offline-contract' -and ($requiredSides.Count -ne 0 -or $oracleArtifacts.Count -ne 0 -or $missingSides.Count -ne 0)) {
      Invoke-MathSecrGroundTruthFailure "$label offline-contract must not pretend to own an external oracle."
    }

    $forbidden = @(Get-MathSecrGroundTruthArray $claim 'forbiddenConclusions' $label)
    Assert-MathSecrGroundTruthStringArray $forbidden "$label.forbiddenConclusions"
    $requiredForbidden = if ($claimClass -ceq 'offline-contract') {
      @('external-ground-truth', 'current-live-truth', 'product-behavior')
    } elseif ($claimClass -ceq 'dated-characterization') {
      @('external-ground-truth', 'current-live-truth', 'product-contract')
    } else {
      @('current-live-truth', 'product-contract')
    }
    if ($claimClass -ceq 'external-ground-truth' -and $forbidden -ccontains 'external-ground-truth') {
      Invoke-MathSecrGroundTruthFailure "$label cannot forbid its own external-ground-truth conclusion."
    }
    foreach ($required in $requiredForbidden) {
      if ($forbidden -cnotcontains $required) {
        Invoke-MathSecrGroundTruthFailure "$label.forbiddenConclusions must include '$required'."
      }
    }
    $outputMarker = Get-MathSecrGroundTruthString $claim 'outputMarker' $label
    $requiredOutputPrefix = "truth_scope=$claimClass"
    if (-not $outputMarker.StartsWith($requiredOutputPrefix, [System.StringComparison]::Ordinal)) {
      Invoke-MathSecrGroundTruthFailure "$label.outputMarker must start with '$requiredOutputPrefix'."
    }
    Assert-MathSecrGroundTruthOutputMarker $evaluatorPath $outputMarker $label

    [void]$summaries.Add([pscustomobject]@{
        Id = $id
        ClaimClass = $claimClass
        RelationKind = $relationKind
        IndependentOracleComplete = $complete
        MissingOracleSides = @($missingSides)
      })
  }

  $requiredSeeds = [ordered]@{
    'body-exact-corpus-scoring' = @('dated-characterization', 'body-exact', 'candidate-body', 'independent-adjudication')
    'search-phrase-stability' = @('dated-characterization', 'dated-search-observation', 'raw-live-trace')
    'idle-search-stability' = @('dated-characterization', 'dated-idle-observation', 'raw-live-trace')
    'db-inference-policy' = @('offline-contract', 'policy-contract')
    'pdf-segmentation-labels' = @('dated-characterization', 'segmentation-labels', 'independent-adjudication')
    'source-anomaly-receipt-shape' = @('offline-contract', 'source-anomaly-receipt-shape')
    'regression-evidence-current-bytes' = @('offline-contract', 'regression-current-input-attestation')
  }
  foreach ($seedId in $requiredSeeds.Keys) {
    $matches = @($summaries | Where-Object { $_.Id -ceq $seedId })
    if ($matches.Count -ne 1) {
      Invoke-MathSecrGroundTruthFailure "required audited claim '$seedId' is missing."
    }
    $expected = $requiredSeeds[$seedId]
    if ($matches[0].ClaimClass -cne $expected[0] -or $matches[0].RelationKind -cne $expected[1]) {
      Invoke-MathSecrGroundTruthFailure "required audited claim '$seedId' changed its claim boundary."
    }
    foreach ($missingSide in @($expected | Select-Object -Skip 2)) {
      if ($matches[0].MissingOracleSides -cnotcontains $missingSide) {
        Invoke-MathSecrGroundTruthFailure "required audited claim '$seedId' must retain missing oracle side '$missingSide'."
      }
    }
  }

  return [pscustomobject]@{
    Claims = @($summaries | ForEach-Object { $_ })
    ClaimCount = $summaries.Count
    ExternalCount = @($summaries | Where-Object ClaimClass -ceq 'external-ground-truth').Count
    CharacterizationCount = @($summaries | Where-Object ClaimClass -ceq 'dated-characterization').Count
    ContractCount = @($summaries | Where-Object ClaimClass -ceq 'offline-contract').Count
    CompleteOracleCount = @($summaries | Where-Object IndependentOracleComplete).Count
  }
}

function Test-MathSecrGroundTruthRegistry {
  param(
    [Parameter(Mandatory = $true)][string]$RegistryPath,
    [Parameter(Mandatory = $true)][string]$ProjectRoot
  )

  if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
    Invoke-MathSecrGroundTruthFailure "registry file does not exist: $RegistryPath"
  }
  try {
    $document = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Invoke-MathSecrGroundTruthFailure "registry is not valid JSON: $($_.Exception.Message)"
  }
  return Test-MathSecrGroundTruthRegistryDocument -Document $document -ProjectRoot $ProjectRoot
}
