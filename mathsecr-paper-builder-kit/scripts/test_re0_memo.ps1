param(
  [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [ValidateSet("All", "ValidRegistry")]
  [string]$Case = "All"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

function Fail {
  param([string]$Message)
  throw "re0-memo: $Message"
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    Fail $Message
  }
}

function Copy-Value {
  param($Value)
  return ($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json)
}

function Get-RequiredProperty {
  param($Object, [string]$Name, [string]$Label)
  if ($null -eq $Object) {
    Fail "$Label is missing because its parent is null."
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    Fail "$Label is missing property '$Name'."
  }
  # Return the property wrapper, not its value. PowerShell 5.1 enumerates an
  # array returned from a function, which otherwise turns a singleton array
  # into a scalar before the caller can validate its JSON shape.
  return $property
}

function Get-RequiredString {
  param($Object, [string]$Name, [string]$Label)
  $value = (Get-RequiredProperty $Object $Name $Label).Value
  if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
    Fail "$Label.$Name must be a non-empty string."
  }
  return [string]$value
}

function Get-RequiredArray {
  param($Object, [string]$Name, [string]$Label)
  $value = (Get-RequiredProperty $Object $Name $Label).Value
  if (-not ($value -is [System.Array])) {
    Fail "$Label.$Name must be an array."
  }
  return $value
}

function Resolve-ProjectRelativePath {
  param([string]$RelativePath, [string]$Purpose)

  if ([string]::IsNullOrWhiteSpace($RelativePath)) {
    Fail "$Purpose must be a non-empty ProjectRoot-relative path."
  }
  $normalized = $RelativePath.Replace('/', '\')
  if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized -match '^[A-Za-z]:') {
    Fail "$Purpose must be ProjectRoot-relative, not rooted: $RelativePath"
  }
  $segments = @($normalized -split '\\+' | Where-Object { $_ -ne '' })
  foreach ($segment in $segments) {
    if ($segment -ceq '.' -or $segment -ceq '..') {
      Fail "$Purpose contains a traversal segment: $RelativePath"
    }
  }
  try {
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path -Path $ProjectRoot -ChildPath $normalized))
  } catch {
    Fail "$Purpose is not a valid relative path: $RelativePath"
  }
  $rootPrefix = $ProjectRoot.TrimEnd('\') + '\'
  if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "$Purpose resolves outside ProjectRoot: $RelativePath"
  }
  return $fullPath
}

function Assert-RelativeUnder {
  param([string]$RelativePath, [string]$Prefix, [string]$Label)
  if (-not $RelativePath.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
    Fail "$Label must be under '$Prefix': $RelativePath"
  }
}

function Assert-NonEmptyStringArray {
  param([object[]]$Values, [string]$Label, [int]$Minimum = 1)
  if ($Values.Count -lt $Minimum) {
    Fail "$Label requires at least $Minimum item(s)."
  }
  foreach ($value in $Values) {
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
      Fail "$Label must contain only non-empty strings."
    }
  }
}

function Assert-ExactStringSet {
  param([object[]]$Values, [string[]]$Expected, [string]$Label)

  $actual = @($Values | Sort-Object -CaseSensitive -Unique)
  $wanted = @($Expected | Sort-Object -CaseSensitive -Unique)
  if ($actual.Count -ne $wanted.Count) {
    Fail "$Label must be the exact set [$($wanted -join ', ')]."
  }
  for ($index = 0; $index -lt $wanted.Count; $index++) {
    if ([string]$actual[$index] -cne [string]$wanted[$index]) {
      Fail "$Label must be the exact set [$($wanted -join ', ')]."
    }
  }
}

function Read-PowerShellAst {
  param([string]$Path, [string]$Label)

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if (@($errors).Count -gt 0) {
    Fail "$Label is not valid PowerShell: $($errors[0].Message)"
  }
  return $ast
}

function Read-PowerShellTextAst {
  param([string]$Text, [string]$Label)

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
  if (@($errors).Count -gt 0) {
    Fail "$Label is not valid PowerShell: $($errors[0].Message)"
  }
  return $ast
}

function Test-HasFunctionAncestor {
  param([System.Management.Automation.Language.Ast]$Node)

  $current = $Node.Parent
  while ($null -ne $current) {
    if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
      return $true
    }
    $current = $current.Parent
  }
  return $false
}

function Assert-ExecutableTestAnchor {
  param(
    [System.Management.Automation.Language.ScriptBlockAst]$TestAst,
    [string]$Anchor,
    [string]$Label
  )

  $matches = @($TestAst.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
          return $false
        }
        $commandName = $node.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName) -or
            ($commandName -cne 'Expect-Rejection' -and -not $commandName.StartsWith('Assert-', [System.StringComparison]::Ordinal))) {
          return $false
        }
        return $node.Extent.Text.Contains($Anchor)
      }, $true) | Where-Object { -not (Test-HasFunctionAncestor $_) })
  if ($matches.Count -lt 1) {
    Fail "$Label must appear in an executable top-level assertion command."
  }
}

function Assert-DirectRunnerGate {
  param(
    [System.Management.Automation.Language.ScriptBlockAst]$RunnerAst,
    [string]$RunnerLabel,
    [string]$TestScript,
    [string]$TestCase,
    [string]$Label
  )

  $normalizedTestScript = $TestScript.Replace('\', '/')
  $matchingCommands = New-Object 'System.Collections.Generic.List[object]'
  $runnerCommands = @($RunnerAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-Logged'
      }, $true))
  foreach ($runnerCommand in $runnerCommands) {
    if (Test-HasFunctionAncestor $runnerCommand) {
      continue
    }
    $pipeline = $runnerCommand.Parent
    if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or
        $pipeline.Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -or
        $pipeline.Parent.Parent -isnot [System.Management.Automation.Language.TryStatementAst]) {
      continue
    }
    $labelElements = @($runnerCommand.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -ceq $RunnerLabel
      })
    if ($labelElements.Count -ne 1) {
      continue
    }
    $invokeScripts = @($runnerCommand.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-Script'
        }, $true))
    foreach ($invokeScript in $invokeScripts) {
      $invokePipeline = $invokeScript.Parent
      $invokeNamedBlock = if ($null -ne $invokePipeline) { $invokePipeline.Parent } else { $null }
      $invokeScriptBlock = if ($null -ne $invokeNamedBlock) { $invokeNamedBlock.Parent } else { $null }
      $invokeScriptBlockExpression = if ($null -ne $invokeScriptBlock) { $invokeScriptBlock.Parent } else { $null }
      if ($invokePipeline -isnot [System.Management.Automation.Language.PipelineAst] -or
          $invokeNamedBlock -isnot [System.Management.Automation.Language.NamedBlockAst] -or
          $invokeScriptBlock -isnot [System.Management.Automation.Language.ScriptBlockAst] -or
          $invokeScriptBlockExpression -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
          -not [object]::ReferenceEquals($invokeScriptBlockExpression.Parent, $runnerCommand)) {
        continue
      }
      $invokeStatements = @($invokeNamedBlock.Statements)
      if ($invokeStatements.Count -ne 1 -or
          -not [object]::ReferenceEquals($invokeStatements[0], $invokePipeline)) {
        continue
      }

      $relativePathArguments = New-Object 'System.Collections.Generic.List[object]'
      $parameterHashtables = New-Object 'System.Collections.Generic.List[object]'
      $commandElements = @($invokeScript.CommandElements)
      for ($elementIndex = 0; $elementIndex -lt ($commandElements.Count - 1); $elementIndex++) {
        $element = $commandElements[$elementIndex]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
          continue
        }
        if ($element.ParameterName -ieq 'RelativePath' -and
            $commandElements[$elementIndex + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
          [void]$relativePathArguments.Add($commandElements[$elementIndex + 1])
        }
        if ($element.ParameterName -ieq 'Parameters' -and
            $commandElements[$elementIndex + 1] -is [System.Management.Automation.Language.HashtableAst]) {
          [void]$parameterHashtables.Add($commandElements[$elementIndex + 1])
        }
      }
      if ($relativePathArguments.Count -ne 1 -or $parameterHashtables.Count -ne 1 -or
          $relativePathArguments[0].Value.Replace('\', '/') -cne $normalizedTestScript) {
        continue
      }

      $parameterHashtable = $parameterHashtables[0]
      $casePairs = @($parameterHashtable.KeyValuePairs | Where-Object {
          $_.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $_.Item1.Value -ieq 'Case'
        })
      $reportPathPairs = @($parameterHashtable.KeyValuePairs | Where-Object {
          $_.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $_.Item1.Value -ieq 'ReportPath'
        })
      if ($casePairs.Count -ne 1 -or $reportPathPairs.Count -ne 0) {
        continue
      }
      $caseValue = $casePairs[0].Item2
      $casePipeline = $null
      if ($caseValue -is [System.Management.Automation.Language.PipelineAst]) {
        $casePipeline = $caseValue
      } elseif ($caseValue -is [System.Management.Automation.Language.StatementBlockAst] -and
                @($caseValue.Statements).Count -eq 1 -and
                $caseValue.Statements[0] -is [System.Management.Automation.Language.PipelineAst]) {
        $casePipeline = $caseValue.Statements[0]
      }
      if ($null -ne $casePipeline -and
          $casePipeline.PipelineElements.Count -eq 1 -and
          $casePipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
          $casePipeline.PipelineElements[0].Expression -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
          $casePipeline.PipelineElements[0].Expression.Value -ceq $TestCase) {
        [void]$matchingCommands.Add($runnerCommand)
      }
    }
  }
  if ($matchingCommands.Count -ne 1) {
    Fail "$Label must map to exactly one direct top-level runner gate; got $($matchingCommands.Count)."
  }
}

