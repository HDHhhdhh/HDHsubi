param([string]$ProjectRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'production_validation.ps1')
. (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/body-comparison/synthetic_selection_test_support.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-production-test-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$assertions=0
function Assert-ProductionTest {param([bool]$Condition,[string]$Message);if(-not $Condition){throw $Message};$script:assertions++}
function Copy-ProductionTest {param($Value);ConvertFrom-MathSecrContractJson (ConvertTo-Json -InputObject $Value -Depth 80)}
function Write-ProductionTest {param($Value,[string]$Path);[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 80),[Text.UTF8Encoding]::new($false))}
function Expect-ProductionRejection {
  param([scriptblock]$Action,[string]$Name,[string]$Fragment)
  $rejected=$false
  try {$null=& $Action} catch {$rejected=$true;if($Fragment){Assert-ProductionTest ($_.Exception.Message.Contains($Fragment)) "$Name rejected for the wrong reason: $($_.Exception.Message)"}}
  Assert-ProductionTest $rejected "$Name was accepted."
}
function New-ProductionTarget {
  param([string]$Number,[string]$CandidateId)
  $key='source-row-'+$Number;$id=if($CandidateId){$CandidateId}else{'candidate-'+$Number};$attempt='attempt-'+$Number
  $obs=New-MathSecrSyntheticSelectionObservation -AttemptId $attempt -Chips @('본문','조건') -ResultCount 1 -OrderedIds @($id)
  $obs.submission.url='https://www.mathsecr.com/mypaper/123'
  $obs.beforeSubmit.raw.url=$obs.submission.url
  foreach($read in $obs.observations){$read.raw.url=$obs.submission.url}
  $hash=(Get-FileHash -LiteralPath (Join-Path $testRoot 'source.png')).Hash.ToLowerInvariant()
  return [pscustomobject]@{
    number=$Number;occurrenceKey=$key;initial='exact';selectedId=$id
    sourceBodyArtifact=[pscustomobject]@{path='source.png';sha256=$hash}
    searchAttemptReceipt=[pscustomobject]@{
      targetBinding=[pscustomobject]@{sourceProblemNumber=$Number;occurrenceKey=$key};outcome='exact'
      literalEvidence=[pscustomobject]@{body=@('본문','조건');printedMetadata=@();visibleUiMetadata=@();formula=@()}
      attempts=@([pscustomobject]@{
        attemptId=$attempt;scope='initial-scope';phase='initial'
        chips=@([pscustomobject]@{value='본문';provenance='literal-body';evidenceReceipt='synthetic-body'},[pscustomobject]@{value='조건';provenance='literal-body';evidenceReceipt='synthetic-condition'})
        submitted=$true;freshResultVerified=$true;resultCount=1;exactFound=$true;inspectedIds=@($id);exactMatchIds=@($id)
        resetBefore=$true;clearReceipt='synthetic-clean';removedChips=@();observationReceipt=$obs
      })
      candidateRecoveryEvidence=[pscustomobject]@{routes=@();coverage=@()}
      commonChips=@('본문','조건');exactMatchIds=@($id);literalOnlyLadderCompleted=$true;resetBackoffPerformed=$true;candidateRecoveryCompleted=$false;completeCoverageVerified=$false
    }
    bodyComparisonReceipt=[pscustomobject]@{
      sourceProblemNumber=$Number;occurrenceKey=$key;candidateId=$id;searchAttemptId=$attempt;policyVersion='body-only-v1';verdict='exact'
      sourceRenderArtifact='source.png';sourceRenderSha256=$hash;candidateRenderArtifact='candidate.png';candidateRenderSha256=$hash
      sourceRenderScale=2;candidateRenderScale=1
      comparison=[pscustomobject]@{bodyText='match';conditions='match';formulas='match';figures='not-present';pointLabels='not-present';requiredValue='match';internalStatements='not-present'}
      comparedBy='synthetic-offline-contract-test';comparedAtUtc='2026-09-05T00:00:05.000Z';unresolvedGlyphs=$false
    }
  }
}
try {
  # Actual bytes are used for identity checks. Synthetic judgments are not a
  # visual oracle and this test performs no MathSecr browser manipulation.
  $png=[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
  [IO.File]::WriteAllBytes((Join-Path $testRoot 'source.png'),$png)
  [IO.File]::WriteAllBytes((Join-Path $testRoot 'candidate.png'),$png)
  Add-Type -AssemblyName System.Drawing
  $foreignImage=[Drawing.Bitmap]::new(2,2)
  try {$foreignImage.SetPixel(0,0,[Drawing.Color]::Red);$foreignImage.Save((Join-Path $testRoot 'foreign-source.png'),[Drawing.Imaging.ImageFormat]::Png)} finally {$foreignImage.Dispose()}
  Copy-Item -LiteralPath (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/production-validation/source-roster.json') -Destination (Join-Path $testRoot 'source-roster.json')
  $roster=ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath (Join-Path $testRoot 'source-roster.json') -Raw)
  $targets=@(1..5 | ForEach-Object {New-ProductionTarget ([string]$_)})
  $ids=@($targets | ForEach-Object {$_.selectedId})
  $dbs=@('서울특별시교육청 > 대수','2026년 교육청 > 대수','한국교육과정평가원 > 미적분','2026년(2027학년도) EBS 수능특강 수학2 > 레벨2','2026 블랙라벨 공통수학1 > 고난도')
  $cards=@();for($i=0;$i -lt 5;$i++){$cards+=[pscustomobject]@{problemId=$ids[$i];occurrenceKey=$targets[$i].occurrenceKey;rawVisibleDbName=$dbs[$i]}}
  $capture=[pscustomobject]@{
    schemaVersion=1;captureId='synthetic-persisted-read';collectorVersion='synthetic-offline-contract-v1'
    surface='aside-repl';capturedAtUtc='2026-09-05T00:00:09.000Z';url='https://www.mathsecr.com/mypaper/123'
    title='Synthetic structural fixture';readEvidenceId='synthetic-final-card-read'
    cards=@($cards | ForEach-Object {[pscustomobject]@{problemId=$_.problemId;rawVisibleDbName=$_.rawVisibleDbName}})
  }
  $capturePath=Join-Path $testRoot 'persisted-capture.json';Write-ProductionTest $capture $capturePath
  $session=[pscustomobject]@{
    schemaVersion=1;sessionId='synthetic-production-v1';paper=[pscustomobject]@{name='합성 구조 검증';url='https://www.mathsecr.com/mypaper/123'}
    sourceTargets=$roster.targets;sourceRosterArtifact=[pscustomobject]@{path='source-roster.json';sha256=(Get-FileHash -LiteralPath (Join-Path $testRoot 'source-roster.json')).Hash}
    snapshot=[pscustomobject]@{
      sourcePresent=$true;asideRepl=[pscustomobject]@{available=$true;paperVerified=$true;nonAsideReplLiveManipulation=$false}
      cleanStateVerified=$true;scope=[pscustomobject]@{verified=$true;unexpectedBroadResult=$false;resultCount=1}
      targets=$targets;selectionBeforeNextIds=$ids;nextClicked=$true
      edit=[pscustomobject]@{draftIds=$ids;oldIds=@();recovery='not_needed'}
      persistence=[pscustomobject]@{freshReloadVerified=$true;ids=$ids};issueClicked=$false
    }
    persistedCards=$cards;failureReportPdf='없음'
    persistedCardObservationArtifact=[pscustomobject]@{path='persisted-capture.json';sha256=(Get-FileHash -LiteralPath $capturePath).Hash}
  }
  $inputBytes=ConvertTo-Json -InputObject $session -Depth 80 -Compress
  $select=Invoke-MathSecrProductionStep -Step Select -InputObject $session -TargetOccurrenceKey 'source-row-1' -ProjectRoot $testRoot
  Assert-ProductionTest ($select.Valid -and $select.CandidateId -ceq 'candidate-1') 'Valid Select failed.'
  foreach($attack in @(
    @{name='body mismatch';change={param($v)$v.bodyComparisonReceipt.comparison.formulas='mismatch'}},
    @{name='wrong candidate';change={param($v)$v.bodyComparisonReceipt.candidateId='foreign'}},
    @{name='IAB mutation';change={param($v)$v.searchAttemptReceipt.attempts[0].observationReceipt.submission.surface='iab'}},
    @{name='missing search';change={param($v)$v.PSObject.Properties.Remove('searchAttemptReceipt')}},
    @{name='stale observation';change={param($v)$v.searchAttemptReceipt.attempts[0].observationReceipt.observations[-1].raw.result.observedSubmitId='foreign'}},
    @{name='not-started resolution override';change={param($v)$v.initial='not-started';$v | Add-Member resolution 'initial_selected'}},
    @{name='array route coercion';change={param($v)$v.initial=@('exact')}},
    @{name='case route coercion';change={param($v)$v.initial='EXACT'}}
  )){$value=Copy-ProductionTest $session;& $attack.change $value.snapshot.targets[0];Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step Select -InputObject $value -TargetOccurrenceKey 'source-row-1' -ProjectRoot $testRoot} $attack.name}
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step Select -InputObject $targets[0] -TargetOccurrenceKey 'source-row-1' -ProjectRoot $testRoot} 'unbound standalone target' 'versioned session'
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step Select -InputObject $session -TargetOccurrenceKey 'foreign-row' -ProjectRoot $testRoot} 'foreign selection occurrence' 'exactly once'
  $transplanted=Copy-ProductionTest $session
  $transplanted.snapshot.targets[0].sourceBodyArtifact.path='foreign-source.png'
  $transplanted.snapshot.targets[0].sourceBodyArtifact.sha256=(Get-FileHash -LiteralPath (Join-Path $testRoot 'foreign-source.png')).Hash
  $transplanted.snapshot.targets[0].bodyComparisonReceipt.sourceRenderArtifact='foreign-source.png'
  $transplanted.snapshot.targets[0].bodyComparisonReceipt.sourceRenderSha256=$transplanted.snapshot.targets[0].sourceBodyArtifact.sha256
  $underlyingSearch=Test-MathSecrSelectedSearchReceipt $transplanted.snapshot.targets[0] 'initial_selected'
  $underlyingBody=Test-MathSecrBodyComparisonReceipt -Receipt $transplanted.snapshot.targets[0].bodyComparisonReceipt -Target $transplanted.snapshot.targets[0] -ProjectRoot $testRoot -InspectedIds $underlyingSearch.InspectedIds -AttemptId $underlyingSearch.AttemptId
  Assert-ProductionTest ($underlyingSearch.Valid -and $underlyingBody.Valid) 'Transplant probe did not reproduce the former unbound receipt gap.'
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step Select -InputObject $transplanted -TargetOccurrenceKey 'source-row-1' -ProjectRoot $testRoot} 'source receipt transplant' 'fixed original roster'
  $result=Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $testRoot
  Assert-ProductionTest ($result.Valid -and $result.ReportProjection.SuccessCount -eq 5) 'Valid AfterReload failed.'
  Assert-ProductionTest ($result.ReportProjection.Sources.Count -eq 3 -and $result.ReportProjection.Sources[0].Name -ceq '교육청' -and $result.ReportProjection.Sources[0].Count -eq 2 -and $result.ReportProjection.Sources[1].Name -ceq '평가원' -and $result.ReportProjection.Sources[2].Name -ceq 'EBS 수능특강 수학2') 'Source normalization/top3/tie order differs.'
  Assert-ProductionTest ((ConvertTo-Json -InputObject $session -Depth 80 -Compress) -ceq $inputBytes) 'Production validation mutated actual input facts.'
  $null=Invoke-MathSecrTypedUserSummaryLint -Text $result.UserSummary -Session $session -ProjectRoot $testRoot
  Expect-ProductionRejection {Invoke-MathSecrTypedUserSummaryLint -Text ($result.UserSummary -replace '교육청 — 2문제','임의 출처 — 2문제') -Session $session -ProjectRoot $testRoot} 'source tamper' 'source name/count/order'
  $swappedSummary=$result.UserSummary.Replace('평가원 — 1문제','temporary-source — 1문제').Replace('EBS 수능특강 수학2 — 1문제','평가원 — 1문제').Replace('temporary-source — 1문제','EBS 수능특강 수학2 — 1문제')
  Expect-ProductionRejection {Invoke-MathSecrTypedUserSummaryLint -Text $swappedSummary -Session $session -ProjectRoot $testRoot} 'source tie-order tamper' 'source name/count/order'
  $wrongTotal=$result.UserSummary.Replace('5문제/5문제','6문제/6문제').Replace('0문제/5문제','0문제/6문제')
  Expect-ProductionRejection {Invoke-MathSecrTypedUserSummaryLint -Text $wrongTotal -Session $session -ProjectRoot $testRoot} 'original-count tamper' 'counts differ'
  foreach($attack in @(
    @{name='snapshot row missing';change={param($v)$v.snapshot.targets=@($v.snapshot.targets[0..3])}},
    @{name='both rosters truncated';change={param($v)$v.sourceTargets=@($v.sourceTargets[0..3]);$v.snapshot.targets=@($v.snapshot.targets[0..3])}},
    @{name='roster hash';change={param($v)$v.sourceRosterArtifact.sha256='0'*64}},
    @{name='source crop replaced';change={param($v)$v.snapshot.targets[0].sourceBodyArtifact.path='candidate.png';$v.snapshot.targets[0].bodyComparisonReceipt.sourceRenderArtifact='candidate.png'}},
    @{name='original order';change={param($v)$v.snapshot.targets=@($v.snapshot.targets[1],$v.snapshot.targets[0],$v.snapshot.targets[2],$v.snapshot.targets[3],$v.snapshot.targets[4])}},
    @{name='persist decreased';change={param($v)$v.snapshot.persistence.ids=@($v.snapshot.persistence.ids[0..3]);$v.persistedCards=@($v.persistedCards[0..3])}},
    @{name='persist card order';change={param($v)$v.persistedCards=@($v.persistedCards[1],$v.persistedCards[0],$v.persistedCards[2],$v.persistedCards[3],$v.persistedCards[4])}},
    @{name='raw DB absent';change={param($v)$v.persistedCards[0].rawVisibleDbName=''}},
    @{name='raw DB changed';change={param($v)$v.persistedCards[0].rawVisibleDbName='임의 출처 > 대수'}},
    @{name='capture absent';change={param($v)$v.PSObject.Properties.Remove('persistedCardObservationArtifact')}},
    @{name='capture hash changed';change={param($v)$v.persistedCardObservationArtifact.sha256='0'*64}},
    @{name='wrong paper';change={param($v)$v.paper.url='https://www.mathsecr.com/mypaper/124'}},
    @{name='issue clicked';change={param($v)$v.snapshot.issueClicked=$true}}
  )){$value=Copy-ProductionTest $session;& $attack.change $value;Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} $attack.name}
  $captureIndex=0
  foreach($attack in @(
    @{name='capture IAB';change={param($v)$v.surface='iab'}},
    @{name='capture URL';change={param($v)$v.url='https://www.mathsecr.com/mypaper/124'}},
    @{name='capture timestamp type';change={param($v)$v.capturedAtUtc=9}},
    @{name='capture timestamp invalid';change={param($v)$v.capturedAtUtc='2026-09-31T00:00:09.000Z'}},
    @{name='capture read provenance missing';change={param($v)$v.PSObject.Properties.Remove('readEvidenceId')}},
    @{name='capture truncated';change={param($v)$v.cards=@($v.cards[0..3])}},
    @{name='capture card order';change={param($v)$v.cards=@($v.cards[1],$v.cards[0],$v.cards[2],$v.cards[3],$v.cards[4])}},
    @{name='capture raw DB type';change={param($v)$v.cards[0].rawVisibleDbName=1}}
  )){
    $badCapture=Copy-ProductionTest $capture;& $attack.change $badCapture
    $relative="bad-capture-$captureIndex.json";$path=Join-Path $testRoot $relative;Write-ProductionTest $badCapture $path
    $value=Copy-ProductionTest $session;$value.persistedCardObservationArtifact.path=$relative;$value.persistedCardObservationArtifact.sha256=(Get-FileHash -LiteralPath $path).Hash
    Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} $attack.name
    $captureIndex++
  }
  $before=Copy-ProductionTest $session;$before.snapshot.nextClicked=$false;$before.snapshot.PSObject.Properties.Remove('edit');$before.snapshot.PSObject.Properties.Remove('persistence')
  $gate=Invoke-MathSecrProductionStep -Step BeforeNext -InputObject $before -ProjectRoot $testRoot
  Assert-ProductionTest ($gate.StateResult.CanNextStep -and $gate.StateResult.Status -ceq 'ready-for-next') 'BeforeNext demanded future edit/persist facts.'
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step BeforeNext -InputObject $session -ProjectRoot $testRoot} 'future facts before next'
  $partial=Copy-ProductionTest $session
  $partial.snapshot | Add-Member requestedAction 'partial-save'
  $partial.snapshot.targets[4]=[pscustomobject]@{number='5';occurrenceKey='source-row-5';initial='not-started';sourceBodyArtifact=$roster.targets[4].sourceBodyArtifact}
  $partial.snapshot.selectionBeforeNextIds=@($ids[0..3]);$partial.snapshot.edit.draftIds=@($ids[0..3]);$partial.snapshot.persistence.ids=@($ids[0..3]);$partial.persistedCards=@($cards[0..3])
  $partialCapture=Copy-ProductionTest $capture;$partialCapture.cards=@($capture.cards[0..3])
  $partialCapturePath=Join-Path $testRoot 'partial-capture.json';Write-ProductionTest $partialCapture $partialCapturePath
  $partial.persistedCardObservationArtifact.path='partial-capture.json';$partial.persistedCardObservationArtifact.sha256=(Get-FileHash -LiteralPath $partialCapturePath).Hash
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $partial -ProjectRoot $testRoot} 'missing failure crop PDF' 'PDF'
  $pdf=Join-Path $testRoot 'failed.pdf';$manifest=Join-Path $testRoot 'failure-manifest.json'
  Write-ProductionTest ([pscustomobject]@{title='Synthetic failed report';source='fixture.pdf';items=@([pscustomobject]@{problem_number=5;image='source.png';crop=@(0,0,1,1)})}) $manifest
  $output=@(& python (Join-Path $PSScriptRoot 'create_failed_problem_report.py') --manifest $manifest --output $pdf --project-root $testRoot --regular-font 'C:\Windows\Fonts\malgun.ttf' --bold-font 'C:\Windows\Fonts\malgunbd.ttf' 2>&1)
  Assert-ProductionTest ($LASTEXITCODE -eq 0) "Synthetic failure PDF generation failed: $($output -join ' ')."
  $partial.failureReportPdf=$pdf
  $saved=Invoke-MathSecrProductionStep -Step AfterReload -InputObject $partial -ProjectRoot $testRoot
  Assert-ProductionTest ($saved.ReportProjection.Status -ceq '부분 완료' -and $saved.ReportProjection.SuccessCount -eq 4 -and $saved.ReportProjection.FailureCount -eq 1 -and $saved.ReportProjection.UnresolvedSourceNumbers -ccontains '5' -and $saved.ReportProjection.ClosedMissedSourceNumbers.Count -eq 0) 'Partial-save changed not-started into a closed miss.'
  Assert-ProductionTest ($partial.snapshot.targets[4].PSObject.Properties['searchAttemptReceipt'] -eq $null) 'Partial-save fabricated a miss receipt.'
  $null=Invoke-MathSecrTypedUserSummaryLint -Text $saved.UserSummary -Session $partial -ProjectRoot $testRoot
  # Edit append has its own observed delta. Historical FirstNext IDs must not
  # be rewritten to the later whole bundle. All judgments here are synthetic.
  function Write-AppendTestArtifact {
    param($Value,[string]$Name)
    $path=Join-Path $testRoot $Name;Write-ProductionTest $Value $path
    return [pscustomobject]@{path=$Name;sha256=(Get-FileHash -LiteralPath $path).Hash}
  }
  $priorReceipt=Write-AppendTestArtifact $partial 'append-prior-session.json'
  $beforeAppend=[pscustomobject]@{capturedAtUtc='2026-09-05T00:00:10.000Z';url=$session.paper.url;priorEditIds=@($ids[0..3]);modalSelectedIds=@($ids[4]);action='추가'}
  $afterAppend=[pscustomobject]@{capturedAtUtc='2026-09-05T00:00:12.000Z';url=$session.paper.url;draftIds=$ids}
  $syntheticExecution=[pscustomobject]@{schemaVersion=1;truthScope='offline-contract';records=@(
    [pscustomobject]@{key='synthetic-add-command';value="const action='추가';page.click();"},
    [pscustomobject]@{key='synthetic-add-result';value=[pscustomobject]@{output='SYNTHETIC_APPEND_COMPLETED: fixture'}},
    [pscustomobject]@{key='synthetic-confirm-command';value="const controlName='확인';page.click();"},
    [pscustomobject]@{key='synthetic-confirm-result';value=[pscustomobject]@{output='SYNTHETIC_CONFIRM_COMPLETED: fixture'}}
  )}
  $executionReceipt=Write-AppendTestArtifact $syntheticExecution 'append-execution.json'
  $beforeReceipt=Write-AppendTestArtifact $beforeAppend 'append-before.json'
  $afterReceipt=Write-AppendTestArtifact $afterAppend 'append-after.json'
  $addAction=[pscustomobject]@{actionId='synthetic-add';surface='aside-repl';startedAtUtc=$beforeAppend.capturedAtUtc;completedAtUtc=$afterAppend.capturedAtUtc;timingBasis='observation-window';url=$session.paper.url;controlName='추가';action='click';evidenceArtifact=$executionReceipt;afterObservationArtifact=$afterReceipt;executionBinding=[pscustomobject]@{commandRecordKey='synthetic-add-command';resultRecordKey='synthetic-add-result';completionMarker='SYNTHETIC_APPEND_COMPLETED:'}}
  $syntheticConfirmBefore=[pscustomobject]@{capturedAtUtc='2026-09-05T00:00:12.500Z';url=$session.paper.url;draftIds=$ids;controlName='확인';surface='aside-repl'}
  $syntheticConfirmAfter=[pscustomobject]@{schemaVersion=1;capturedAtUtc='2026-09-05T00:00:14.500Z';url=$session.paper.url;draftIds=$ids;controlName='확인';surface='aside-repl';action='click';startedAtUtc='2026-09-05T00:00:13.000Z';completedAtUtc='2026-09-05T00:00:14.000Z'}
  $confirmAction=[pscustomobject]@{actionId='synthetic-confirm';surface='aside-repl';startedAtUtc=$syntheticConfirmAfter.startedAtUtc;completedAtUtc=$syntheticConfirmAfter.completedAtUtc;timingBasis='recorded-execution';url=$session.paper.url;controlName='확인';action='click';evidenceArtifact=$executionReceipt;executionBinding=[pscustomobject]@{commandRecordKey='synthetic-confirm-command';resultRecordKey='synthetic-confirm-result';completionMarker='SYNTHETIC_CONFIRM_COMPLETED:'};beforeObservationArtifact=(Write-AppendTestArtifact $syntheticConfirmBefore 'append-confirm-before.json');afterObservationArtifact=(Write-AppendTestArtifact $syntheticConfirmAfter 'append-confirm-after.json')}
  $draftAppend=[pscustomobject]@{capturedAtUtc='2026-09-05T00:00:15.000Z';url=$session.paper.url;draftIds=$ids}
  $appended=Copy-ProductionTest $session
  $appended.snapshot.selectionBeforeNextIds=@($ids[0..3])
  $appended.snapshot | Add-Member requestedAction 'partial-save'
  $appended.snapshot | Add-Member editAppendReceipt ([pscustomobject]@{
    schemaVersion=1;appendId='synthetic-append-1';surface='aside-repl';priorSessionArtifact=$priorReceipt;beforeObservationArtifact=$beforeReceipt
    deltaTargets=@([pscustomobject]@{sourceProblemNumber='5';occurrenceKey='source-row-5';problemId=$ids[4]})
    addActionArtifact=(Write-AppendTestArtifact $addAction 'append-add-action.json');confirmActionArtifact=(Write-AppendTestArtifact $confirmAction 'append-confirm-action.json')
    draftObservationArtifact=(Write-AppendTestArtifact $draftAppend 'append-draft.json')
  })
  $appendCapture=Copy-ProductionTest $capture;$appendCapture.captureId='synthetic-appended-persisted';$appendCapture.readEvidenceId='synthetic-appended-read';$appendCapture.capturedAtUtc='2026-09-05T00:00:16.000Z'
  $appended.persistedCardObservationArtifact=Write-AppendTestArtifact $appendCapture 'append-persisted.json'
  $appendInput=ConvertTo-Json -InputObject $appended -Depth 100 -Compress
  $appendResult=Invoke-MathSecrProductionStep -Step AfterReload -InputObject $appended -ProjectRoot $testRoot
  Assert-ProductionTest ($appendResult.ReportProjection.SuccessCount -eq 5 -and (Test-OrderedIdsEqual $ids $appendResult.StateResult.SelectedIds) -and (Test-OrderedIdsEqual $ids[0..3] $appendResult.StateResult.SelectionBeforeNextIds)) 'Edit append failed or rewrote historical FirstNext.'
  Assert-ProductionTest ((ConvertTo-Json -InputObject $appended -Depth 100 -Compress) -ceq $appendInput) 'Edit append validation mutated historical observations.'
  $recordedAdd=Copy-ProductionTest $addAction
  $recordedAdd.timingBasis='recorded-execution';$recordedAdd.startedAtUtc='2026-09-05T00:00:10.500Z';$recordedAdd.completedAtUtc='2026-09-05T00:00:11.500Z'
  $recordedAddAfter=Copy-ProductionTest $afterAppend
  $recordedAddAfter | Add-Member schemaVersion 1;$recordedAddAfter | Add-Member surface 'aside-repl';$recordedAddAfter | Add-Member controlName '추가';$recordedAddAfter | Add-Member action 'click'
  $recordedAddAfter | Add-Member startedAtUtc $recordedAdd.startedAtUtc;$recordedAddAfter | Add-Member completedAtUtc $recordedAdd.completedAtUtc
  $recordedAdd.afterObservationArtifact=Write-AppendTestArtifact $recordedAddAfter 'append-recorded-add-after.json'
  $value=Copy-ProductionTest $appended;$value.snapshot.editAppendReceipt.addActionArtifact=Write-AppendTestArtifact $recordedAdd 'append-recorded-add.json'
  $recordedAddResult=Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot
  Assert-ProductionTest ($recordedAddResult.ReportProjection.SuccessCount -eq 5) 'Recorded add action did not bind its actual post-action observation.'
  $recordedAdd.startedAtUtc='2026-09-05T00:00:10.600Z'
  $value.snapshot.editAppendReceipt.addActionArtifact=Write-AppendTestArtifact $recordedAdd 'append-recorded-add-invented-time.json'
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} 'recorded add invented timestamp' 'add-action-binding'
  $directAppend=Invoke-MathSecrStateMachine -Snapshot $appended.snapshot -ProjectRoot $testRoot
  Assert-ProductionTest ($directAppend.State -ceq 'REPORT' -and $directAppend.PersistedCount -eq 5 -and $directAppend.SelectedCount -eq 5) 'Direct state append did not derive the complete selected bundle.'
  foreach($attack in @(
    @{name='historical Next overwritten';change={param($v)$v.snapshot.selectionBeforeNextIds=$ids}},
    @{name='historical Next occurrence scalar';change={param($v)$v.snapshot | Add-Member selectionBeforeNextOccurrenceKeys 'source-row-1'}},
    @{name='append prior hash';change={param($v)$v.snapshot.editAppendReceipt.priorSessionArtifact.sha256='0'*64}},
    @{name='append delta target';change={param($v)$v.snapshot.editAppendReceipt.deltaTargets[0].sourceProblemNumber='4'}},
    @{name='append delta occurrence';change={param($v)$v.snapshot.editAppendReceipt.deltaTargets[0].occurrenceKey='source-row-4'}},
    @{name='append delta candidate';change={param($v)$v.snapshot.editAppendReceipt.deltaTargets[0].problemId='foreign'}},
    @{name='append delta ghost';change={param($v)$v.snapshot.editAppendReceipt.deltaTargets+=@([pscustomobject]@{sourceProblemNumber='4';occurrenceKey='source-row-4';problemId='candidate-4'})}},
    @{name='append confirm absent';change={param($v)$v.snapshot.editAppendReceipt.PSObject.Properties.Remove('confirmActionArtifact')}},
    @{name='append receipt absent';change={param($v)$v.snapshot.PSObject.Properties.Remove('editAppendReceipt')}},
    @{name='append prior target rewritten';change={param($v)$v.snapshot.targets[0].bodyComparisonReceipt.comparedBy='rewritten-comparer'}},
    @{name='append new body mismatch';change={param($v)$v.snapshot.targets[4].bodyComparisonReceipt.comparison.conditions='mismatch'}},
    @{name='append draft lost prior';change={param($v)$v.snapshot.edit.draftIds=@('candidate-5')}},
    @{name='append reload wrong order';change={param($v)$v.snapshot.persistence.ids=@($ids[4],$ids[0..3])}},
    @{name='append delta not selected';change={param($v)$v.snapshot.targets[4]=Copy-ProductionTest $partial.snapshot.targets[4]}}
  )){$value=Copy-ProductionTest $appended;& $attack.change $value;Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} $attack.name}
  $artifactAttackIndex=0
  foreach($attack in @(
    @{name='append before stale prior';field='beforeObservationArtifact';value=$beforeAppend;change={param($v)$v.priorEditIds=@('foreign')}},
    @{name='append unselected modal delta';field='beforeObservationArtifact';value=$beforeAppend;change={param($v)$v.modalSelectedIds=@()}},
    @{name='append before wrong URL';field='beforeObservationArtifact';value=$beforeAppend;change={param($v)$v.url='https://www.mathsecr.com/mypaper/124'}},
    @{name='append wrong control';field='addActionArtifact';value=$addAction;change={param($v)$v.controlName='출제하기'}},
    @{name='append non Aside action';field='confirmActionArtifact';value=$confirmAction;change={param($v)$v.surface='iab'}},
    @{name='append action evidence absent';field='confirmActionArtifact';value=$confirmAction;change={param($v)$v.PSObject.Properties.Remove('evidenceArtifact')}},
    @{name='append execution binding absent';field='confirmActionArtifact';value=$confirmAction;change={param($v)$v.PSObject.Properties.Remove('executionBinding')}},
    @{name='append execution command key missing';field='confirmActionArtifact';value=$confirmAction;change={param($v)$v.executionBinding.commandRecordKey='foreign-command'}},
    @{name='append execution completed marker mismatch';field='confirmActionArtifact';value=$confirmAction;change={param($v)$v.executionBinding.completionMarker='FOREIGN_MARKER:'}},
    @{name='append confirm observations absent';field='confirmActionArtifact';value=$confirmAction;change={param($v)$v.PSObject.Properties.Remove('beforeObservationArtifact')}},
    @{name='append invented execution time';field='confirmActionArtifact';value=$confirmAction;change={param($v)$v.startedAtUtc='2026-09-05T00:00:13.100Z';$v.completedAtUtc='2026-09-05T00:00:14.100Z'}},
    @{name='append action reused';field='confirmActionArtifact';value=$confirmAction;change={param($v)$v.actionId='synthetic-add'}},
    @{name='append confirm before add';field='confirmActionArtifact';value=$confirmAction;change={param($v)$v.startedAtUtc='2026-09-05T00:00:11.000Z'}},
    @{name='append window invented';field='addActionArtifact';value=$addAction;change={param($v)$v.completedAtUtc='2026-09-05T00:00:11.000Z'}},
    @{name='append draft before confirmation';field='draftObservationArtifact';value=$draftAppend;change={param($v)$v.capturedAtUtc='2026-09-05T00:00:13.000Z'}},
    @{name='append observed draft missing prior';field='draftObservationArtifact';value=$draftAppend;change={param($v)$v.draftIds=@('candidate-5')}},
    @{name='append observed draft wrong order';field='draftObservationArtifact';value=$draftAppend;change={param($v)$v.draftIds=@($ids[4],$ids[0..3])}},
    @{name='append prior state corrupted';field='priorSessionArtifact';value=$partial;change={param($v)$v.snapshot.persistence.ids=@('candidate-1')}},
    @{name='append prior production capture corrupted';field='priorSessionArtifact';value=$partial;change={param($v)$v.persistedCards[0].rawVisibleDbName='invented source'}},
    @{name='append prior PDF absent';field='priorSessionArtifact';value=$partial;change={param($v)$v.failureReportPdf='없음'}}
  )) {
    $changed=Copy-ProductionTest $attack.value;& $attack.change $changed
    $value=Copy-ProductionTest $appended;$value.snapshot.editAppendReceipt.($attack.field)=Write-AppendTestArtifact $changed "append-negative-$artifactAttackIndex.json"
    Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} $attack.name
    $artifactAttackIndex++
  }
  $unrelatedAction=Copy-ProductionTest $confirmAction;$unrelatedAction.evidenceArtifact=$partial.sourceRosterArtifact
  $value=Copy-ProductionTest $appended;$value.snapshot.editAppendReceipt.confirmActionArtifact=Write-AppendTestArtifact $unrelatedAction 'append-unrelated-json-action.json'
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} 'append arbitrary JSON as execution artifact' 'execution-schema'
  foreach($attack in @(
    @{name='append command no click';change={param($v)$v.records[2].value="const controlName='확인';"}},
    @{name='append command another control';change={param($v)$v.records[2].value="const controlName='추가';page.click();"}},
    @{name='append result empty';change={param($v)$v.records[3].value.output=''}},
    @{name='append duplicate execution key';change={param($v)$v.records+=@($v.records[2])}}
  )) {
    $badExecution=Copy-ProductionTest $syntheticExecution;& $attack.change $badExecution
    $badAction=Copy-ProductionTest $confirmAction;$badAction.evidenceArtifact=Write-AppendTestArtifact $badExecution "append-bad-execution-$artifactAttackIndex.json"
    $value=Copy-ProductionTest $appended;$value.snapshot.editAppendReceipt.confirmActionArtifact=Write-AppendTestArtifact $badAction "append-bad-execution-action-$artifactAttackIndex.json"
    Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} $attack.name
    $artifactAttackIndex++
  }
  foreach($attack in @(
    @{name='append confirm wrong before bundle';field='beforeObservationArtifact';value=$syntheticConfirmBefore;change={param($v)$v.draftIds=@('foreign')}},
    @{name='append confirm observed another control';field='afterObservationArtifact';value=$syntheticConfirmAfter;change={param($v)$v.controlName='추가'}},
    @{name='append confirm observed another URL';field='afterObservationArtifact';value=$syntheticConfirmAfter;change={param($v)$v.url='https://www.mathsecr.com/mypaper/124'}},
    @{name='append confirm observed no click';field='afterObservationArtifact';value=$syntheticConfirmAfter;change={param($v)$v.action='hover'}},
    @{name='append confirm observed timestamp mismatch';field='afterObservationArtifact';value=$syntheticConfirmAfter;change={param($v)$v.startedAtUtc='2026-09-05T00:00:13.100Z'}}
  )) {
    $badObservation=Copy-ProductionTest $attack.value;& $attack.change $badObservation
    $badAction=Copy-ProductionTest $confirmAction;$badAction.($attack.field)=Write-AppendTestArtifact $badObservation "append-bad-confirm-observed-$artifactAttackIndex.json"
    $value=Copy-ProductionTest $appended;$value.snapshot.editAppendReceipt.confirmActionArtifact=Write-AppendTestArtifact $badAction "append-bad-confirm-observed-action-$artifactAttackIndex.json"
    Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} $attack.name
    $artifactAttackIndex++
  }
  $earlyPersisted=Copy-ProductionTest $appendCapture;$earlyPersisted.capturedAtUtc='2026-09-05T00:00:14.000Z'
  $value=Copy-ProductionTest $appended;$value.persistedCardObservationArtifact=Write-AppendTestArtifact $earlyPersisted 'append-early-persisted.json'
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} 'append persisted before confirmed draft' 'predates'
  $sameRead=Copy-ProductionTest $appendCapture;$sameRead.captureId=$partialCapture.captureId
  $value=Copy-ProductionTest $appended;$value.persistedCardObservationArtifact=Write-AppendTestArtifact $sameRead 'append-reused-persisted.json'
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $testRoot} 'append reused prior capture' 'read identity'
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step BeforeNext -InputObject $appended -ProjectRoot $testRoot} 'append BeforeNext reuse' 'AfterReload'
  $withKeys=Copy-ProductionTest $appended;$allKeys=@($targets | ForEach-Object {$_.occurrenceKey})
  $withKeys.snapshot | Add-Member selectionAfterAppendOccurrenceKeys $allKeys
  $withKeys.snapshot.edit | Add-Member draftOccurrenceKeys $allKeys
  $withKeys.snapshot.persistence | Add-Member occurrenceKeys $allKeys
  $keyedResult=Invoke-MathSecrProductionStep -Step AfterReload -InputObject $withKeys -ProjectRoot $testRoot
  Assert-ProductionTest ((Test-OrderedIdsEqual $allKeys $keyedResult.StateResult.SelectedOccurrenceKeys)) 'Append full occurrence bundle was not preserved.'
  $withKeys.snapshot.persistence.occurrenceKeys=@($allKeys[0..3])
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $withKeys -ProjectRoot $testRoot} 'append partial occurrence bundle'
  $lowerCaseBinding=Copy-ProductionTest $appended
  $lowerCaseBinding.snapshot.targets[4].sourceBodyArtifact.sha256=$lowerCaseBinding.snapshot.targets[4].sourceBodyArtifact.sha256.ToUpperInvariant()
  $lowerCaseResult=Invoke-MathSecrProductionStep -Step AfterReload -InputObject $lowerCaseBinding -ProjectRoot $testRoot
  Assert-ProductionTest ($lowerCaseResult.ReportProjection.SuccessCount -eq 5) 'Equivalent SHA-256 case changed append source identity.'
  $duplicateAppend=Copy-ProductionTest $appended
  $duplicateAppend.snapshot.targets[4]=New-ProductionTarget '5' 'candidate-4'
  $duplicateIds=@($ids[0..3])+@('candidate-4')
  $duplicateAppend.snapshot.edit.draftIds=$duplicateIds;$duplicateAppend.snapshot.persistence.ids=$duplicateIds
  $duplicateAppend.persistedCards[4].problemId='candidate-4'
  $duplicateBefore=Copy-ProductionTest $beforeAppend;$duplicateBefore.modalSelectedIds=@('candidate-4')
  $duplicateAfter=Copy-ProductionTest $afterAppend;$duplicateAfter.draftIds=$duplicateIds
  $duplicateDraft=Copy-ProductionTest $draftAppend;$duplicateDraft.draftIds=$duplicateIds
  $duplicateAdd=Copy-ProductionTest $addAction
  $duplicateConfirmBefore=Copy-ProductionTest $syntheticConfirmBefore;$duplicateConfirmBefore.draftIds=$duplicateIds
  $duplicateConfirmAfter=Copy-ProductionTest $syntheticConfirmAfter;$duplicateConfirmAfter.draftIds=$duplicateIds
  $duplicateConfirm=Copy-ProductionTest $confirmAction
  $duplicateConfirm.beforeObservationArtifact=Write-AppendTestArtifact $duplicateConfirmBefore 'append-duplicate-confirm-before.json'
  $duplicateConfirm.afterObservationArtifact=Write-AppendTestArtifact $duplicateConfirmAfter 'append-duplicate-confirm-after.json'
  $duplicateAdd.afterObservationArtifact=Write-AppendTestArtifact $duplicateAfter 'append-duplicate-after.json'
  $duplicateAppend.snapshot.editAppendReceipt.beforeObservationArtifact=Write-AppendTestArtifact $duplicateBefore 'append-duplicate-before.json'
  $duplicateAppend.snapshot.editAppendReceipt.addActionArtifact=Write-AppendTestArtifact $duplicateAdd 'append-duplicate-add.json'
  $duplicateAppend.snapshot.editAppendReceipt.confirmActionArtifact=Write-AppendTestArtifact $duplicateConfirm 'append-duplicate-confirm.json'
  $duplicateAppend.snapshot.editAppendReceipt.draftObservationArtifact=Write-AppendTestArtifact $duplicateDraft 'append-duplicate-draft.json'
  $duplicateAppend.snapshot.editAppendReceipt.deltaTargets[0].problemId='candidate-4'
  $duplicateCapture=Copy-ProductionTest $appendCapture;$duplicateCapture.cards[4].problemId='candidate-4'
  $duplicateAppend.persistedCardObservationArtifact=Write-AppendTestArtifact $duplicateCapture 'append-duplicate-persisted.json'
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $duplicateAppend -ProjectRoot $testRoot} 'duplicate append without separate proof'
  $duplicateAppend.snapshot | Add-Member selectionAfterAppendOccurrenceKeys $allKeys
  $duplicateAppend.snapshot.edit | Add-Member draftOccurrenceKeys $allKeys
  $duplicateAppend.snapshot.persistence | Add-Member occurrenceKeys $allKeys
  $duplicateAppend.snapshot | Add-Member occurrenceProof ([pscustomobject]@{DuplicateAddControlVerified=$true;DuplicateAddControlKind='duplicate/add';DuplicateAddControlReceipt='synthetic separate add control';OrderedBundleVerified=$true})
  $duplicateResult=Invoke-MathSecrProductionStep -Step AfterReload -InputObject $duplicateAppend -ProjectRoot $testRoot
  Assert-ProductionTest ($duplicateResult.ReportProjection.SuccessCount -eq 5 -and (Test-OrderedIdsEqual $duplicateIds $duplicateResult.StateResult.PersistedIds)) 'Distinct duplicate occurrences were collapsed by append.'
  $duplicateAppend.snapshot.persistence.occurrenceKeys=@($allKeys[0..3])
  Expect-ProductionRejection {Invoke-MathSecrProductionStep -Step AfterReload -InputObject $duplicateAppend -ProjectRoot $testRoot} 'duplicate append incomplete occurrence bundle'
  $cli=Join-Path $PSScriptRoot 'validate_production_step.ps1';$inputPath=Join-Path $testRoot 'session.json';Write-ProductionTest $session $inputPath
  $selectOut=Join-Path $testRoot 'select-result.json'
  $selectCli=@(& pwsh -NoProfile -File $cli -Step Select -InputPath $inputPath -ProjectRoot $testRoot -TargetOccurrenceKey 'source-row-1' -OutPath $selectOut 2>&1)
  Assert-ProductionTest ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $selectOut)) "Bound Select CLI failed: $($selectCli -join ' ')."
  $outPath=Join-Path $testRoot 'result.json';$summaryPath=Join-Path $testRoot 'summary.md'
  $cliResult=@(& pwsh -NoProfile -File $cli -Step AfterReload -InputPath $inputPath -ProjectRoot $testRoot -OutPath $outPath -SummaryPath $summaryPath 2>&1)
  Assert-ProductionTest ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $outPath) -and (Test-Path -LiteralPath $summaryPath)) "CLI roundtrip failed: $($cliResult -join ' ')."
  $appendCliInput=Join-Path $testRoot 'append-session.json';Write-ProductionTest $appended $appendCliInput
  $appendCliOut=Join-Path $testRoot 'append-result.json'
  $appendCli=@(& pwsh -NoProfile -File $cli -Step AfterReload -InputPath $appendCliInput -ProjectRoot $testRoot -OutPath $appendCliOut 2>&1)
  Assert-ProductionTest ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $appendCliOut)) "Strict CLI edit append failed: $($appendCli -join ' ')."
  $appendCliResult=ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $appendCliOut -Raw)
  Assert-ProductionTest ($appendCliResult.Valid -and $appendCliResult.ReportProjection.SuccessCount -eq 5 -and (Test-OrderedIdsEqual $ids[0..3] $appendCliResult.StateResult.SelectionBeforeNextIds)) 'Strict CLI edit append rewrote initial Next or lost persisted rows.'
  $outHash=(Get-FileHash -LiteralPath $outPath).Hash
  $null=& pwsh -NoProfile -File $cli -Step AfterReload -InputPath $inputPath -ProjectRoot $testRoot -OutPath $outPath 2>&1
  Assert-ProductionTest ($LASTEXITCODE -ne 0 -and (Get-FileHash -LiteralPath $outPath).Hash -ceq $outHash) 'CLI overwrote an existing result.'
  Write-Output "PASS Production Validation: $assertions assertions; Select/BeforeNext/AfterReload, edit append with historical Next preservation, typed source/count/order comparisons, unresolved partial-save and real PDF/CLI roundtrip; offline-contract only."
} finally {
  $full=[IO.Path]::GetFullPath($testRoot);$tmp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if($full.StartsWith($tmp+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full).StartsWith('mathsecr-production-test-',[StringComparison]::Ordinal)){Remove-Item -LiteralPath $full -Recurse -Force}
}
