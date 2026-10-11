# New synthetic inputs for Phase 0. This is not a recovered private fixture,
# a real browser observation, or a mathematical/visual oracle.
. (Join-Path $PSScriptRoot '../../mathsecr-paper-builder-kit/scripts/production_validation.ps1')

function Assert-MathSecrBenchmarkTempRoot {
  param([Parameter(Mandatory)][string]$Path)
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if (-not $full.StartsWith($temp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Benchmark artifacts must be in a child of the system temporary directory.'
  }
  $ancestor = $full
  while ($ancestor) {
    if (Test-Path -LiteralPath $ancestor) {
      if (((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Benchmark paths must not traverse reparse points.'
      }
    }
    $ancestor = Split-Path -Parent $ancestor
  }
  return $full
}

function Remove-MathSecrOwnedBenchmarkRoot {
  param([string]$Path)
  $full = Assert-MathSecrBenchmarkTempRoot $Path
  if ([IO.Path]::GetFileName($full) -notmatch '^mathsecr-phase0-[a-z]+-[a-f0-9]{32}$') {
    throw 'Refusing cleanup of a directory not owned by the Phase 0 harness.'
  }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

function Copy-MathSecrBenchmarkObject {
  param($Value)
  return ConvertFrom-MathSecrContractJson (ConvertTo-Json -InputObject $Value -Depth 100 -Compress)
}

function Write-MathSecrBenchmarkArtifact {
  param($Value, [string]$Root, [string]$Name)
  $path = Join-Path $Root $Name
  if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite benchmark artifact: $Name" }
  [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Value -Depth 100 -Compress), [Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{path=$Name; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}

function New-MathSecrBenchmarkObservation {
  param([string]$AttemptId, [string]$CandidateId, [string]$Surface='aside-repl', [string]$PaperUrl)
  if (-not $PaperUrl) { $PaperUrl = 'https://www.mathsecr.com/mypaper/123' }
  $criteria = [pscustomobject]@{
    scopeMode='내 문제지'; sourceChips=@('합성 DB'); filterChips=@('대수')
    chips=@([pscustomobject]@{kind='text';value='본문'}, [pscustomobject]@{kind='text';value='조건'})
  }
  $reads = @(foreach ($index in 0..2) {
    [pscustomobject]@{
      schemaVersion=1; collectorVersion='mathsecr-search-observation-v1'
      adapterId='phase0-synthetic-adapter'; adapterEvidenceId='phase0-synthetic-control-map'
      attemptId=$AttemptId; submitId=$(if ($index -eq 0) {$null} else {"submit-$AttemptId"})
      readEvidenceId="read-$AttemptId-$index"
      raw=[pscustomobject]@{
        captureId="capture-$AttemptId-$index"; capturedAtUtc=('2026-10-11T00:00:0{0}.000Z' -f $index)
        timeOriginMs=1000; monotonicMs=($index + 1)
        url=$PaperUrl; title='Synthetic Phase 0 fixture'
        criteria=(Copy-MathSecrBenchmarkObject $criteria); scopeSelectionConfirmed=$true
        result=[pscustomobject]@{count=1;orderedIds=@($CandidateId);loading=$false;observedSubmitId=$null;observedCriteriaKey=$null}
      }
    }
  })
  return [pscustomobject]@{
    schemaVersion=1; attemptId=$AttemptId
    submission=[pscustomobject]@{
      submitId="submit-$AttemptId"; actionEvidenceId="action-$AttemptId"; action='검색하기'; surface=$Surface
      completedAtUtc='2026-10-11T00:00:00.500Z'; url=$PaperUrl
      criteria=$criteria; resultCriteriaKey=$null
    }
    beforeSubmit=$reads[0]; observations=@($reads[1], $reads[2])
  }
}

function New-MathSecrBenchmarkTarget {
  param($SourceRow, [string]$CandidateName, [string]$Surface='aside-repl', [string]$PaperUrl)
  $number = $SourceRow.number
  $id = 'candidate-' + $number
  $attempt = 'attempt-' + $number
  $hash = $SourceRow.sourceBodyArtifact.sha256
  return [pscustomobject]@{
    number=$number; occurrenceKey=$SourceRow.occurrenceKey; initial='exact'; selectedId=$id
    sourceBodyArtifact=(Copy-MathSecrBenchmarkObject $SourceRow.sourceBodyArtifact)
    searchAttemptReceipt=[pscustomobject]@{
      targetBinding=[pscustomobject]@{sourceProblemNumber=$number;occurrenceKey=$SourceRow.occurrenceKey};outcome='exact'
      literalEvidence=[pscustomobject]@{body=@('본문','조건');printedMetadata=@();visibleUiMetadata=@();formula=@()}
      attempts=@([pscustomobject]@{
        attemptId=$attempt;scope='initial-scope';phase='initial'
        chips=@([pscustomobject]@{value='본문';provenance='literal-body';evidenceReceipt='synthetic-body'},
          [pscustomobject]@{value='조건';provenance='literal-body';evidenceReceipt='synthetic-condition'})
        submitted=$true;freshResultVerified=$true;resultCount=1;exactFound=$true;inspectedIds=@($id);exactMatchIds=@($id)
        resetBefore=$true;clearReceipt='synthetic-clean';removedChips=@()
        observationReceipt=(New-MathSecrBenchmarkObservation $attempt $id -Surface $Surface -PaperUrl $PaperUrl)
      })
      candidateRecoveryEvidence=[pscustomobject]@{routes=@();coverage=@()}
      commonChips=@('본문','조건');exactMatchIds=@($id);literalOnlyLadderCompleted=$true
      resetBackoffPerformed=$true;candidateRecoveryCompleted=$false;completeCoverageVerified=$false
    }
    bodyComparisonReceipt=[pscustomobject]@{
      sourceProblemNumber=$number;occurrenceKey=$SourceRow.occurrenceKey;candidateId=$id;searchAttemptId=$attempt
      policyVersion='body-only-v1';verdict='exact'
      sourceRenderArtifact=$SourceRow.sourceBodyArtifact.path;sourceRenderSha256=$hash
      candidateRenderArtifact=$CandidateName;candidateRenderSha256=$hash;sourceRenderScale=2;candidateRenderScale=1
      comparison=[pscustomobject]@{bodyText='match';conditions='match';formulas='match';figures='not-present';
        pointLabels='not-present';requiredValue='match';internalStatements='not-present'}
      comparedBy='phase0-synthetic-contract-generator';comparedAtUtc='2026-10-11T00:00:05.000Z';unresolvedGlyphs=$false
    }
  }
}

function New-MathSecrAppendHistoryFixture {
  [CmdletBinding()]
  param(
    [ValidateRange(1, 1000)][int]$ProblemCount,
    [ValidateRange(0, 63)][int]$HistoryDepth,
    [Parameter(Mandatory)][string]$OutRoot,
    [string]$Surface='aside-repl',
    [string]$PaperUrl
  )
  if ($HistoryDepth -ge $ProblemCount) { throw 'Each append must add a new row; ProblemCount must exceed HistoryDepth.' }
  if (-not $PaperUrl) {
    $PaperUrl = if ($Surface -ceq 'offline-dom-test') {
      [Uri]::new((Join-Path $PSScriptRoot '../../mathsecr-paper-builder-kit/test-fixtures/iab-simulator/index.html')).AbsoluteUri
    } else { 'https://www.mathsecr.com/mypaper/123' }
  }
  $root = Assert-MathSecrBenchmarkTempRoot $OutRoot
  if (Test-Path -LiteralPath $root) {
    if (-not (Test-Path -LiteralPath $root -PathType Container) -or @(Get-ChildItem -LiteralPath $root -Force).Count) {
      throw 'OutRoot must be absent or an empty temporary directory.'
    }
  } else { $null = New-Item -ItemType Directory -Path $root }
  # Valid, distinct PNGs; no original exam or candidate body is read.
  $python = @'
from pathlib import Path
from PIL import Image
import sys
root = Path(sys.argv[1])
for number in range(1, int(sys.argv[2]) + 1):
    image = Image.new("RGB", (16, 16), ((number * 37) % 256, (number * 71) % 256, (number * 113) % 256))
    image.save(root / f"source-{number}.png")
    image.save(root / f"candidate-{number}.png")
'@
  $pythonOutput = @(& python -c $python $root $ProblemCount 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "Synthetic crop generation failed: $($pythonOutput -join ' ')" }
  $rows = @(foreach ($number in 1..$ProblemCount) {
    $name = "source-$number.png"
    [pscustomobject]@{number=[string]$number;occurrenceKey="source-row-$number";
      sourceBodyArtifact=[pscustomobject]@{path=$name;sha256=(Get-FileHash -LiteralPath (Join-Path $root $name)).Hash.ToLowerInvariant()}}
  })
  $roster = Write-MathSecrBenchmarkArtifact ([pscustomobject]@{schemaVersion=1;targets=$rows}) $root 'source-roster.json'
  $targets = @(foreach ($row in $rows) { New-MathSecrBenchmarkTarget $row ("candidate-" + $row.number + '.png') -Surface $Surface -PaperUrl $PaperUrl })
  $initialCount = $ProblemCount - $HistoryDepth
  $initialIds = @($targets[0..($initialCount - 1)] | ForEach-Object {$_.selectedId})
  $sessions = [Collections.Generic.List[object]]::new()
  $prior = $null
  for ($stage = 0; $stage -le $HistoryDepth; $stage++) {
    $selectedCount = $initialCount + $stage
    $currentTargets = @(for ($index = 0; $index -lt $ProblemCount; $index++) {
      if ($index -lt $selectedCount) { Copy-MathSecrBenchmarkObject $targets[$index] }
      else { [pscustomobject]@{number=$rows[$index].number;occurrenceKey=$rows[$index].occurrenceKey;
        initial='not-started';sourceBodyArtifact=(Copy-MathSecrBenchmarkObject $rows[$index].sourceBodyArtifact)} }
    })
    $ids = @($currentTargets[0..($selectedCount - 1)] | ForEach-Object {$_.selectedId})
    $cards = @($currentTargets[0..($selectedCount - 1)] | ForEach-Object {
      [pscustomobject]@{problemId=$_.selectedId;occurrenceKey=$_.occurrenceKey;rawVisibleDbName='합성 DB > 대수'}
    })
    $origin = [datetimeoffset]::Parse('2026-10-11T00:00:10.000Z').AddSeconds($stage * 10)
    $stamp = {param([double]$Seconds) $origin.AddSeconds($Seconds).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture)}
    $capture = [pscustomobject]@{
      schemaVersion=1;captureId="persisted-capture-$stage";collectorVersion='phase0-synthetic-v1';surface=$Surface
      capturedAtUtc=(& $stamp 7);url=$PaperUrl;title='Synthetic Phase 0 fixture'
      readEvidenceId="persisted-read-$stage"
      cards=@($cards | ForEach-Object {[pscustomobject]@{problemId=$_.problemId;rawVisibleDbName=$_.rawVisibleDbName}})
    }
    $session = [pscustomobject]@{
      schemaVersion=1;sessionId='phase0-synthetic-session';paper=[pscustomobject]@{name='합성 성능 기준선';url=$capture.url}
      sourceTargets=@(Copy-MathSecrBenchmarkObject $rows);sourceRosterArtifact=$roster
      snapshot=[pscustomobject]@{
        sourcePresent=$true;asideRepl=[pscustomobject]@{available=$true;paperVerified=$true;nonAsideReplLiveManipulation=$false}
        cleanStateVerified=$true;scope=[pscustomobject]@{verified=$true;unexpectedBroadResult=$false;resultCount=1}
        requestedAction='partial-save';targets=$currentTargets;selectionBeforeNextIds=$initialIds;nextClicked=$true
        edit=[pscustomobject]@{draftIds=$ids;oldIds=@();recovery='not_needed'}
        persistence=[pscustomobject]@{freshReloadVerified=$true;ids=$ids};issueClicked=$false
      }
      persistedCards=$cards;failureReportPdf='없음'
      persistedCardObservationArtifact=(Write-MathSecrBenchmarkArtifact $capture $root "persisted-$stage.json")
    }
    if ($Surface -cne 'aside-repl') {
      $session | Add-Member -NotePropertyName surfaceIdentity -NotePropertyValue ([pscustomobject]@{
        schemaVersion=1;surface=$Surface;browserFamily=$MathSecrSurfaceBrowserFamilies[$Surface]
        profileOrSessionId='synthetic-profile';tabId='synthetic-tab';url=$PaperUrl;observedAtUtc='2026-10-11T00:00:00.000Z'
      })
      $session.snapshot.PSObject.Properties.Remove('asideRepl')
      $session.snapshot | Add-Member -NotePropertyName surfaceState -NotePropertyValue ([pscustomobject]@{
        surface=$Surface;available=$true;paperVerified=$true;offSurfaceLiveManipulation=$false
      })
    }
    if ($selectedCount -lt $ProblemCount) {
      $items = @(foreach ($number in ($selectedCount + 1)..$ProblemCount) {
        [pscustomobject]@{problem_number=$number;image="source-$number.png";crop=@(0,0,16,16)}
      })
      $manifest = Write-MathSecrBenchmarkArtifact ([pscustomobject]@{title='Synthetic unresolved crops';source='synthetic.pdf';items=$items}) $root "failure-$stage.json"
      $pdf = Join-Path $root "failure-$stage.pdf"
      $pdfOutput = @(& python (Join-Path $PSScriptRoot '../../mathsecr-paper-builder-kit/scripts/create_failed_problem_report.py') --manifest (Join-Path $root $manifest.path) --output $pdf --project-root $root 2>&1)
      if ($LASTEXITCODE -ne 0) { throw "Synthetic PDF generation failed: $($pdfOutput -join ' ')" }
      $session.failureReportPdf = $pdf
    }
    if ($stage -gt 0) {
      $before = [pscustomobject]@{capturedAtUtc=(& $stamp 0);url=$capture.url;priorEditIds=@($ids[0..($selectedCount - 2)]);
        modalSelectedIds=@($ids[-1]);action='추가'}
      $after = [pscustomobject]@{capturedAtUtc=(& $stamp 2);url=$capture.url;draftIds=$ids}
      $execution = [pscustomobject]@{schemaVersion=1;truthScope='offline-contract';records=@(
        [pscustomobject]@{key='add-command';value="const action='추가';page.click();"},
        [pscustomobject]@{key='add-result';value=[pscustomobject]@{output='SYNTHETIC_APPEND_COMPLETED: fixture'}},
        [pscustomobject]@{key='confirm-command';value="const action='확인';page.click();"},
        [pscustomobject]@{key='confirm-result';value=[pscustomobject]@{output='SYNTHETIC_CONFIRM_COMPLETED: fixture'}}
      )}
      $evidence = Write-MathSecrBenchmarkArtifact $execution $root "execution-$stage.json"
      $beforeReceipt = Write-MathSecrBenchmarkArtifact $before $root "before-$stage.json"
      $afterReceipt = Write-MathSecrBenchmarkArtifact $after $root "after-$stage.json"
      $add = [pscustomobject]@{actionId="synthetic-add-$stage";surface=$Surface;startedAtUtc=$before.capturedAtUtc;
        completedAtUtc=$after.capturedAtUtc;timingBasis='observation-window';url=$capture.url;controlName='추가';action='click';
        evidenceArtifact=$evidence;afterObservationArtifact=$afterReceipt;
        executionBinding=[pscustomobject]@{commandRecordKey='add-command';resultRecordKey='add-result';completionMarker='SYNTHETIC_APPEND_COMPLETED:'}}
      $confirmBefore = [pscustomobject]@{capturedAtUtc=(& $stamp 2.5);url=$capture.url;draftIds=$ids;controlName='확인';surface=$Surface}
      $confirmAfter = [pscustomobject]@{schemaVersion=1;capturedAtUtc=(& $stamp 4.5);url=$capture.url;draftIds=$ids;
        controlName='확인';surface=$Surface;action='click';startedAtUtc=(& $stamp 3);completedAtUtc=(& $stamp 4)}
      $confirm = [pscustomobject]@{actionId="synthetic-confirm-$stage";surface=$Surface;startedAtUtc=$confirmAfter.startedAtUtc;
        completedAtUtc=$confirmAfter.completedAtUtc;timingBasis='recorded-execution';url=$capture.url;controlName='확인';action='click';
        evidenceArtifact=$evidence;executionBinding=[pscustomobject]@{commandRecordKey='confirm-command';resultRecordKey='confirm-result';completionMarker='SYNTHETIC_CONFIRM_COMPLETED:'};
        beforeObservationArtifact=(Write-MathSecrBenchmarkArtifact $confirmBefore $root "confirm-before-$stage.json");
        afterObservationArtifact=(Write-MathSecrBenchmarkArtifact $confirmAfter $root "confirm-after-$stage.json")}
      $draft = [pscustomobject]@{capturedAtUtc=(& $stamp 5);url=$capture.url;draftIds=$ids}
      $delta = $currentTargets[$selectedCount - 1]
      $receipt = [pscustomobject]@{schemaVersion=1;appendId="synthetic-append-$stage";surface=$Surface;
        priorSessionArtifact=$prior;beforeObservationArtifact=$beforeReceipt;
        deltaTargets=@([pscustomobject]@{sourceProblemNumber=$delta.number;occurrenceKey=$delta.occurrenceKey;problemId=$delta.selectedId});
        addActionArtifact=(Write-MathSecrBenchmarkArtifact $add $root "add-$stage.json");
        confirmActionArtifact=(Write-MathSecrBenchmarkArtifact $confirm $root "confirm-$stage.json");
        draftObservationArtifact=(Write-MathSecrBenchmarkArtifact $draft $root "draft-$stage.json")}
      $session.snapshot | Add-Member -NotePropertyName editAppendReceipt -NotePropertyValue $receipt
    }
    $prior = Write-MathSecrBenchmarkArtifact $session $root "session-$stage.json"
    $sessions.Add([pscustomobject]@{stage=$stage;selectedCount=$selectedCount;artifact=$prior})
  }
  $value = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath (Join-Path $root $prior.path) -Raw -Encoding UTF8)
  $validation = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $value -ProjectRoot $root
  if (-not $validation.Valid -or $validation.ReportProjection.SuccessCount -ne $ProblemCount) {
    throw 'The generated history did not pass the unchanged production boundary.'
  }
  $manifest = [pscustomobject]@{schemaVersion=1;kind='new-phase0-synthetic-history';truthScope='offline-contract';
    liveProductBehavior=$false;problemCount=$ProblemCount;historyDepth=$HistoryDepth;sessions=$sessions.ToArray();
    finalSessionArtifact=$prior;validated=$true;
    artifactCount=(@(Get-ChildItem -LiteralPath $root -File -Recurse).Count + 1)}
  # Include fixture.json itself; write it once, then verify the final inventory.
  $null = Write-MathSecrBenchmarkArtifact $manifest $root 'fixture.json'
  if ($manifest.artifactCount -ne @(Get-ChildItem -LiteralPath $root -File -Recurse).Count) {
    throw 'Synthetic artifact count does not match the final file inventory.'
  }
  return [pscustomobject]@{Root=$root;Manifest=$manifest;Session=$value}
}