function Get-SwitchCaseBlockAst {
  param(
    [System.Management.Automation.Language.ScriptBlockAst]$ScriptAst,
    [string]$CaseName,
    [string]$Label
  )

  $blocks = New-Object 'System.Collections.Generic.List[object]'
  $switches = @($ScriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] }, $true))
  foreach ($switch in $switches) {
    foreach ($clause in @($switch.Clauses)) {
      if ($clause.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
          $clause.Item1.Value -ceq $CaseName) {
        [void]$blocks.Add($clause.Item2)
      }
    }
  }
  if ($blocks.Count -ne 1) {
    Fail "$Label must resolve to exactly one executable switch case; got $($blocks.Count)."
  }
  return $blocks[0]
}

function Assert-NegativeFixtureCase {
  param($CaseNode, [string]$Label)

  $expectProperty = $CaseNode.PSObject.Properties['expect']
  if ($null -eq $expectProperty -or $null -eq $expectProperty.Value) {
    Fail "$Label must contain an expect object that encodes a negative outcome."
  }
  $expect = $expectProperty.Value
  $isNegative = $false
  $claimsValidProperty = $expect.PSObject.Properties['claimsValid']
  if ($null -ne $claimsValidProperty -and
      $claimsValidProperty.Value -is [bool] -and
      $claimsValidProperty.Value -eq $false) {
    $isNegative = $true
  }
  $statusProperty = $expect.PSObject.Properties['status']
  if ($null -ne $statusProperty -and
      $statusProperty.Value -is [string] -and
      $statusProperty.Value -match '(?i)(pending|invalid|blocked|rejected|failure|error|차단)') {
    $isNegative = $true
  }
  if (-not $isNegative) {
    Fail "$Label must encode a negative outcome, not a successful or positive control."
  }
}

function Assert-ExecutableFixtureLoad {
  param(
    [System.Management.Automation.Language.ScriptBlockAst]$ScriptAst,
    [string]$FixturePath,
    [string]$Label
  )

  $normalizedFixturePath = [regex]::Replace($FixturePath.Replace('\', '/'), '/+', '/')
  $pathVariables = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $assignments = @($ScriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
  foreach ($assignment in $assignments) {
    if ($assignment.Parent -isnot [System.Management.Automation.Language.NamedBlockAst] -or
        $assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
      continue
    }
    $pathLiterals = @($assignment.Right.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | Where-Object {
          [regex]::Replace($_.Value.Replace('\', '/'), '/+', '/') -ceq $normalizedFixturePath
        })
    if ($pathLiterals.Count -gt 0) {
      [void]$pathVariables.Add($assignment.Left.VariablePath.UserPath)
    }
  }

  if ($pathVariables.Count -lt 1) {
    Fail "$Label fixture path must be assigned by a direct executable statement."
  }

  $readCommands = @($ScriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-Content'
      }, $true))
  foreach ($readCommand in $readCommands) {
    $enclosingAssignment = $readCommand.Parent
    while ($null -ne $enclosingAssignment -and
           $enclosingAssignment -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
      $enclosingAssignment = $enclosingAssignment.Parent
    }
    if ($null -eq $enclosingAssignment -or
        $enclosingAssignment.Parent -isnot [System.Management.Automation.Language.NamedBlockAst]) {
      continue
    }
    $variables = @($readCommand.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
    foreach ($variable in $variables) {
      if ($pathVariables.Contains($variable.VariablePath.UserPath)) {
        return
      }
    }
  }
  Fail "$Label fixture path must flow into a direct executable Get-Content command."
}

function Assert-CaseIncludedInAllDispatch {
  param(
    [System.Management.Automation.Language.ScriptBlockAst]$ScriptAst,
    [string]$CaseName,
    [string]$Label
  )

  $matchingSwitches = New-Object 'System.Collections.Generic.List[object]'
  $switches = @($ScriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.SwitchStatementAst]
      }, $true))
  foreach ($switch in $switches) {
    $matchingClauses = @($switch.Clauses | Where-Object {
        $_.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
          $_.Item1.Value -ceq $CaseName
      })
    if ($matchingClauses.Count -gt 0 -and -not (Test-HasFunctionAncestor $switch)) {
      [void]$matchingSwitches.Add($switch)
    }
  }
  if ($matchingSwitches.Count -ne 1) {
    Fail "$Label must resolve to exactly one top-level switch dispatch; got $($matchingSwitches.Count)."
  }

  $caseSwitch = $matchingSwitches[0]
  if ($caseSwitch.Condition -isnot [System.Management.Automation.Language.PipelineAst] -or
      $caseSwitch.Condition.PipelineElements.Count -ne 1 -or
      $caseSwitch.Condition.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
      $caseSwitch.Condition.PipelineElements[0].Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
    Fail "$Label switch must dispatch a single loop variable."
  }
  $dispatchVariable = $caseSwitch.Condition.PipelineElements[0].Expression.VariablePath.UserPath
  if ($caseSwitch.Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -or
      $caseSwitch.Parent.Parent -isnot [System.Management.Automation.Language.ForEachStatementAst]) {
    Fail "$Label switch must be the executable body of a foreach dispatch."
  }

  $switchStatements = @($caseSwitch.Parent.Statements)
  if ($switchStatements.Count -lt 1 -or
      -not [object]::ReferenceEquals($switchStatements[0], $caseSwitch)) {
    Fail "$Label switch must be the first executable statement in its foreach dispatch body."
  }

  $dispatchLoop = $caseSwitch.Parent.Parent
  if ($dispatchLoop.Variable -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
      -not [string]::Equals($dispatchLoop.Variable.VariablePath.UserPath, $dispatchVariable, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "$Label switch variable must match its foreach dispatch variable."
  }
  if ($dispatchLoop.Condition -isnot [System.Management.Automation.Language.PipelineAst] -or
      $dispatchLoop.Condition.PipelineElements.Count -ne 1 -or
      $dispatchLoop.Condition.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
      $dispatchLoop.Condition.PipelineElements[0].Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
    Fail "$Label foreach must enumerate a single case-list variable."
  }
  $caseListVariable = $dispatchLoop.Condition.PipelineElements[0].Expression.VariablePath.UserPath

  $caseListAssignments = @($ScriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
          $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
          [string]::Equals($node.Left.VariablePath.UserPath, $caseListVariable, [System.StringComparison]::OrdinalIgnoreCase) -and
          $node.Parent -is [System.Management.Automation.Language.NamedBlockAst]
      }, $true) | Where-Object { -not (Test-HasFunctionAncestor $_) })
  if ($caseListAssignments.Count -ne 1) {
    Fail "$Label must have exactly one top-level assignment for dispatch list '$caseListVariable'; got $($caseListAssignments.Count)."
  }

  $caseListAssignment = $caseListAssignments[0]
  if ($caseListAssignment.Extent.StartOffset -ge $dispatchLoop.Extent.StartOffset -or
      $caseListAssignment.Right -isnot [System.Management.Automation.Language.IfStatementAst]) {
    Fail "$Label must remain in the executable All-case dispatch list."
  }

  $dispatchBlock = $dispatchLoop.Parent
  $dispatchTry = $dispatchBlock.Parent
  if ($dispatchBlock -isnot [System.Management.Automation.Language.StatementBlockAst] -or
      $dispatchTry -isnot [System.Management.Automation.Language.TryStatementAst] -or
      -not [object]::ReferenceEquals($dispatchTry.Parent, $ScriptAst.EndBlock)) {
    Fail "$Label foreach must be on the direct root executable dispatch path."
  }
  $dispatchStatements = @($dispatchBlock.Statements)
  if ($dispatchStatements.Count -lt 1 -or
      -not [object]::ReferenceEquals($dispatchStatements[0], $dispatchLoop)) {
    Fail "$Label foreach must be the first executable statement in the root dispatch try block."
  }
  if (-not [object]::ReferenceEquals($caseListAssignment.Parent, $ScriptAst.EndBlock)) {
    Fail "$Label case-list assignment must be on the direct root executable dispatch path."
  }
  $rootStatements = @($ScriptAst.EndBlock.Statements)
  $assignmentIndex = -1
  $dispatchTryIndex = -1
  for ($statementIndex = 0; $statementIndex -lt $rootStatements.Count; $statementIndex++) {
    if ([object]::ReferenceEquals($rootStatements[$statementIndex], $caseListAssignment)) {
      $assignmentIndex = $statementIndex
    }
    if ([object]::ReferenceEquals($rootStatements[$statementIndex], $dispatchTry)) {
      $dispatchTryIndex = $statementIndex
    }
  }
  if ($assignmentIndex -lt 0 -or $dispatchTryIndex -ne ($assignmentIndex + 1)) {
    Fail "$Label case-list assignment and executable dispatch must be adjacent root statements."
  }

  foreach ($protectedInputName in @('Case', 'ReportPath')) {
    $protectedInputWrites = @($ScriptAst.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            [string]::Equals($node.Left.VariablePath.UserPath, $protectedInputName, [System.StringComparison]::OrdinalIgnoreCase) -and
            $node.Extent.StartOffset -lt $caseListAssignment.Extent.StartOffset
        }, $true) | Where-Object { -not (Test-HasFunctionAncestor $_) })
    if ($protectedInputWrites.Count -ne 0) {
      Fail "$Label must not overwrite runner input variable '$protectedInputName' before All dispatch; got $($protectedInputWrites.Count) write(s)."
    }
  }

  $preDispatchTerminals = @($ScriptAst.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.ReturnStatementAst] -or
          $node -is [System.Management.Automation.Language.ExitStatementAst]) -and
          $node.Extent.StartOffset -lt $caseListAssignment.Extent.StartOffset
      }, $true) | Where-Object { -not (Test-HasFunctionAncestor $_) })
  if ($preDispatchTerminals.Count -gt 0) {
    $reportPathParameters = @($ScriptAst.ParamBlock.Parameters | Where-Object {
        $_.Name -is [System.Management.Automation.Language.VariableExpressionAst] -and
          [string]::Equals($_.Name.VariablePath.UserPath, 'ReportPath', [System.StringComparison]::OrdinalIgnoreCase)
      })
    if ($reportPathParameters.Count -ne 1) {
      Fail "$Label pre-dispatch return/exit requires exactly one ReportPath parameter."
    }
    $reportPathDefault = $reportPathParameters[0].DefaultValue
    if ($null -ne $reportPathDefault -and
        ($reportPathDefault -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
          $reportPathDefault.Value -cne '')) {
      Fail "$Label ReportPath parameter default must be absent or a static empty string."
    }
  }
  foreach ($terminal in $preDispatchTerminals) {
    $rootStatement = $terminal
    while ($null -ne $rootStatement.Parent -and
           -not [object]::ReferenceEquals($rootStatement.Parent, $ScriptAst.EndBlock)) {
      $rootStatement = $rootStatement.Parent
    }

    $isSafeReportPathExit = $false
    if ($null -ne $rootStatement.Parent -and
        $rootStatement -is [System.Management.Automation.Language.IfStatementAst]) {
      foreach ($clause in @($rootStatement.Clauses)) {
        $condition = $clause.Item1
        $isReportPathCondition = $condition -is [System.Management.Automation.Language.PipelineAst] -and
          $condition.PipelineElements.Count -eq 1 -and
          $condition.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
          $condition.PipelineElements[0].Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
          [string]::Equals($condition.PipelineElements[0].Expression.VariablePath.UserPath, 'ReportPath', [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $isReportPathCondition) {
          continue
        }

        $ancestor = $terminal
        while ($null -ne $ancestor -and -not [object]::ReferenceEquals($ancestor, $clause.Item2)) {
          $ancestor = $ancestor.Parent
        }
        if ($null -ne $ancestor) {
          $isSafeReportPathExit = $true
          break
        }
      }
    }
    if (-not $isSafeReportPathExit) {
      Fail "$Label contains an unsupported pre-dispatch return/exit path."
    }
  }

  $allCaseBodies = New-Object 'System.Collections.Generic.List[object]'
  foreach ($clause in @($caseListAssignment.Right.Clauses)) {
    $condition = $clause.Item1
    if ($condition -isnot [System.Management.Automation.Language.PipelineAst] -or
        $condition.PipelineElements.Count -ne 1 -or
        $condition.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
        $condition.PipelineElements[0].Expression -isnot [System.Management.Automation.Language.BinaryExpressionAst]) {
      continue
    }
    $binary = $condition.PipelineElements[0].Expression
    if (@('Ieq', 'Ceq') -cnotcontains [string]$binary.Operator) {
      continue
    }
    $leftIsCase = $binary.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
      [string]::Equals($binary.Left.VariablePath.UserPath, 'Case', [System.StringComparison]::OrdinalIgnoreCase)
    $rightIsCase = $binary.Right -is [System.Management.Automation.Language.VariableExpressionAst] -and
      [string]::Equals($binary.Right.VariablePath.UserPath, 'Case', [System.StringComparison]::OrdinalIgnoreCase)
    $leftIsAll = $binary.Left -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $binary.Left.Value -ceq 'All'
    $rightIsAll = $binary.Right -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $binary.Right.Value -ceq 'All'
    if (($leftIsCase -and $rightIsAll) -or ($leftIsAll -and $rightIsCase)) {
      [void]$allCaseBodies.Add($clause.Item2)
    }
  }
  if ($allCaseBodies.Count -ne 1) {
    Fail "$Label must have exactly one executable All branch; got $($allCaseBodies.Count)."
  }

  $allCaseBody = $allCaseBodies[0]
  $allCaseTrapCount = if ($null -eq $allCaseBody.Traps) { 0 } else { @($allCaseBody.Traps).Count }
  $allCaseStatements = @($allCaseBody.Statements)
  if ($allCaseTrapCount -ne 0 -or $allCaseStatements.Count -ne 1 -or
      $allCaseStatements[0] -isnot [System.Management.Automation.Language.PipelineAst]) {
    Fail "$Label executable All branch must be one direct case-list output."
  }
  $outerPipeline = $allCaseStatements[0]
  if ($outerPipeline.PipelineElements.Count -ne 1 -or
      $outerPipeline.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
      $outerPipeline.PipelineElements[0].Expression -isnot [System.Management.Automation.Language.ArrayExpressionAst]) {
    $elementType = if ($outerPipeline.PipelineElements.Count -eq 1) { $outerPipeline.PipelineElements[0].GetType().Name } else { 'n/a' }
    $expressionType = if ($outerPipeline.PipelineElements.Count -eq 1 -and $null -ne $outerPipeline.PipelineElements[0].Expression) {
      $outerPipeline.PipelineElements[0].Expression.GetType().Name
    } else {
      'n/a'
    }
    Fail "$Label executable All branch must emit one static array; elements=$($outerPipeline.PipelineElements.Count) elementType=$elementType expressionType=$expressionType."
  }
  $arrayBody = $outerPipeline.PipelineElements[0].Expression.SubExpression
  $arrayTrapCount = if ($null -eq $arrayBody.Traps) { 0 } else { @($arrayBody.Traps).Count }
  $arrayStatements = @($arrayBody.Statements)
  if ($arrayTrapCount -ne 0 -or $arrayStatements.Count -ne 1 -or
      $arrayStatements[0] -isnot [System.Management.Automation.Language.PipelineAst]) {
    Fail "$Label executable All branch must emit one static array."
  }
  $innerPipeline = $arrayStatements[0]
  if ($innerPipeline.PipelineElements.Count -ne 1 -or
      $innerPipeline.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
      $innerPipeline.PipelineElements[0].Expression -isnot [System.Management.Automation.Language.ArrayLiteralAst]) {
    Fail "$Label executable All branch must emit one static array."
  }
  $arrayElements = @($innerPipeline.PipelineElements[0].Expression.Elements)
  if (@($arrayElements | Where-Object { $_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst] }).Count -ne 0) {
    Fail "$Label executable All branch must contain only direct string literals."
  }
  $matchingCaseLiterals = @($arrayElements | Where-Object { $_.Value -ceq $CaseName })
  if ($matchingCaseLiterals.Count -ne 1) {
    Fail "$Label case '$CaseName' must occur exactly once in the executable All-case dispatch list; got $($matchingCaseLiterals.Count)."
  }
}

