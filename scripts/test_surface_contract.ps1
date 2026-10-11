[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'perf/assembly_support.ps1')

function Assert-SurfaceTest {
  param([bool]$Condition,[string]$Message)
  if (-not $Condition) { throw $Message }
}
function Assert-SurfaceRejection {
  param([int]$Case,[string]$Surface,[scriptblock]$Action,[string]$Token)
  $message=$null
  try { $null=& $Action } catch { $message=$_.Exception.Message }
  Assert-SurfaceTest ($null -ne $message -and $message.Contains($Token,[StringComparison]::Ordinal)) "Negative $Case expected $Token; received: $message"
  [pscustomobject]@{kind='negative';case=$Case;surface=$Surface;status='PASS';token=$Token;error=$message} | ConvertTo-Json -Compress
}
function New-SurfacePreNextSession {
  param($Fixture)
  $session=New-MathSecrAssemblySession $Fixture
  # H=1 has already appended the final row. Characterize a fresh pre-next
  # selection of these same targets, without carrying that append operation.
  $session.snapshot.PSObject.Properties.Remove('editAppendReceipt')
  $session.snapshot.selectionBeforeNextIds=@($session.snapshot.targets.selectedId)
  return $session
}

$roots=[Collections.Generic.List[string]]::new()
$fixtures=@{}
try {
  foreach ($surface in $MathSecrSupportedSurfaces) {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-surface-'+[guid]::NewGuid().ToString('N'))
    $roots.Add($root)
    $fixture=New-MathSecrAppendHistoryFixture -ProblemCount 3 -HistoryDepth 1 -OutRoot $root -Surface $surface
    $fixtures[$surface]=$fixture
    $preNext=New-SurfacePreNextSession $fixture
    foreach ($step in @('Select','BeforeNext','AfterReload')) {
      $arguments=@{Step=$step;ProjectRoot=$root;InputObject=$preNext}
      if ($step -ceq 'Select') { $arguments.TargetOccurrenceKey=$preNext.snapshot.targets[0].occurrenceKey }
      if ($step -ceq 'AfterReload') { $arguments.InputObject=$fixture.Session }
      $result=Invoke-MathSecrProductionStep @arguments
      Assert-SurfaceTest $result.Valid "$surface $step rejected."
      if ($step -ceq 'AfterReload') {
        $lint=Invoke-MathSecrTypedUserSummaryLint -Text $result.UserSummary -Session $fixture.Session -ProjectRoot $root
        Assert-SurfaceTest ($lint.PaperUrl -ceq $fixture.Session.paper.url -and $lint.SuccessCount -eq 3) "$surface typed summary lint rejected."
      }
      [pscustomobject]@{kind='positive';surface=$surface;step=$step;status='PASS'} | ConvertTo-Json -Compress
    }
  }

  $fixture=$fixtures['codex-iab']; $root=$fixture.Root
  $session=Copy-MathSecrBenchmarkObject $fixture.Session
  $session.surfaceIdentity.browserFamily='aside'
  Assert-SurfaceRejection 1 codex-iab { Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root } 'surface-browser-family'

  $session=Copy-MathSecrBenchmarkObject $fixture.Session
  $capture=ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath (Join-Path $root $session.persistedCardObservationArtifact.path) -Raw -Encoding UTF8)
  $capture.surface='aside-repl'
  $session.persistedCardObservationArtifact=Write-MathSecrBenchmarkArtifact $capture $root 'mixed-capture.json'
  Assert-SurfaceRejection 2 codex-iab { Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root } 'Production validation: Persisted-card capture schema or surface is invalid.'

  $session=Copy-MathSecrBenchmarkObject $fixture.Session
  $session.surfaceIdentity.surface='chrome'
  Assert-SurfaceRejection 3 chrome { Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root } 'surface-unsupported'

  $fixture=$fixtures['aside-repl']; $root=$fixture.Root
  $session=New-SurfacePreNextSession $fixture
  $session.snapshot.targets[0].searchAttemptReceipt.attempts[0].observationReceipt.submission.surface='offline-dom-test'
  Assert-SurfaceRejection 4 aside-repl { Invoke-MathSecrProductionStep -Step Select -InputObject $session -ProjectRoot $root -TargetOccurrenceKey $session.snapshot.targets[0].occurrenceKey } 'surface-mismatch'

  $fixture=$fixtures['offline-dom-test']; $root=$fixture.Root
  $session=Copy-MathSecrBenchmarkObject $fixture.Session
  $session.paper.url='https://www.mathsecr.com/mypaper/123'
  Assert-SurfaceRejection 5 offline-dom-test { Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root } 'surface-url'

  $fixture=$fixtures['codex-iab']; $root=$fixture.Root
  $session=Copy-MathSecrBenchmarkObject $fixture.Session
  $session.snapshot | Add-Member -NotePropertyName asideRepl -NotePropertyValue ([pscustomobject]@{available=$true;paperVerified=$true;nonAsideReplLiveManipulation=$false})
  Assert-SurfaceRejection 6 codex-iab { Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root } 'surface-mismatch'

  $fixture=$fixtures['codex-chrome-ext']; $root=$fixture.Root
  $session=Copy-MathSecrBenchmarkObject $fixture.Session
  $session.snapshot.editAppendReceipt.surface='codex-iab'
  Assert-SurfaceRejection 7 codex-chrome-ext { Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root } 'edit-append-schema'

  $fixture=$fixtures['codex-iab']; $root=$fixture.Root
  $session=Copy-MathSecrBenchmarkObject $fixture.Session
  $prior=ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath (Join-Path $root $session.snapshot.editAppendReceipt.priorSessionArtifact.path) -Raw -Encoding UTF8)
  $prior.PSObject.Properties.Remove('surfaceIdentity')
  $session.snapshot.editAppendReceipt.priorSessionArtifact=Write-MathSecrBenchmarkArtifact $prior $root 'undeclared-prior.json'
  Assert-SurfaceRejection 8 codex-iab { Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $root } 'surface-mismatch'

  $fixture=$fixtures['aside-repl']; $root=$fixture.Root
  $session=New-SurfacePreNextSession $fixture
  $target=$session.snapshot.targets[0]
  $second=Copy-MathSecrBenchmarkObject $target.searchAttemptReceipt.attempts[0]
  $second.attemptId='nonwinning-attempt';$second.scope='candidate-recovery';$second.exactFound=$false;$second.exactMatchIds=@()
  $second.removedChips=@(foreach ($chip in $second.chips) { [pscustomobject]@{value=$chip.value;removalReceipt='synthetic-removal'} })
  $second.observationReceipt=New-MathSecrBenchmarkObservation $second.attemptId $target.selectedId
  $target.searchAttemptReceipt.attempts=@($target.searchAttemptReceipt.attempts)+@($second)
  $control=Invoke-MathSecrProductionStep -Step Select -InputObject $session -ProjectRoot $root -TargetOccurrenceKey $target.occurrenceKey
  Assert-SurfaceTest $control.Valid 'Nonwinning attempt control was invalid before the surface mutation.'
  $second.observationReceipt.submission.surface='codex-iab'
  Assert-SurfaceRejection 9 aside-repl { Invoke-MathSecrProductionStep -Step Select -InputObject $session -ProjectRoot $root -TargetOccurrenceKey $target.occurrenceKey } 'surface-mismatch'
  $state=Invoke-MathSecrStateMachine -Snapshot $session.snapshot -Phase BeforeNext -ProjectRoot $root
  Assert-SurfaceTest ($state.Status -ceq '차단' -and $state.EvidenceErrors -ccontains 'surface-mismatch') 'State machine ignored a nonwinning mixed-surface attempt.'

  # Contract edges beyond the required matrix: strict identity, URI and safe
  # optional probe artifacts. Every artifact remains under an owned temp root.
  foreach ($invalidSurface in @('ASIDE-REPL','chrome',1,$null)) {
    Assert-SurfaceTest (-not (Test-MathSecrSupportedSurface $invalidSurface)) 'Unsupported or nonstring surface accepted.'
  }
  foreach ($badUrl in @('http://www.mathsecr.com/mypaper/123','https://mathsecr.com/mypaper/123','https://www.mathsecr.com/mypaper/abc','https://www.mathsecr.com/mypaper/123/')) {
    Assert-SurfaceTest (-not (Test-MathSecrSurfacePaperUrl aside-repl $badUrl)) "Invalid live paper URL accepted: $badUrl"
  }
  foreach ($badUrl in @('file://otherhost/test-fixtures/iab-simulator/index.html','file:///test-fixtures/other/index.html','https://www.mathsecr.com/mypaper/123')) {
    Assert-SurfaceTest (-not (Test-MathSecrSurfacePaperUrl offline-dom-test $badUrl)) "Invalid offline paper URL accepted: $badUrl"
  }
  $fixture=$fixtures['codex-iab']; $root=$fixture.Root
  foreach ($field in @('profileOrSessionId','tabId','observedAtUtc','schemaVersion')) {
    $identity=Copy-MathSecrBenchmarkObject $fixture.Session.surfaceIdentity
    $identity.$field=switch ($field) { 'observedAtUtc' {'2026-10-11T00:00:00+00:00'}; 'schemaVersion' {$true}; default {' padded '} }
    $result=Test-MathSecrSurfaceIdentityReceipt -Receipt $identity -PaperUrl $fixture.Session.paper.url
    Assert-SurfaceTest (-not $result.Valid -and $result.Errors -ccontains 'surface-identity-invalid') "Invalid identity $field accepted."
  }
  # The mandated state artifact resolver retains its image-extension allowlist.
  $probe=Copy-MathSecrBenchmarkObject $fixture.Session.sourceTargets[0].sourceBodyArtifact
  $identity=Copy-MathSecrBenchmarkObject $fixture.Session.surfaceIdentity
  $identity | Add-Member -NotePropertyName probeArtifact -NotePropertyValue $probe
  $context=Enter-MathSecrValidationContext -ProjectRoot $root
  try {
    foreach ($index in 1..2) {
      $result=Test-MathSecrSurfaceIdentityReceipt -Receipt $identity -PaperUrl $identity.url -ProjectRoot $root -Context $context
      Assert-SurfaceTest $result.Valid 'Valid optional probe rejected.'
    }
    Assert-SurfaceTest ($context.ArtifactCache.Count -eq 1) 'Optional probe did not reuse the artifact cache.'
    $identity.probeArtifact.sha256='0'*64
    $result=Test-MathSecrSurfaceIdentityReceipt -Receipt $identity -PaperUrl $identity.url -ProjectRoot $root -Context $context
    Assert-SurfaceTest (-not $result.Valid -and $result.Errors -ccontains 'surface-identity-invalid') 'Changed probe hash accepted.'
    $identity.probeArtifact.path='../source-1.png'
    $result=Test-MathSecrSurfaceIdentityReceipt -Receipt $identity -PaperUrl $identity.url -ProjectRoot $root -Context $context
    Assert-SurfaceTest (-not $result.Valid -and $result.Errors -ccontains 'surface-identity-invalid') 'Unsafe probe path accepted.'
    $metadata=[pscustomobject]@{metadataRescue=[pscustomobject]@{buckets=@([pscustomobject]@{observationReceipt=(New-MathSecrBenchmarkObservation extra candidate -Surface codex-chrome-ext)})}}
    Assert-SurfaceTest (-not (Test-MathSecrTargetObservationSurfaces $metadata codex-iab)) 'A metadata rescue observation crossed the surface boundary.'
  } finally { Exit-MathSecrValidationContext -Context $context }
  Write-Output 'SurfaceContract PASS'
} finally {
  foreach ($ownedRoot in $roots) { if (Test-Path -LiteralPath $ownedRoot) { Remove-MathSecrOwnedBenchmarkRoot $ownedRoot } }
}
