[CmdletBinding()]
param(
  [string]$ProjectRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [ValidateSet('All')][string]$Case='All',
  [string]$NodePath='node',
  [string]$PlaywrightModule,
  [string]$BrowserPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot)
$kit=Join-Path $ProjectRoot 'mathsecr-paper-builder-kit'
. (Join-Path $ProjectRoot 'scripts/perf/assembly_support.ps1')
$pwsh=(Get-Command pwsh).Source
function Assert-AssemblyTest {param([bool]$Condition,[string]$Message);if (-not $Condition) {throw $Message}}
function Read-AssemblyJson {param([string]$Path);return ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)}
function Invoke-AssemblyTest {
  param([string]$ObservationName,[string]$JudgmentName,[string]$OutputName,[string]$RosterName='source-roster.json',
    [string]$Surface,[string]$FixtureRoot=$root)
  $surfaceArgument=@{}
  if ($PSBoundParameters.ContainsKey('Surface')) { $surfaceArgument.Surface=$Surface }
  $output=@(& $pwsh -NoProfile -File (Join-Path $kit 'scripts/assemble_target.ps1') -ProjectRoot $FixtureRoot -RosterPath $RosterName -OccurrenceKey $session.snapshot.targets[0].occurrenceKey -ObservationPath $ObservationName -BodyJudgmentPath $JudgmentName -CandidateRenderPath 'candidate-1.png' -OutPath $OutputName @surfaceArgument 2>&1 | ForEach-Object {[string]$_})
  $code=$LASTEXITCODE
  Assert-AssemblyTest ($output.Count -eq 1) ("Assembler must return exactly one JSON line: "+($output -join ' '))
  return [pscustomobject]@{Code=$code;Response=(ConvertFrom-MathSecrContractJson $output[0])}
}
function Assert-AssemblyRejection {
  param([string]$ObservationName,[string]$JudgmentName,[string]$OutputName,[string]$Reason,[string]$RosterName='source-roster.json')
  $result=Invoke-AssemblyTest $ObservationName $JudgmentName $OutputName $RosterName
  Assert-AssemblyTest ($result.Code -eq 1 -and -not $result.Response.assembled -and
    $result.Response.reason -ceq $Reason -and -not (Test-Path -LiteralPath (Join-Path $root $OutputName))) ("Assembly rejection differs: "+($result | ConvertTo-Json -Depth 5 -Compress))
}
if (-not $PlaywrightModule) {
  $candidates=@((Join-Path $kit 'node_modules/playwright'),
    (Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright'))
  $found=@($candidates | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1)
  if ($found.Count) {$PlaywrightModule=$found[0]}
}
if (-not $BrowserPath) {
  $candidates=@((Join-Path $env:ProgramFiles 'Google/Chrome/Application/chrome.exe'),
    (Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Microsoft/Edge/Application/msedge.exe'))
  $found=@($candidates | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1)
  if ($found.Count) {$BrowserPath=$found[0]}
}
if (-not $PlaywrightModule -or -not $BrowserPath) {throw 'Assembly DOM test requires Playwright module and a browser executable.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-assembly-'+[guid]::NewGuid().ToString('N'))
$worker=$null
$offlineWorker=$null
$offlineRoot=Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-assembly-'+[guid]::NewGuid().ToString('N'))
try {
  foreach ($name in @('simulator','mathsecr-current')) {
    $valid=Test-Json -Json (Get-Content -LiteralPath (Join-Path $kit "test-fixtures/control-map/$name.json") -Raw) -SchemaFile (Join-Path $kit 'test-fixtures/control-map/schema.json')
    Assert-AssemblyTest $valid "Invalid $name control map schema."
  }
  $fixture=New-MathSecrAppendHistoryFixture -ProblemCount 3 -HistoryDepth 0 -OutRoot $root
  $session=New-MathSecrAssemblySession $fixture
  $targetKey=$session.snapshot.targets[0].occurrenceKey
  $originalSelect=Invoke-MathSecrProductionStep -Step Select -InputObject $session -ProjectRoot $root -TargetOccurrenceKey $targetKey
  $originalNext=Invoke-MathSecrProductionStep -Step BeforeNext -InputObject $session -ProjectRoot $root
  Assert-AssemblyTest ($originalSelect.Valid -and $originalNext.Valid) 'Synthetic pre-next session characterization failed.'
  $domPath=Join-Path $root 'dom-packet.json'
  & $NodePath (Join-Path $kit 'test-fixtures/control-map/collector_assembly_test.js') $PlaywrightModule $BrowserPath $domPath
  if ($LASTEXITCODE -ne 0) {throw 'Control map DOM collection failed.'}
  $dom=Read-AssemblyJson $domPath
  $domObservation=Test-MathSecrSearchObservation -Packet $dom -AttemptId 'attempt-1' -Chips @('본문','조건') -ResultCount $dom.observations[-1].raw.result.count
  Assert-AssemblyTest $domObservation.FreshResultVerified ('Simulator observation rejected: '+($domObservation.Errors -join ';'))
  $observationA=New-MathSecrAssemblyObservationInput $dom
  $packetB=New-MathSecrBenchmarkObservation 'attempt-1' '7231357'
  $observationB=New-MathSecrAssemblyObservationInput $packetB
  foreach ($observationInput in @($observationA,$observationB)) {
    $observationInput.attempts[0].chips[0] | Add-Member -NotePropertyName formulaCommitReceipt -NotePropertyValue 'synthetic-retained-commit'
    $observationInput.attempts[0].chips[0] | Add-Member -NotePropertyName indexEvidenceReceipt -NotePropertyValue 'synthetic-retained-index'
  }
  $factsA=Copy-MathSecrBenchmarkObject $observationA
  $factsB=Copy-MathSecrBenchmarkObject $observationB
  foreach ($facts in @($factsA,$factsB)) {
    foreach ($name in @('submission','beforeSubmit','observations')) {$facts.attempts[0].PSObject.Properties.Remove($name)}
  }
  Assert-AssemblyTest ((ConvertTo-Json $factsA -Depth 80 -Compress) -ceq (ConvertTo-Json $factsB -Depth 80 -Compress)) 'A/B attempt facts changed along with the observations.'
  $judgment=New-MathSecrAssemblyJudgment 'attempt-1' '7231357'
  Assert-AssemblyTest (Test-Json -Json (ConvertTo-Json $judgment -Depth 10) -SchemaFile (Join-Path $kit 'test-fixtures/body-judgment/schema.json')) 'Synthetic judgment schema rejected.'
  $null=Write-MathSecrBenchmarkArtifact $observationA $root 'observation-a.json'
  $null=Write-MathSecrBenchmarkArtifact $observationB $root 'observation-b.json'
  $null=Write-MathSecrBenchmarkArtifact $judgment $root 'judgment.json'
  Assert-AssemblyRejection 'observation-a.json' 'judgment.json' 'target-a.json' 'selected-search-receipt-invalid'
  Write-Output 'AssemblyPath A1 PASS (default Aside rejects simulator receipt: selected-search-receipt-invalid).'
  # A2 uses the same actual file-DOM packet as A1 and an explicitly declared
  # offline session. No receipt surface or URL is rewritten to obtain acceptance.
  $offlineFixture=New-MathSecrAppendHistoryFixture -ProblemCount 3 -HistoryDepth 0 -OutRoot $offlineRoot -Surface offline-dom-test
  $offlineSession=New-MathSecrAssemblySession $offlineFixture
  Assert-AssemblyTest ($offlineSession.paper.url -ceq $dom.submission.url) 'Offline fixture URL differs from the collected simulator URL.'
  $null=Write-MathSecrBenchmarkArtifact $observationA $offlineRoot 'observation-a.json'
  $null=Write-MathSecrBenchmarkArtifact $judgment $offlineRoot 'judgment.json'
  $offlineAssembly=Invoke-AssemblyTest 'observation-a.json' 'judgment.json' 'target-a2.json' -Surface offline-dom-test -FixtureRoot $offlineRoot
  Assert-AssemblyTest ($offlineAssembly.Code -eq 0 -and $offlineAssembly.Response.assembled) 'Offline simulator A2 assembly failed.'
  $offlineSession.snapshot.targets[0]=Read-AssemblyJson (Join-Path $offlineRoot 'target-a2.json')
  $offlineSession.snapshot.selectionBeforeNextIds=@($offlineSession.snapshot.targets.selectedId)
  $null=Write-MathSecrBenchmarkArtifact $offlineSession $offlineRoot 'offline-session.json'
  $offlineWorker=Start-MathSecrResidentValidation $ProjectRoot $offlineRoot
  $offlineSelect=Invoke-MathSecrResidentCommand $offlineWorker @{step='Select';inputPath='offline-session.json';targetOccurrenceKey=$targetKey}
  $offlineNext=Invoke-MathSecrResidentCommand $offlineWorker @{step='BeforeNext';inputPath='offline-session.json'}
  Assert-AssemblyTest ($offlineSelect.Valid -and $offlineNext.Valid) ('Offline simulator resident A2 failed: '+(ConvertTo-Json @($offlineSelect,$offlineNext) -Depth 80 -Compress))
  Stop-MathSecrResidentValidation $offlineWorker;$offlineWorker=$null
  Write-Output 'AssemblyPath A2 PASS (offline-dom-test assembler exit 0; resident Select and BeforeNext Valid=true).'
  $assembled=Invoke-AssemblyTest 'observation-b.json' 'judgment.json' 'target-b.json'
  Assert-AssemblyTest ($assembled.Code -eq 0 -and $assembled.Response.assembled -and $assembled.Response.resolution -ceq 'initial_selected') 'Synthetic assembly failed.'
  $target=Read-AssemblyJson (Join-Path $root 'target-b.json')
  Assert-AssemblyTest ($target.searchAttemptReceipt.attempts[0].chips[0].formulaCommitReceipt -ceq 'synthetic-retained-commit' -and
    $target.searchAttemptReceipt.attempts[0].chips[0].indexEvidenceReceipt -ceq 'synthetic-retained-index') 'Assembly discarded additional chip evidence.'
  # The actual DOM packet also satisfies the attempt contract before the final policy gate.
  $domSearch=Copy-MathSecrBenchmarkObject $target.searchAttemptReceipt
  $domSearch.attempts[0].observationReceipt=$dom
  $domSearch.attempts[0].resultCount=$dom.observations[-1].raw.result.count
  $domSearch.attempts[0].inspectedIds=$dom.observations[-1].raw.result.orderedIds
  $domContract=Test-MathSecrSearchAttemptContract $domSearch
  Assert-AssemblyTest ($domContract.Status -ceq 'exact-found' -and @($domContract.Errors).Count -eq 0) 'Simulator search attempt contract failed before selection policy.'
  Assert-AssemblyTest ($target.preparation.helperVersion -ceq 'assemble-target-v1' -and
    $target.bodyComparisonReceipt.comparedAtUtc -ceq $judgment.comparedAtUtc -and
    $target.bodyComparisonReceipt.comparedBy -ceq $judgment.comparator) 'Judgment identity/time were filled or changed.'
  $canonical=@(foreach ($name in @('roster','observation','judgment','candidateRender')) {
    $name+':'+$target.preparation.inputs.$name
  })
  $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($canonical -join [char]10)+[char]10))).ToLowerInvariant()
  Assert-AssemblyTest ($digest -ceq $target.preparation.inputSha256) 'Preparation input digest does not use the specified ordered LF framing.'

  $missing=Copy-MathSecrBenchmarkObject $judgment
  $missing.PSObject.Properties.Remove('comparator')
  $null=Write-MathSecrBenchmarkArtifact $missing $root 'judgment-missing.json'
  Assert-AssemblyRejection 'observation-b.json' 'judgment-missing.json' 'missing-target.json' 'judgment-missing:comparator'
  $missingTime=Copy-MathSecrBenchmarkObject $judgment
  $missingTime.PSObject.Properties.Remove('comparedAtUtc')
  $null=Write-MathSecrBenchmarkArtifact $missingTime $root 'judgment-no-time.json'
  Assert-AssemblyRejection 'observation-b.json' 'judgment-no-time.json' 'no-time-target.json' 'judgment-missing:comparedAtUtc'
  $invalidScale=Copy-MathSecrBenchmarkObject $judgment
  $invalidScale.sourceRenderScale=$true
  $null=Write-MathSecrBenchmarkArtifact $invalidScale $root 'judgment-scale.json'
  Assert-AssemblyRejection 'observation-b.json' 'judgment-scale.json' 'scale-target.json' 'judgment-invalid:sourceRenderScale'
  $mismatch=Copy-MathSecrBenchmarkObject $judgment
  $mismatch.comparison.bodyText='mismatch'
  $null=Write-MathSecrBenchmarkArtifact $mismatch $root 'judgment-mismatch.json'
  Assert-AssemblyRejection 'observation-b.json' 'judgment-mismatch.json' 'mismatch-target.json' 'body-not-exact'
  $tamper=Copy-MathSecrBenchmarkObject $observationB
  $tamper | Add-Member -NotePropertyName resultCount -NotePropertyValue 999
  $null=Write-MathSecrBenchmarkArtifact $tamper $root 'observation-count.json'
  Assert-AssemblyRejection 'observation-count.json' 'judgment.json' 'count-target.json' 'observation-rejected:attempt-1'
  $scope=Copy-MathSecrBenchmarkObject $observationB
  $scope.attempts[0].scope='candidate-recovery'
  $null=Write-MathSecrBenchmarkArtifact $scope $root 'observation-scope.json'
  Assert-AssemblyRejection 'observation-scope.json' 'judgment.json' 'scope-target.json' 'assembly-scope-unsupported:candidate-recovery'
  $roster=Read-AssemblyJson (Join-Path $root 'source-roster.json')
  $badRoster=Copy-MathSecrBenchmarkObject $roster
  $badRoster.targets[0].sourceBodyArtifact.sha256='0'*64
  $null=Write-MathSecrBenchmarkArtifact $badRoster $root 'roster-hash.json'
  Assert-AssemblyRejection 'observation-b.json' 'judgment.json' 'roster-target.json' 'roster-hash-mismatch' 'roster-hash.json'
  $duplicate=Copy-MathSecrBenchmarkObject $roster
  $duplicate.targets=@($duplicate.targets)+@($duplicate.targets[0])
  $null=Write-MathSecrBenchmarkArtifact $duplicate $root 'roster-duplicate.json'
  Assert-AssemblyRejection 'observation-b.json' 'judgment.json' 'duplicate-target.json' 'roster-row-missing' 'roster-duplicate.json'

  $helperOutput=@(& $pwsh -NoProfile -File (Join-Path $kit 'scripts/prepare_selection_evidence.ps1') -ProjectRoot $root -InputPath 'target-b.json' -OutPath 'prepared-target.json' 2>&1)
  Assert-AssemblyTest ($LASTEXITCODE -eq 0) ('Original preparation helper failed: '+($helperOutput -join ' '))
  $prepared=Read-AssemblyJson (Join-Path $root 'prepared-target.json')
  $plain=Copy-MathSecrBenchmarkObject $target
  $plain.PSObject.Properties.Remove('preparation');$prepared.PSObject.Properties.Remove('preparation')
  Assert-AssemblyTest ((ConvertTo-Json $plain -Depth 80 -Compress) -ceq (ConvertTo-Json $prepared -Depth 80 -Compress)) 'Assembled and original helper targets differ.'

  $session.snapshot.targets[0]=$target
  $session.snapshot.selectionBeforeNextIds=@($session.snapshot.targets.selectedId)
  $null=Write-MathSecrBenchmarkArtifact $session $root 'assembly-session.json'
  # Copy path and CreateNew helpers exactly, so resident commands keep CLI errors.
  foreach ($name in @('Resolve-ProductionCliPath','Write-ProductionCliNewFile')) {
    $bodies=@(foreach ($file in @('validate_production_step.ps1','validate_production_session.ps1')) {
      $tokens=$null;$errors=$null
      $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $kit "scripts/$file"),[ref]$tokens,[ref]$errors)
      Assert-AssemblyTest ($errors.Count -eq 0) "$file syntax invalid."
      $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true).Body.Extent.Text
    })
    Assert-AssemblyTest ($bodies[0] -ceq $bodies[1]) "$name body changed between CLI and resident validator."
  }
  $worker=Start-MathSecrResidentValidation $ProjectRoot $root
  $pidValue=$worker.Process.Id
  $broken=Invoke-MathSecrResidentCommand $worker -RawLine '{broken'
  Assert-AssemblyTest (-not $broken.Valid -and $null -eq $broken.Step) 'Broken JSON did not return one recoverable error.'
  $arrayCommand=Invoke-MathSecrResidentCommand $worker -RawLine '[{"step":"exit"}]'
  Assert-AssemblyTest (-not $arrayCommand.Valid -and $null -eq $arrayCommand.Step) 'A singleton JSON array was accepted as a command object.'
  $selected=Invoke-MathSecrResidentCommand $worker @{step='Select';inputPath='assembly-session.json';targetOccurrenceKey=$targetKey}
  Assert-AssemblyTest ($selected.Valid -and $worker.Process.Id -eq $pidValue) 'Resident Select failed or restarted.'
  $next=Invoke-MathSecrResidentCommand $worker @{step='BeforeNext';inputPath='assembly-session.json'}
  Assert-AssemblyTest $next.Valid 'Resident BeforeNext failed.'
  $cliOutput=@(& $pwsh -NoProfile -File (Join-Path $kit 'scripts/validate_production_step.ps1') -ProjectRoot $root -Step Select -InputPath 'assembly-session.json' -TargetOccurrenceKey $targetKey)
  Assert-AssemblyTest ($LASTEXITCODE -eq 0) 'CLI Select failed.'
  $cli=ConvertFrom-MathSecrContractJson ($cliOutput -join [Environment]::NewLine)
  Assert-AssemblyTest ((ConvertTo-Json $cli -Depth 80 -Compress) -ceq (ConvertTo-Json $selected -Depth 80 -Compress)) 'CLI and resident Select results differ.'
  $firstOutput=Invoke-MathSecrResidentCommand $worker @{step='Select';inputPath='assembly-session.json';targetOccurrenceKey=$targetKey;outPath='resident-output.json'}
  Assert-AssemblyTest $firstOutput.Valid 'Resident output creation failed.'
  $exists=Invoke-MathSecrResidentCommand $worker @{step='Select';inputPath='assembly-session.json';targetOccurrenceKey=$targetKey;outPath='resident-output.json'}
  Assert-AssemblyTest (-not $exists.Valid -and $exists.Error -ceq 'Output already exists; choose a new path.') 'Resident existing output error changed.'
  $cliExists=@(& $pwsh -NoProfile -File (Join-Path $kit 'scripts/validate_production_step.ps1') -ProjectRoot $root -Step Select -InputPath 'assembly-session.json' -TargetOccurrenceKey $targetKey -OutPath 'resident-output.json')
  Assert-AssemblyTest ($LASTEXITCODE -eq 1 -and (ConvertFrom-MathSecrContractJson ($cliExists -join [Environment]::NewLine)).Error -ceq $exists.Error) 'CLI existing output rejection differs.'
  # A resident process must reread files on each command, including after failures.
  $path=Join-Path $root 'assembly-session.json'
  $bytes=[IO.File]::ReadAllBytes($path)
  $session.snapshot.targets[0].bodyComparisonReceipt.verdict='mismatch'
  [IO.File]::WriteAllText($path,(ConvertTo-Json $session -Depth 80),[Text.UTF8Encoding]::new($false))
  $changed=Invoke-MathSecrResidentCommand $worker @{step='Select';inputPath='assembly-session.json';targetOccurrenceKey=$targetKey}
  Assert-AssemblyTest (-not $changed.Valid) 'Resident command reused a prior validation after file mutation.'
  [IO.File]::WriteAllBytes($path,$bytes)
  $restored=Invoke-MathSecrResidentCommand $worker @{step='Select';inputPath='assembly-session.json';targetOccurrenceKey=$targetKey}
  Assert-AssemblyTest $restored.Valid 'Resident rejection polluted the restored command.'
  Stop-MathSecrResidentValidation $worker;$worker=$null
  Assert-AssemblyTest ($null -eq (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) 'Resident process survived exit.'
  $worker=Start-MathSecrResidentValidation $ProjectRoot $root
  $noStep=Invoke-MathSecrResidentCommand $worker @{inputPath='assembly-session.json'}
  Assert-AssemblyTest (-not $noStep.Valid -and $null -eq $noStep.Step) 'Missing step did not return a recoverable error.'
  Stop-MathSecrResidentValidation $worker -Eof;$worker=$null
  Write-Output 'AssemblePipeline PASS (A1 mixed-surface rejection, A2 offline simulator Select/BeforeNext, synthetic Select/BeforeNext, four specified negatives, roster binding, helper/CLI identity, resident isolation/exit/EOF).'
} finally {
  if ($null -ne $offlineWorker) {Stop-MathSecrResidentValidation $offlineWorker}
  if ($null -ne $worker) {Stop-MathSecrResidentValidation $worker}
  if (Test-Path -LiteralPath $offlineRoot) {Remove-MathSecrOwnedBenchmarkRoot $offlineRoot}
  Remove-MathSecrOwnedBenchmarkRoot $root
}