function Find-CaseNodes {
  param($Node, [string]$CaseName)

  $matches = New-Object 'System.Collections.Generic.List[object]'
  if ($null -eq $Node) {
    return @($matches.ToArray())
  }
  if ($Node -is [System.Array]) {
    foreach ($item in @($Node)) {
      foreach ($match in @(Find-CaseNodes $item $CaseName)) {
        [void]$matches.Add($match)
      }
    }
    return @($matches.ToArray())
  }
  if ($Node -is [string]) {
    return @($matches.ToArray())
  }

  $nameProperty = $Node.PSObject.Properties['name']
  if ($null -ne $nameProperty -and [string]$nameProperty.Value -ceq $CaseName) {
    [void]$matches.Add($Node)
  }
  foreach ($property in @($Node.PSObject.Properties)) {
    foreach ($match in @(Find-CaseNodes $property.Value $CaseName)) {
      [void]$matches.Add($match)
    }
  }
  return @($matches.ToArray())
}

function Assert-Contains {
  param([string]$Text, [string]$Needle, [string]$Label)
  if (-not $Text.Contains($Needle)) {
    Fail "$Label does not contain '$Needle'."
  }
}

function Test-NegativeCorpusItem {
  param(
    $Item,
    [string]$Label,
    [string]$GateTestScript,
    [string]$GateTestCase,
    [System.Management.Automation.Language.ScriptBlockAst]$GateTestScriptAst
  )

  $kind = Get-RequiredString $Item 'kind' $Label
  if (@('fixture-case', 'script-case') -cnotcontains $kind) {
    Fail "$Label.kind must be fixture-case or script-case."
  }
  $caseName = Get-RequiredString $Item 'case' $Label
  $expectedContains = Get-RequiredString $Item 'expectedContains' $Label

  if ($kind -ceq 'fixture-case') {
    $fixturePath = Get-RequiredString $Item 'fixture' $Label
    Assert-RelativeUnder $fixturePath 'mathsecr-paper-builder-kit/test-fixtures/' "$Label.fixture"
    $fixtureFullPath = Resolve-ProjectRelativePath $fixturePath "$Label.fixture"
    if (-not (Test-Path -LiteralPath $fixtureFullPath -PathType Leaf)) {
      Fail "$Label.fixture does not exist: $fixturePath"
    }
    try {
      $fixture = Get-Content -LiteralPath $fixtureFullPath -Raw | ConvertFrom-Json
    } catch {
      Fail "$Label.fixture is not valid JSON: $fixturePath"
    }
    $caseNodes = @(Find-CaseNodes $fixture $caseName)
    if ($caseNodes.Count -ne 1) {
      Fail "$Label fixture case '$caseName' must resolve to exactly one node; got $($caseNodes.Count)."
    }
    Assert-NegativeFixtureCase $caseNodes[0] "$Label fixture case '$caseName'"
    $serializedCase = $caseNodes[0] | ConvertTo-Json -Depth 100 -Compress
    Assert-Contains $serializedCase $expectedContains "$Label fixture case '$caseName'"

    if ($GateTestCase -cne 'All' -and $GateTestCase -cne $caseName) {
      Fail "$Label fixture case '$caseName' is not executed by qualityGate testCase '$GateTestCase'."
    }
    Assert-ExecutableFixtureLoad $GateTestScriptAst $fixturePath "$Label qualityGate.testScript"
  } else {
    $scriptPath = Get-RequiredString $Item 'script' $Label
    Assert-RelativeUnder $scriptPath 'mathsecr-paper-builder-kit/scripts/' "$Label.script"
    $scriptFullPath = Resolve-ProjectRelativePath $scriptPath "$Label.script"
    if (-not (Test-Path -LiteralPath $scriptFullPath -PathType Leaf)) {
      Fail "$Label.script does not exist: $scriptPath"
    }
    if ($scriptPath -cne $GateTestScript) {
      Fail "$Label.script must match qualityGate.testScript '$GateTestScript'."
    }
    if ($GateTestCase -cne 'All' -and $GateTestCase -cne $caseName) {
      Fail "$Label script case '$caseName' is not executed by qualityGate testCase '$GateTestCase'."
    }
    $caseBlock = Get-SwitchCaseBlockAst $GateTestScriptAst $caseName "$Label script case"
    $matchingRejectionAssertions = @($caseBlock.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Expect-Rejection' -and
            $node.Extent.Text.Contains($expectedContains)
        }, $true) | Where-Object {
          $_.Parent -is [System.Management.Automation.Language.PipelineAst] -and
            [object]::ReferenceEquals($_.Parent.Parent, $caseBlock)
        })
    if ($matchingRejectionAssertions.Count -lt 1) {
      Fail "$Label script case '$caseName' must contain a direct executable rejection assertion for '$expectedContains'."
    }
    if ($GateTestCase -ceq 'All') {
      Assert-CaseIncludedInAllDispatch $GateTestScriptAst $caseName "$Label script case"
    }
  }
}

function Test-Registry {
  param(
    $Registry,
    [System.Management.Automation.Language.ScriptBlockAst]$RunnerAst
  )

  $schemaVersion = (Get-RequiredProperty $Registry 'schemaVersion' 'registry').Value
  if ([int]$schemaVersion -ne 1) {
    Fail "registry.schemaVersion must be 1."
  }
  $contract = (Get-RequiredProperty $Registry 'contract' 'registry').Value
  $runnerRelativePath = Get-RequiredString $contract 'runner' 'registry.contract'
  if ($runnerRelativePath -cne 'mathsecr-paper-builder-kit/scripts/run_mathsecr_regression.ps1') {
    Fail "registry.contract.runner must point to the full regression runner."
  }
  $runnerFullPath = Resolve-ProjectRelativePath $runnerRelativePath 'registry.contract.runner'
  if (-not (Test-Path -LiteralPath $runnerFullPath -PathType Leaf)) {
    Fail "registry.contract.runner does not exist."
  }
  $allowedStatuses = @(Get-RequiredArray $contract 'allowedStatuses' 'registry.contract')
  Assert-NonEmptyStringArray $allowedStatuses 'registry.contract.allowedStatuses' 2
  Assert-ExactStringSet $allowedStatuses @('gated', 'record-only') 'registry.contract.allowedStatuses'
  $highImpactStatuses = @(Get-RequiredArray $contract 'highImpactStatuses' 'registry.contract')
  Assert-NonEmptyStringArray $highImpactStatuses 'registry.contract.highImpactStatuses' 2
  Assert-ExactStringSet $highImpactStatuses @('high', 'repeated') 'registry.contract.highImpactStatuses'
  $claimBoundary = Get-RequiredString $contract 'claimBoundary' 'registry.contract'
  if ($claimBoundary -cne 'linkage-only; underlying tests prove outcomes; no live truth') {
    Fail 'registry.contract.claimBoundary must state the linkage-only/no-live-truth boundary.'
  }

  $lessons = @(Get-RequiredArray $Registry 'lessons' 'registry')
  if ($lessons.Count -lt 5) {
    Fail "registry.lessons must preserve at least 5 seed lessons; got $($lessons.Count)."
  }
  # These incident seeds keep their earned classification and gate ownership.
  # New schema-valid lessons may still be appended without changing this list.
  $requiredSeedContracts = @(
    [pscustomobject]@{
      Id = 'semantic-and-recall-collapse'
      Category = 'Search'
      Impact = 'high'
      Status = 'gated'
      TestScript = 'mathsecr-paper-builder-kit/scripts/test_search_attempt_contract.ps1'
      TestCase = 'All'
      RunnerLabel = 'Search Attempt Provenance Contract All'
      Evidence = @(
        '.omo/evidence/mathsecr_semantic_and_false_negative_2026-08-26.md',
        '.omo/evidence/mathsecr_metadata_rescue_gap_2026-08-15.md'
      )
      Corpus = @(
        [pscustomobject]@{
          Kind = 'fixture-case'
          LocationField = 'fixture'
          Location = 'mathsecr-paper-builder-kit/test-fixtures/search-attempts/goguk2-mid-q2.json'
          Case = 'bad-common-semantic-and'
          ExpectedContains = 'semantic-inference'
        }
      )
    },
    [pscustomobject]@{
      Id = 'receipt-binding-self-attestation'
      Category = 'Failure'
      Impact = 'high'
      Status = 'gated'
      TestScript = 'mathsecr-paper-builder-kit/scripts/test_report_lint.ps1'
      TestCase = 'All'
      RunnerLabel = 'Session Report Linter All'
      Evidence = @(
        '.omo/evidence/mathsecr_report_receipt_binding_2026-08-26.md',
        '.omo/evidence/mathsecr_semantic_and_false_negative_2026-08-26.md'
      )
      Corpus = @(
        [pscustomobject]@{
          Kind = 'script-case'
          LocationField = 'script'
          Location = 'mathsecr-paper-builder-kit/scripts/test_report_lint.ps1'
          Case = 'InvalidSearchAttemptOneReceiptMultipleMisses'
          ExpectedContains = 'receipt count must equal missed source problem number count'
        },
        [pscustomobject]@{
          Kind = 'script-case'
          LocationField = 'script'
          Location = 'mathsecr-paper-builder-kit/scripts/test_report_lint.ps1'
          Case = 'InvalidSearchAttemptWrongTargetBinding'
          ExpectedContains = 'targetBinding.sourceProblemNumber does not match missed problem number'
        }
      )
    },
    [pscustomobject]@{
      Id = 'partial-coverage-miss-closure'
      Category = 'Search'
      Impact = 'high'
      Status = 'gated'
      TestScript = 'mathsecr-paper-builder-kit/scripts/test_state_machine.ps1'
      TestCase = 'All'
      RunnerLabel = 'Offline State Machine All'
      Evidence = @(
        '.omo/evidence/mathsecr_metadata_rescue_gap_2026-08-15.md',
        '.omo/evidence/mathsecr_semantic_and_false_negative_2026-08-26.md'
      )
      Corpus = @(
        [pscustomobject]@{
          Kind = 'fixture-case'
          LocationField = 'fixture'
          Location = 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json'
          Case = 'MetadataRescueIncompleteCoverage'
          ExpectedContains = 'metadata-rescue-receipt-invalid'
        },
        [pscustomobject]@{
          Kind = 'fixture-case'
          LocationField = 'fixture'
          Location = 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json'
          Case = 'MetadataRescueExactIdMissing'
          ExpectedContains = 'metadata-rescue-receipt-invalid'
        }
      )
    },
    [pscustomobject]@{
      Id = 'ambiguous-glyph-certainty-escalation'
      Category = 'Failure'
      Impact = 'high'
      Status = 'gated'
      TestScript = 'mathsecr-paper-builder-kit/scripts/test_state_machine.ps1'
      TestCase = 'All'
      RunnerLabel = 'Offline State Machine All'
      Evidence = @(
        '.omo/evidence/mathsecr_metadata_rescue_gap_2026-08-15.md',
        '.omo/evidence/mathsecr_source_anomaly_gate_2026-08-27.md',
        '.omo/evidence/mathsecr_recent_two_week_learning_expansion_2026-08-27.md'
      )
      Corpus = @(
        [pscustomobject]@{
          Kind = 'fixture-case'
          LocationField = 'fixture'
          Location = 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json'
          Case = 'MetadataRescueSourceAnomalyReceiptMissing'
          ExpectedContains = 'metadata-rescue-receipt-invalid'
        },
        [pscustomobject]@{
          Kind = 'fixture-case'
          LocationField = 'fixture'
          Location = 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json'
          Case = 'MetadataRescueSourceAnomaly'
          ExpectedContains = 'source-anomaly-pending'
        }
      )
    },
    [pscustomobject]@{
      Id = 'source-occurrence-identity-collapse'
      Category = 'Failure'
      Impact = 'high'
      Status = 'gated'
      TestScript = 'mathsecr-paper-builder-kit/scripts/test_state_machine.ps1'
      TestCase = 'All'
      RunnerLabel = 'Offline State Machine All'
      Evidence = @(
        '.omo/evidence/mathsecr_juyeop1_gongsu2_build_2026-08-22.md',
        '.omo/evidence/mathsecr_selection_journal_resume_2026-07-31.md',
        '.omo/evidence/mathsecr_recent_two_week_learning_expansion_2026-08-27.md'
      )
      Corpus = @(
        [pscustomobject]@{
          Kind = 'fixture-case'
          LocationField = 'fixture'
          Location = 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json'
          Case = 'DuplicateTargetIds'
          ExpectedContains = '"status":"차단"'
        }
      )
    },
    [pscustomobject]@{
      Id = 'state-bundle-contamination'
      Category = 'Failure'
      Impact = 'repeated'
      Status = 'gated'
      TestScript = 'mathsecr-paper-builder-kit/scripts/test_state_machine.ps1'
      TestCase = 'All'
      RunnerLabel = 'Offline State Machine All'
      Evidence = @(
        '.omo/evidence/mathsecr_state_contamination_2026-06-05.md',
        '.omo/evidence/mathsecr_restart_results_2026-06-05.md',
        '.omo/evidence/mathsecr_session_report_1917284_2026-08-21.md',
        '.omo/evidence/mathsecr_juyeop1_gongsu2_build_2026-08-22.md'
      )
      Corpus = @(
        [pscustomobject]@{
          Kind = 'fixture-case'
          LocationField = 'fixture'
          Location = 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json'
          Case = 'Collapse'
          ExpectedContains = '"status":"차단"'
        },
        [pscustomobject]@{
          Kind = 'fixture-case'
          LocationField = 'fixture'
          Location = 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json'
          Case = 'PermutationDrift'
          ExpectedContains = '"state":"EDIT_VERIFY"'
        }
      )
    },
    [pscustomobject]@{
      Id = 'bounded-inventory-fast-lane'
      Category = 'Efficient'
      Impact = 'observed'
      Status = 'record-only'
      TestScript = $null
      TestCase = $null
      RunnerLabel = $null
      Evidence = @(
        '.omo/evidence/mathsecr_session_019ecab8_learning_review.md',
        '.omo/evidence/mathsecr_mission_first_review_2026-06-05.md',
        '.omo/evidence/mathsecr_session_report_1917284_2026-08-21.md'
      )
      Corpus = @()
    },
    [pscustomobject]@{
      Id = 'circular-ground-truth-self-confirmation'
      Category = 'Failure'
      Impact = 'high'
      Status = 'gated'
      TestScript = 'mathsecr-paper-builder-kit/scripts/test_ground_truth_contract.ps1'
      TestCase = 'All'
      RunnerLabel = 'Ground Truth Independence Contract All'
      Evidence = @(
        '.omo/evidence/mathsecr_mandela_ground_truth_2026-08-27.md',
        '.omo/evidence/mathsecr_body_only_exact_policy_2026-06-07.md'
      )
      Corpus = @(
        [pscustomobject]@{
          Kind = 'script-case'
          LocationField = 'script'
          Location = 'mathsecr-paper-builder-kit/scripts/test_ground_truth_contract.ps1'
          Case = 'CircularBodyExactSelfOracle'
          ExpectedContains = 'independent oracle cannot reuse a design artifact'
        }
      )
    },
    [pscustomobject]@{
      Id = 'stale-regression-evidence-reuse'
      Category = 'Failure'
      Impact = 'high'
      Status = 'gated'
      TestScript = 'mathsecr-paper-builder-kit/scripts/test_regression_evidence_contract.ps1'
      TestCase = 'All'
      RunnerLabel = 'Regression Evidence Contract'
      Evidence = @(
        '.omo/evidence/mathsecr_mandela_ground_truth_2026-08-27.md',
        '.omo/evidence/mathsecr_recent_two_week_learning_expansion_2026-08-27.md'
      )
      Corpus = @(
        [pscustomobject]@{
          Kind = 'script-case'
          LocationField = 'script'
          Location = 'mathsecr-paper-builder-kit/scripts/test_regression_evidence_contract.ps1'
          Case = 'StalePassArtifactReuse'
          ExpectedContains = 'current validation input bytes'
        }
      )
    }
  )
  $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
  foreach ($lesson in $lessons) {
    $id = Get-RequiredString $lesson 'id' 'lesson'
    if (-not $seenIds.Add($id)) {
      Fail "duplicate lesson id '$id'."
    }
    $category = Get-RequiredString $lesson 'category' "lesson '$id'"
    if (@('Failure', 'Efficient', 'Search', 'Tooling', 'Policy') -cnotcontains $category) {
      Fail "lesson '$id' has an unknown category '$category'."
    }
    $impact = Get-RequiredString $lesson 'impact' "lesson '$id'"
    if (@('high', 'repeated', 'observed') -cnotcontains $impact) {
      Fail "lesson '$id' has an unknown impact '$impact'."
    }
    $status = Get-RequiredString $lesson 'status' "lesson '$id'"
    if (@($allowedStatuses) -cnotcontains $status) {
      Fail "lesson '$id' uses a status not allowed by registry.contract."
    }
    if (@($highImpactStatuses) -ccontains $impact -and $status -cne 'gated') {
      Fail "high/repeated lessons must be gated: '$id'."
    }
    if ($impact -ceq 'observed' -and $status -cne 'record-only') {
      Fail "observed lessons must remain record-only: '$id'."
    }

    foreach ($field in @('patternFamily', 'antiPattern', 'failureSignal')) {
      $null = Get-RequiredString $lesson $field "lesson '$id'"
    }
    $evidence = @(Get-RequiredArray $lesson 'evidence' "lesson '$id'")
    Assert-NonEmptyStringArray $evidence "lesson '$id'.evidence" 1
    foreach ($evidencePath in $evidence) {
      Assert-RelativeUnder ([string]$evidencePath) '.omo/evidence/' "lesson '$id'.evidence"
      $evidenceFullPath = Resolve-ProjectRelativePath ([string]$evidencePath) "lesson '$id'.evidence"
      if (-not (Test-Path -LiteralPath $evidenceFullPath -PathType Leaf)) {
        Fail "lesson '$id' evidence does not exist: $evidencePath"
      }
    }
    $specificExamples = @(Get-RequiredArray $lesson 'specificExamples' "lesson '$id'")
    Assert-NonEmptyStringArray $specificExamples "lesson '$id'.specificExamples" 2
    foreach ($field in @('preserve', 'discard', 'nextCycleVocabulary')) {
      $values = @(Get-RequiredArray $lesson $field "lesson '$id'")
      Assert-NonEmptyStringArray $values "lesson '$id'.$field" 1
    }

    $qualityGateProperty = $lesson.PSObject.Properties['qualityGate']
    $negativeCorpusProperty = $lesson.PSObject.Properties['negativeCorpus']
    if ($status -ceq 'gated') {
      if ($null -eq $qualityGateProperty) {
        Fail "gated lesson '$id' requires qualityGate."
      }
      $qualityGate = $qualityGateProperty.Value
      $testScript = Get-RequiredString $qualityGate 'testScript' "lesson '$id'.qualityGate"
      Assert-RelativeUnder $testScript 'mathsecr-paper-builder-kit/scripts/' "lesson '$id'.qualityGate.testScript"
      $testScriptFullPath = Resolve-ProjectRelativePath $testScript "lesson '$id'.qualityGate.testScript"
      if (-not (Test-Path -LiteralPath $testScriptFullPath -PathType Leaf)) {
        Fail "lesson '$id' qualityGate testScript does not exist: $testScript"
      }
      $testCase = Get-RequiredString $qualityGate 'testCase' "lesson '$id'.qualityGate"
      $runnerLabel = Get-RequiredString $qualityGate 'runnerLabel' "lesson '$id'.qualityGate"
      $testAnchor = Get-RequiredString $qualityGate 'testAnchor' "lesson '$id'.qualityGate"
      $expectedOutcome = Get-RequiredString $qualityGate 'expectedOutcome' "lesson '$id'.qualityGate"
      Assert-DirectRunnerGate $RunnerAst $runnerLabel $testScript $testCase "lesson '$id' qualityGate"
      $testScriptAst = Read-PowerShellAst $testScriptFullPath "lesson '$id'.qualityGate.testScript"
      Assert-ExecutableTestAnchor $testScriptAst $testAnchor "lesson '$id' qualityGate test anchor"
      if ([string]::IsNullOrWhiteSpace($expectedOutcome)) {
        Fail "lesson '$id'.qualityGate.expectedOutcome must be non-empty."
      }
      if ($null -eq $negativeCorpusProperty) {
        Fail "gated lesson '$id' requires negativeCorpus."
      }
      $negativeCorpus = @(Get-RequiredArray $lesson 'negativeCorpus' "lesson '$id'")
      if ($negativeCorpus.Count -lt 1) {
        Fail "gated lesson '$id' requires at least one negativeCorpus item."
      }
      for ($index = 0; $index -lt $negativeCorpus.Count; $index++) {
        Test-NegativeCorpusItem `
          $negativeCorpus[$index] `
          "lesson '$id'.negativeCorpus[$index]" `
          $testScript `
          $testCase `
          $testScriptAst
      }
    } else {
      if ($null -ne $qualityGateProperty) {
        Fail "record-only lesson '$id' must not declare qualityGate."
      }
      if ($null -ne $negativeCorpusProperty) {
        Fail "record-only lesson '$id' must not declare negativeCorpus."
      }
      $null = Get-RequiredString $lesson 'gateBlocker' "lesson '$id'"
    }
  }
  foreach ($seedContract in $requiredSeedContracts) {
    $requiredSeedId = $seedContract.Id
    if (-not $seenIds.Contains($requiredSeedId)) {
      Fail "registry.lessons is missing durable seed lesson '$requiredSeedId'."
    }
    $seedLesson = @($lessons | Where-Object { $_.id -is [string] -and $_.id -ceq $requiredSeedId })[0]
    foreach ($fieldName in @('Category', 'Impact', 'Status')) {
      $propertyName = $fieldName.ToLowerInvariant()
      $actualValue = Get-RequiredString $seedLesson $propertyName "durable seed lesson '$requiredSeedId'"
      $expectedValue = [string]$seedContract.$fieldName
      if ($actualValue -cne $expectedValue) {
        Fail "durable seed lesson '$requiredSeedId' must preserve $propertyName '$expectedValue'; got '$actualValue'."
      }
    }
    $seedEvidence = @(Get-RequiredArray $seedLesson 'evidence' "durable seed lesson '$requiredSeedId'")
    foreach ($requiredEvidencePath in @($seedContract.Evidence)) {
      $matchingEvidencePaths = @($seedEvidence | Where-Object {
          $_ -is [string] -and $_ -ceq $requiredEvidencePath
        })
      if ($matchingEvidencePaths.Count -ne 1) {
        Fail "durable seed lesson '$requiredSeedId' must preserve evidence path '$requiredEvidencePath'; got $($matchingEvidencePaths.Count)."
      }
    }
    if ($seedContract.Status -ceq 'gated') {
      $seedGate = (Get-RequiredProperty $seedLesson 'qualityGate' "durable seed lesson '$requiredSeedId'").Value
      foreach ($gateField in @('TestScript', 'TestCase', 'RunnerLabel')) {
        $propertyName = $gateField.Substring(0, 1).ToLowerInvariant() + $gateField.Substring(1)
        $actualValue = Get-RequiredString $seedGate $propertyName "durable seed lesson '$requiredSeedId'.qualityGate"
        $expectedValue = [string]$seedContract.$gateField
        if ($actualValue -cne $expectedValue) {
          Fail "durable seed lesson '$requiredSeedId' must preserve qualityGate.$propertyName '$expectedValue'; got '$actualValue'."
        }
      }
      $seedCorpus = @(Get-RequiredArray $seedLesson 'negativeCorpus' "durable seed lesson '$requiredSeedId'")
      foreach ($requiredCorpusItem in @($seedContract.Corpus)) {
        $locationField = [string]$requiredCorpusItem.LocationField
        $matchingCorpusItems = @($seedCorpus | Where-Object {
            $locationProperty = $_.PSObject.Properties[$locationField]
            $_.kind -is [string] -and $_.kind -ceq $requiredCorpusItem.Kind -and
              $null -ne $locationProperty -and $locationProperty.Value -is [string] -and
              $locationProperty.Value -ceq $requiredCorpusItem.Location -and
              $_.case -is [string] -and $_.case -ceq $requiredCorpusItem.Case -and
              $_.expectedContains -is [string] -and $_.expectedContains -ceq $requiredCorpusItem.ExpectedContains
          })
        if ($matchingCorpusItems.Count -ne 1) {
          Fail "durable seed lesson '$requiredSeedId' must preserve negativeCorpus tuple '$($requiredCorpusItem.Kind)|$($requiredCorpusItem.Location)|$($requiredCorpusItem.Case)|$($requiredCorpusItem.ExpectedContains)'; got $($matchingCorpusItems.Count)."
        }
      }
    }
  }
  $gatedCount = @($lessons | Where-Object { $_.status -ceq 'gated' }).Count
  $recordOnlyCount = @($lessons | Where-Object { $_.status -ceq 'record-only' }).Count
  if ($gatedCount -lt 4 -or $recordOnlyCount -lt 1) {
    Fail "registry must preserve at least 4 gated and 1 record-only seed lessons; got gated=$gatedCount record-only=$recordOnlyCount."
  }
  return [pscustomobject]@{
    LessonCount = $lessons.Count
    GatedCount = $gatedCount
    RecordOnlyCount = $recordOnlyCount
  }
}

function Expect-Rejection {
  param(
    $Registry,
    [string]$Name,
    [scriptblock]$Mutate,
    [string]$ExpectedFragment,
    [System.Management.Automation.Language.ScriptBlockAst]$RunnerAst
  )
  $candidate = Copy-Value $Registry
  & $Mutate $candidate
  $rejected = $false
  $message = ''
  try {
    $null = Test-Registry $candidate $RunnerAst
  } catch {
    $rejected = $true
    $message = $_.Exception.Message
  }
  if (-not $rejected) {
    Fail "$Name should have been rejected."
  }
  if (-not $message.Contains($ExpectedFragment)) {
    Fail "$Name rejected with unexpected message: $message"
  }
  Write-Host "$Name rejected as expected: $message"
}

function Expect-ActionRejection {
  param([string]$Name, [scriptblock]$Action, [string]$ExpectedFragment)

  $rejected = $false
  $message = ''
  try {
    & $Action
  } catch {
    $rejected = $true
    $message = $_.Exception.Message
  }
  if (-not $rejected) {
    Fail "$Name should have been rejected."
  }
  if (-not $message.Contains($ExpectedFragment)) {
    Fail "$Name rejected with unexpected message: $message"
  }
  Write-Host "$Name rejected as expected: $message"
}

$registryPath = Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/lessons/re0-memo-registry.json'
$runnerPath = Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/scripts/run_mathsecr_regression.ps1'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
  Fail "registry file is missing: $registryPath"
}
if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
  Fail "regression runner is missing: $runnerPath"
}
try {
  $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
} catch {
  Fail "registry is not valid JSON: $registryPath"
}
$runnerAst = Read-PowerShellAst $runnerPath 'registry.contract.runner'
$summary = Test-Registry $registry $runnerAst

$intentionalRedCaseCount = 0
if ($Case -eq 'All') {
  $redCases = @(
    [pscustomobject]@{
      Name = 'missing evidence path'
      Expected = 'must be under'
      Mutate = { param($candidate) $candidate.lessons[0].evidence[0] = 'C:\outside.md' }
    },
    [pscustomobject]@{
      Name = 'durable semantic evidence replaced by unrelated incident'
      Expected = 'must preserve evidence path'
      Mutate = {
        param($candidate)
        $candidate.lessons[0].evidence = [object[]]@('.omo/evidence/mathsecr_state_contamination_2026-06-05.md')
      }
    },
    [pscustomobject]@{
      Name = 'duplicate lesson id'
      Expected = 'duplicate lesson id'
      Mutate = { param($candidate) $candidate.lessons[1].id = $candidate.lessons[0].id }
    },
    [pscustomobject]@{
      Name = 'durable Mandela lesson removed'
      Expected = "missing durable seed lesson 'circular-ground-truth-self-confirmation'"
      Mutate = { param($candidate) $candidate.lessons = [object[]]@($candidate.lessons | Where-Object { $_.id -cne 'circular-ground-truth-self-confirmation' }) }
    },
    [pscustomobject]@{
      Name = 'durable ambiguous glyph lesson removed'
      Expected = "missing durable seed lesson 'ambiguous-glyph-certainty-escalation'"
      Mutate = { param($candidate) $candidate.lessons = [object[]]@($candidate.lessons | Where-Object { $_.id -cne 'ambiguous-glyph-certainty-escalation' }) }
    },
    [pscustomobject]@{
      Name = 'durable source occurrence lesson removed'
      Expected = "missing durable seed lesson 'source-occurrence-identity-collapse'"
      Mutate = { param($candidate) $candidate.lessons = [object[]]@($candidate.lessons | Where-Object { $_.id -cne 'source-occurrence-identity-collapse' }) }
    },
    [pscustomobject]@{
      Name = 'durable stale regression evidence lesson removed'
      Expected = "missing durable seed lesson 'stale-regression-evidence-reuse'"
      Mutate = { param($candidate) $candidate.lessons = [object[]]@($candidate.lessons | Where-Object { $_.id -cne 'stale-regression-evidence-reuse' }) }
    },
    [pscustomobject]@{
      Name = 'high impact record-only lesson'
      Expected = 'high/repeated lessons must be gated'
      Mutate = {
        param($candidate)
        @($candidate.lessons | Where-Object { $_.id -ceq 'bounded-inventory-fast-lane' })[0].impact = 'high'
      }
    },
    [pscustomobject]@{
      Name = 'unknown runner label'
      Expected = 'direct top-level runner gate'
      Mutate = { param($candidate) $candidate.lessons[0].qualityGate.runnerLabel = 'Unknown Runner All' }
    },
    [pscustomobject]@{
      Name = 'unknown fixture case'
      Expected = 'must resolve to exactly one node'
      Mutate = { param($candidate) $candidate.lessons[0].negativeCorpus[0].case = 'NoSuchFixtureCase' }
    },
    [pscustomobject]@{
      Name = 'positive fixture substituted for negative corpus'
      Expected = 'must encode a negative outcome'
      Mutate = {
        param($candidate)
        $candidate.lessons[0].negativeCorpus[0].case = 'goguk2-q2-exact-found'
        $candidate.lessons[0].negativeCorpus[0].expectedContains = '"status":"exact-found"'
      }
    },
    [pscustomobject]@{
      Name = 'record-only fake gate'
      Expected = 'record-only lesson'
      Mutate = {
        param($candidate)
        @($candidate.lessons | Where-Object { $_.id -ceq 'bounded-inventory-fast-lane' })[0] |
          Add-Member -NotePropertyName qualityGate -NotePropertyValue ([pscustomobject]@{})
      }
    },
    [pscustomobject]@{
      Name = 'one specific example'
      Expected = 'requires at least 2 item(s)'
      Mutate = { param($candidate) $candidate.lessons[0].specificExamples = [object[]]@('one') }
    },
    [pscustomobject]@{
      Name = 'gated negative corpus removed'
      Expected = 'requires negativeCorpus'
      Mutate = { param($candidate) $candidate.lessons[0].PSObject.Properties.Remove('negativeCorpus') }
    },
    [pscustomobject]@{
      Name = 'quality gate script and label mismatch'
      Expected = 'direct top-level runner gate'
      Mutate = { param($candidate) $candidate.lessons[0].qualityGate.testScript = 'mathsecr-paper-builder-kit/scripts/test_state_machine.ps1' }
    },
    [pscustomobject]@{
      Name = 'traversal fixture path'
      Expected = 'traversal segment'
      Mutate = { param($candidate) $candidate.lessons[2].negativeCorpus[0].fixture = 'mathsecr-paper-builder-kit/test-fixtures/../outside.json' }
    },
    [pscustomobject]@{
      Name = 'allowed status set weakened'
      Expected = 'exact set'
      Mutate = { param($candidate) $candidate.contract.allowedStatuses = @('gated', 'gated') }
    },
    [pscustomobject]@{
      Name = 'seed lesson removed'
      Expected = 'at least 5 seed lessons'
      Mutate = { param($candidate) $candidate.lessons = @($candidate.lessons | Select-Object -First 4) }
    },
    [pscustomobject]@{
      Name = 'durable seed replaced at constant counts'
      Expected = 'missing durable seed lesson'
      Mutate = {
        param($candidate)
        $replacement = Copy-Value $candidate.lessons[2]
        $replacement.id = 'replacement-gated-seed'
        $candidate.lessons[0] = $replacement
      }
    },
    [pscustomobject]@{
      Name = 'durable gated seed downgraded with compensating gate'
      Expected = "must preserve impact 'high'"
      Mutate = {
        param($candidate)
        $downgraded = $candidate.lessons[0]
        $downgraded.impact = 'observed'
        $downgraded.status = 'record-only'
        $downgraded.PSObject.Properties.Remove('qualityGate')
        $downgraded.PSObject.Properties.Remove('negativeCorpus')
        $downgraded | Add-Member -NotePropertyName gateBlocker -NotePropertyValue 'Downgraded without preserving the earned incident gate.'
        $replacement = Copy-Value $candidate.lessons[2]
        $replacement.id = 'replacement-semantic-gate'
        $candidate.lessons = [object[]](@($candidate.lessons) + @($replacement))
      }
    },
    [pscustomobject]@{
      Name = 'non-assertion anchor'
      Expected = 'executable top-level assertion command'
      Mutate = { param($candidate) $candidate.lessons[0].qualityGate.testAnchor = 'param(' }
    },
    [pscustomobject]@{
      Name = 'singleton array in scalar field'
      Expected = 'must be a non-empty string'
      Mutate = { param($candidate) $candidate.lessons[0].id = [object[]]@('semantic-and-recall-collapse') }
    },
    [pscustomobject]@{
      Name = 'scalar object in negative corpus field'
      Expected = 'negativeCorpus must be an array'
      Mutate = { param($candidate) $candidate.lessons[0].negativeCorpus = $candidate.lessons[0].negativeCorpus[0] }
    },
    [pscustomobject]@{
      Name = 'fixture corpus swapped across gates'
      Expected = 'fixture path must be assigned by a direct executable statement'
      Mutate = { param($candidate) $candidate.lessons[0].negativeCorpus = Copy-Value $candidate.lessons[2].negativeCorpus }
    },
    [pscustomobject]@{
      Name = 'durable partial-coverage corpus replaced by unrelated blocker'
      Expected = 'must preserve negativeCorpus tuple'
      Mutate = {
        param($candidate)
        $candidate.lessons[2].negativeCorpus = [object[]]@(
          [pscustomobject]@{
            kind = 'fixture-case'
            fixture = 'mathsecr-paper-builder-kit/test-fixtures/state-machine/cases.json'
            case = 'Collapse'
            expectedContains = '"status":"차단"'
          }
        )
      }
    },
    [pscustomobject]@{
      Name = 'script corpus gate mismatch'
      Expected = 'must match qualityGate.testScript'
      Mutate = { param($candidate) $candidate.lessons[1].negativeCorpus[0].script = 'mathsecr-paper-builder-kit/scripts/test_state_machine.ps1' }
    },
    [pscustomobject]@{
      Name = 'generic script corpus binding'
      Expected = 'must resolve to exactly one executable switch case'
      Mutate = {
        param($candidate)
        foreach ($item in @($candidate.lessons[1].negativeCorpus)) {
          $item.case = 'All'
          $item.expectedContains = 'All'
        }
      }
    },
    [pscustomobject]@{
      Name = 'positive script case substituted for negative corpus'
      Expected = 'direct executable rejection assertion'
      Mutate = {
        param($candidate)
        $candidate.lessons[1].negativeCorpus[0].case = 'ValidComplete'
        $candidate.lessons[1].negativeCorpus[0].expectedContains = 'Invoke-MathSecrReportLint'
      }
    },
    [pscustomobject]@{
      Name = 'durable receipt corpus replaced by unrelated rejection'
      Expected = 'must preserve negativeCorpus tuple'
      Mutate = {
        param($candidate)
        $candidate.lessons[1].negativeCorpus = [object[]]@(
          [pscustomobject]@{
            kind = 'script-case'
            script = 'mathsecr-paper-builder-kit/scripts/test_report_lint.ps1'
            case = 'InvalidBundleOrder'
            expectedContains = 'ordered ID bundles'
          }
        )
      }
    }
  )
  foreach ($redCase in $redCases) {
    Expect-Rejection $registry $redCase.Name $redCase.Mutate $redCase.Expected $runnerAst
    $intentionalRedCaseCount++
  }

  $commentOnlyFixtureSource = @'
# mathsecr-paper-builder-kit/test-fixtures/search-attempts/goguk2-mid-q2.json
$fixture = @{}
'@
  $commentOnlyFixtureAst = Read-PowerShellTextAst $commentOnlyFixtureSource 'comment-only fixture source'
  Expect-ActionRejection 'comment-only fixture binding' {
    Assert-ExecutableFixtureLoad `
      $commentOnlyFixtureAst `
      'mathsecr-paper-builder-kit/test-fixtures/search-attempts/goguk2-mid-q2.json' `
      'synthetic fixture gate'
  } 'direct executable statement'
  $intentionalRedCaseCount++

  $missingAllDispatchSource = @'
param([string]$Case = "All")
$proof = @("All", "TargetCase")
$cases = if ($Case -eq "All") { @("OtherCase", "AnotherCase") } else { @($Case) }
try {
  foreach ($item in $cases) {
    switch ($item) {
      "TargetCase" { Expect-Rejection $item $invalid "expected failure" }
    }
  }
} finally {
}
'@
  $missingAllDispatchAst = Read-PowerShellTextAst $missingAllDispatchSource 'missing All-dispatch source'
  Expect-ActionRejection 'switch case omitted from All dispatch' {
    Assert-CaseIncludedInAllDispatch $missingAllDispatchAst 'TargetCase' 'synthetic script case'
  } 'executable All-case dispatch list'
  $intentionalRedCaseCount++

  $branchSwapDispatchSource = @'
param([string]$Case = "All")
$cases = if ($Case -eq "All") { @("OtherCase", "AnotherCase") } else { @("TargetCase") }
try {
  foreach ($item in $cases) {
    switch ($item) {
      "TargetCase" { Expect-Rejection $item $invalid "expected failure" }
    }
  }
} finally {
}
'@
  $branchSwapDispatchAst = Read-PowerShellTextAst $branchSwapDispatchSource 'branch-swapped All-dispatch source'
  Expect-ActionRejection 'switch case hidden in non-All branch' {
    Assert-CaseIncludedInAllDispatch $branchSwapDispatchAst 'TargetCase' 'synthetic script case'
  } 'executable All-case dispatch list'
  $intentionalRedCaseCount++

  $nestedDeadDispatchSource = @'
param([string]$Case = "All")
$cases = if ($Case -eq "All") { @($(if ($false) { "TargetCase" }), "OtherCase") } else { @($Case) }
try {
  foreach ($item in $cases) {
    switch ($item) {
      "TargetCase" { Expect-Rejection $item $invalid "expected failure" }
    }
  }
} finally {
}
'@
  $nestedDeadDispatchAst = Read-PowerShellTextAst $nestedDeadDispatchSource 'nested dead All-dispatch source'
  Expect-ActionRejection 'switch case hidden in dead nested expression' {
    Assert-CaseIncludedInAllDispatch $nestedDeadDispatchAst 'TargetCase' 'synthetic script case'
  } 'direct string literals'
  $intentionalRedCaseCount++

  $nestedReassignmentDispatchSource = @'
param([string]$Case = "All")
$cases = if ($Case -eq "All") { @("TargetCase", "OtherCase") } else { @($Case) }
if ($Case -eq "All") {
  $cases = @("OtherCase", "AnotherCase")
}
try {
  foreach ($item in $cases) {
    switch ($item) {
      "TargetCase" { Expect-Rejection $item $invalid "expected failure" }
    }
  }
} finally {
}
'@
  $nestedReassignmentDispatchAst = Read-PowerShellTextAst $nestedReassignmentDispatchSource 'nested reassignment dispatch source'
  Expect-ActionRejection 'All dispatch list overwritten before loop' {
    Assert-CaseIncludedInAllDispatch $nestedReassignmentDispatchAst 'TargetCase' 'synthetic script case'
  } 'adjacent root statements'
  $intentionalRedCaseCount++

  $deadBranchDispatchSource = @'
param([string]$Case = "All")
$cases = if ($Case -eq "All") { @("TargetCase", "OtherCase") } else { @($Case) }
if ($false) {
  foreach ($item in $cases) {
    switch ($item) {
      "TargetCase" { Expect-Rejection $item $invalid "expected failure" }
    }
  }
}
'@
  $deadBranchDispatchAst = Read-PowerShellTextAst $deadBranchDispatchSource 'dead branch dispatch source'
  Expect-ActionRejection 'switch dispatch hidden in dead branch' {
    Assert-CaseIncludedInAllDispatch $deadBranchDispatchAst 'TargetCase' 'synthetic script case'
  } 'direct root executable dispatch path'
  $intentionalRedCaseCount++

  $iteratorReassignedDispatchSource = @'
param([string]$Case = "All")
$cases = if ($Case -eq "All") { @("TargetCase", "OtherCase") } else { @($Case) }
try {
  foreach ($item in $cases) {
    $item = "OtherCase"
    switch ($item) {
      "TargetCase" { Expect-Rejection $item $invalid "expected failure" }
    }
  }
} finally {
}
'@
  $iteratorReassignedDispatchAst = Read-PowerShellTextAst $iteratorReassignedDispatchSource 'iterator reassigned dispatch source'
  Expect-ActionRejection 'dispatch iterator overwritten before switch' {
    Assert-CaseIncludedInAllDispatch $iteratorReassignedDispatchAst 'TargetCase' 'synthetic script case'
  } 'first executable statement'
  $intentionalRedCaseCount++

  $targetContinuedDispatchSource = @'
param([string]$Case = "All")
$cases = if ($Case -eq "All") { @("TargetCase", "OtherCase") } else { @($Case) }
try {
  foreach ($item in $cases) {
    if ($item -eq "TargetCase") {
      continue
    }
    switch ($item) {
      "TargetCase" { Expect-Rejection $item $invalid "expected failure" }
    }
  }
} finally {
}
'@
  $targetContinuedDispatchAst = Read-PowerShellTextAst $targetContinuedDispatchSource 'target continued dispatch source'
  Expect-ActionRejection 'target bypassed before switch' {
    Assert-CaseIncludedInAllDispatch $targetContinuedDispatchAst 'TargetCase' 'synthetic script case'
  } 'first executable statement'
  $intentionalRedCaseCount++

  $preDispatchBypassTemplate = @'
param([string]$Case = "All", [string]$ReportPath = "")
__PREFIX__
$cases = if ($Case -eq "All") { @("TargetCase", "OtherCase") } else { @($Case) }
try {
  foreach ($item in $cases) {
    switch ($item) {
      "TargetCase" { Expect-Rejection $item $invalid "expected failure" }
    }
  }
} finally {
}
'@
  $preDispatchBypassCases = @(
    [pscustomobject]@{
      Name = 'Case input overwritten before All selection'
      Prefix = '$Case = "OtherCase"'
      Expected = "runner input variable 'Case'"
    },
    [pscustomobject]@{
      Name = 'Case input overwritten in nested branch'
      Prefix = 'if ($Case -eq "All") { $Case = "OtherCase" }'
      Expected = "runner input variable 'Case'"
    },
    [pscustomobject]@{
      Name = 'direct return before All dispatch'
      Prefix = 'return'
      Expected = 'unsupported pre-dispatch return/exit path'
    },
    [pscustomobject]@{
      Name = 'direct success exit before All dispatch'
      Prefix = 'exit 0'
      Expected = 'unsupported pre-dispatch return/exit path'
    },
    [pscustomobject]@{
      Name = 'Case-dependent return before All dispatch'
      Prefix = 'if ($Case -eq "All") { return }'
      Expected = 'unsupported pre-dispatch return/exit path'
    },
    [pscustomobject]@{
      Name = 'constant-true return before All dispatch'
      Prefix = 'if ($true) { return }'
      Expected = 'unsupported pre-dispatch return/exit path'
    }
  )
  foreach ($preDispatchBypassCase in $preDispatchBypassCases) {
    $preDispatchBypassSource = $preDispatchBypassTemplate.Replace('__PREFIX__', $preDispatchBypassCase.Prefix)
    $preDispatchBypassAst = Read-PowerShellTextAst $preDispatchBypassSource $preDispatchBypassCase.Name
    Expect-ActionRejection $preDispatchBypassCase.Name {
      Assert-CaseIncludedInAllDispatch $preDispatchBypassAst 'TargetCase' 'synthetic script case'
    } $preDispatchBypassCase.Expected
    $intentionalRedCaseCount++
  }

  $truthyReportPathDefaultSource = $preDispatchBypassTemplate.Replace(
    '[string]$ReportPath = ""',
    '[string]$ReportPath = "skip"'
  ).Replace('__PREFIX__', 'if ($ReportPath) { exit 0 }')
  $truthyReportPathDefaultAst = Read-PowerShellTextAst $truthyReportPathDefaultSource 'truthy ReportPath default source'
  Expect-ActionRejection 'truthy ReportPath default bypasses All dispatch' {
    Assert-CaseIncludedInAllDispatch $truthyReportPathDefaultAst 'TargetCase' 'synthetic script case'
  } 'ReportPath parameter default'
  $intentionalRedCaseCount++

  $runnerWithReportPathSource = @'
try {
  Invoke-Logged "Session Report Linter All" {
    Invoke-Script -RelativePath "mathsecr-paper-builder-kit/scripts/test_report_lint.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All"; ReportPath = "valid-report.md" }
  }
} finally {
}
'@
  $runnerWithReportPathAst = Read-PowerShellTextAst $runnerWithReportPathSource 'runner with ReportPath source'
  Expect-ActionRejection 'runner supplies ReportPath to All gate' {
    Assert-DirectRunnerGate `
      $runnerWithReportPathAst `
      'Session Report Linter All' `
      'mathsecr-paper-builder-kit/scripts/test_report_lint.ps1' `
      'All' `
      'synthetic runner gate'
  } 'exactly one direct top-level runner gate'
  $intentionalRedCaseCount++

  $deadRunnerGateSource = @'
try {
  Invoke-Logged "Session Report Linter All" {
    if ($false) {
      Invoke-Script -RelativePath "mathsecr-paper-builder-kit/scripts/test_report_lint.ps1" -Parameters @{ ProjectRoot = $ProjectRoot; Case = "All" }
    }
  }
} finally {
}
'@
  $deadRunnerGateAst = Read-PowerShellTextAst $deadRunnerGateSource 'dead runner gate source'
  Expect-ActionRejection 'runner gate hidden in dead branch' {
    Assert-DirectRunnerGate `
      $deadRunnerGateAst `
      'Session Report Linter All' `
      'mathsecr-paper-builder-kit/scripts/test_report_lint.ps1' `
      'All' `
      'synthetic runner gate'
  } 'exactly one direct top-level runner gate'
  $intentionalRedCaseCount++

  $singleEvidenceRegistry = Copy-Value $registry
  $singleEvidenceLesson = Copy-Value (@($singleEvidenceRegistry.lessons | Where-Object { $_.id -ceq 'bounded-inventory-fast-lane' })[0])
  $singleEvidenceLesson.id = 'singleton-evidence-observed'
  $singleEvidenceLesson.evidence = [object[]]@($singleEvidenceLesson.evidence[0])
  $singleEvidenceRegistry.lessons = [object[]](@($singleEvidenceRegistry.lessons) + @($singleEvidenceLesson))
  $singleEvidenceSummary = Test-Registry $singleEvidenceRegistry $runnerAst
  Assert-True ($singleEvidenceSummary.LessonCount -eq ($summary.LessonCount + 1)) 'singleton evidence array green case was not preserved.'

  $extendedRegistry = Copy-Value $registry
  $additionalLesson = Copy-Value (@($extendedRegistry.lessons | Where-Object { $_.id -ceq 'bounded-inventory-fast-lane' })[0])
  $additionalLesson.id = 'additional-observed-seed'
  $additionalLesson.patternFamily = 'An additional observed lesson can extend the registry without changing the validator implementation.'
  $extendedRegistry.lessons = @($extendedRegistry.lessons) + @($additionalLesson)
  $extendedSummary = Test-Registry $extendedRegistry $runnerAst
  Assert-True ($extendedSummary.LessonCount -eq ($summary.LessonCount + 1)) 'registry extension green case did not accept one additional schema-valid lesson.'
}

Write-Host "Re0Memo PASS lessons=$($summary.LessonCount) gated=$($summary.GatedCount) record_only=$($summary.RecordOnlyCount) intentional_red_cases=$intentionalRedCaseCount"
