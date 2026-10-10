# Thin production boundary. All observations and judgments are supplied by the
# caller; existing search/body/state contracts derive the validation result.
. (Join-Path $PSScriptRoot 'state_machine.ps1')
. (Join-Path $PSScriptRoot 'report_contract.ps1')
. (Join-Path $PSScriptRoot 'read_contract_json.ps1')

function Assert-MathSecrProduction {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "Production validation: $Message" }
}

function Get-MathSecrProductionArtifact {
  param($Receipt, [string]$ProjectRoot, [string]$Extension = '.json')
  Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $Receipt @('path','sha256')) 'An artifact path and SHA-256 are required.'
  Assert-MathSecrProduction ($Receipt.sha256 -is [string] -and $Receipt.sha256 -match '^[a-fA-F0-9]{64}$') 'Artifact SHA-256 is invalid.'
  Assert-MathSecrProduction ($Receipt.path -is [string] -and -not [string]::IsNullOrWhiteSpace($Receipt.path) -and $Receipt.path -ceq $Receipt.path.Trim() -and -not [IO.Path]::IsPathRooted($Receipt.path) -and -not $Receipt.path.Contains(':')) 'Artifact path must be canonical and project-relative.'
  $segments=@($Receipt.path -split '[\\/]+')
  Assert-MathSecrProduction (@($segments | Where-Object { $_ -cin @('','.','..') }).Count -eq 0) 'Artifact path contains an unsafe segment.'
  $root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
  $full=[IO.Path]::GetFullPath((Join-Path $root $Receipt.path))
  Assert-MathSecrProduction ($full.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Leaf) -and [IO.Path]::GetExtension($full).ToLowerInvariant() -ceq $Extension) 'Artifact must be an existing, safe project-relative file of the required type.'
  $cursor=$root
  foreach($segment in $segments){$cursor=Join-Path $cursor $segment;Assert-MathSecrProduction (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Artifact path traverses a reparse point.'}
  $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
  Assert-MathSecrProduction ([string]::Equals($hash, $Receipt.sha256, [StringComparison]::OrdinalIgnoreCase)) 'Artifact hash does not match its bytes.'
  return $full
}

function Assert-MathSecrProductionRoster {
  param($Session, [string]$ProjectRoot)
  Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $Session @('schemaVersion','sessionId','paper','sourceTargets','sourceRosterArtifact','snapshot')) 'A versioned session, source roster and current snapshot are required.'
  Assert-MathSecrProduction ((Test-IsStrictInteger $Session.schemaVersion) -and $Session.schemaVersion -eq 1) 'Unsupported session schemaVersion.'
  Assert-MathSecrProduction (Test-IsCanonicalId $Session.sessionId) 'sessionId must be canonical.'
  Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $Session.paper @('name','url')) 'Paper name and URL are required.'
  Assert-MathSecrProduction ($Session.paper.name -is [string] -and -not [string]::IsNullOrWhiteSpace($Session.paper.name) -and $Session.paper.name -notmatch '[\r\n\[\]#@]') 'Paper name is not safe for the public summary.'
  Assert-MathSecrProduction ($Session.paper.url -is [string] -and $Session.paper.url -match '^https://www\.mathsecr\.com/mypaper/[0-9]+$') 'A verified MathSecr paper URL is required.'
  Assert-MathSecrProduction ($Session.sourceTargets -is [array] -and $Session.sourceTargets.Count -gt 0 -and $Session.snapshot -is [pscustomobject] -and $Session.snapshot.targets -is [array]) 'Source and snapshot targets must be arrays.'
  $rosterPath = Get-MathSecrProductionArtifact $Session.sourceRosterArtifact $ProjectRoot
  $roster = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $rosterPath -Raw -Encoding UTF8)
  $null = Get-MathSecrProductionArtifact $Session.sourceRosterArtifact $ProjectRoot
  Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $roster @('schemaVersion','targets')) 'The fixed source roster is invalid.'
  Assert-MathSecrProduction ((Test-IsStrictInteger $roster.schemaVersion) -and $roster.schemaVersion -eq 1 -and $roster.targets -is [array]) 'Unsupported source roster schema.'
  Assert-MathSecrProduction ($roster.targets.Count -eq $Session.sourceTargets.Count -and $roster.targets.Count -eq $Session.snapshot.targets.Count) 'Original source rows are missing or extra.'
  $numbers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  for ($i = 0; $i -lt $roster.targets.Count; $i++) {
    $original = $roster.targets[$i]
    Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $original @('number','occurrenceKey','sourceBodyArtifact')) 'Each source occurrence needs its reporting number, occurrenceKey and actual source crop.'
    Assert-MathSecrProduction ($original.number -is [string] -and $original.number -match '^[1-9][0-9]*$' -and (Test-IsCanonicalOccurrenceKey $original.occurrenceKey)) 'Source identities are invalid.'
    Assert-MathSecrProduction ($numbers.Add($original.number) -and $keys.Add($original.occurrenceKey)) 'Source identities repeat.'
    $artifact=$original.sourceBodyArtifact
    Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $artifact @('path','sha256')) 'The fixed source crop binding is missing.'
    $sourcePath=Resolve-MathSecrStateArtifactPath $ProjectRoot $artifact.path
    Assert-MathSecrProduction ($null -ne $sourcePath -and $artifact.sha256 -is [string] -and $artifact.sha256 -match '^[a-fA-F0-9]{64}$' -and [string]::Equals((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash,$artifact.sha256,[StringComparison]::OrdinalIgnoreCase)) 'The fixed source crop is missing or its hash differs.'
    foreach ($actual in @($Session.sourceTargets[$i], $Session.snapshot.targets[$i])) {
      Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $actual @('number','occurrenceKey','sourceBodyArtifact')) 'A source row is missing its identity or crop.'
      Assert-MathSecrProduction ($actual.number -is [string] -and $actual.occurrenceKey -is [string] -and $actual.number -ceq $original.number -and $actual.occurrenceKey -ceq $original.occurrenceKey) 'Original source order or occurrence binding changed.'
      Assert-MathSecrProduction ((Test-MathSecrSearchRequiredProperties $actual.sourceBodyArtifact @('path','sha256')) -and $actual.sourceBodyArtifact.path -is [string] -and $actual.sourceBodyArtifact.path -ceq $artifact.path -and $actual.sourceBodyArtifact.sha256 -is [string] -and [string]::Equals($actual.sourceBodyArtifact.sha256,$artifact.sha256,[StringComparison]::OrdinalIgnoreCase)) 'A source crop binding differs from the fixed original roster.'
    }
  }
}

function Test-MathSecrProductionSelection {
  param([pscustomobject]$Session, [string]$TargetOccurrenceKey, [string]$ProjectRoot)
  Assert-MathSecrProductionRoster $Session $ProjectRoot
  Assert-MathSecrProduction (Test-IsCanonicalOccurrenceKey $TargetOccurrenceKey) 'Select requires an explicit canonical target occurrenceKey.'
  $matching=@($Session.snapshot.targets | Where-Object {$_.occurrenceKey -ceq $TargetOccurrenceKey})
  Assert-MathSecrProduction ($matching.Count -eq 1) 'Select target must occur exactly once in the fixed session roster.'
  $Target=$matching[0]
  Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $Target @('number','occurrenceKey','selectedId','bodyComparisonReceipt','sourceBodyArtifact')) 'Select requires the actual prepared target, search observation and body comparison.'
  $rowState=Test-MathSecrTargetRowState -Target $Target
  Assert-MathSecrProduction ([bool]$rowState.Valid) "Select target row state was rejected: $($rowState.Errors -join '; ')."
  $resolution=$rowState.Resolution
  $property = $Target.PSObject.Properties['resolution']
  Assert-MathSecrProduction ($null -eq $property -or ($property.Value -is [string] -and $property.Value -ceq $resolution)) 'Caller resolution differs from the derived target route.'
  Assert-MathSecrProduction ($resolution -cin @('initial_selected','candidate_selected','whole_selected','metadata_selected')) 'Select requires an exact-producing resolution.'
  if ($resolution -ceq 'metadata_selected') {
    $metadata=Test-MathSecrMetadataRescueReceipt $Target $false $ProjectRoot
    Assert-MathSecrProduction ([bool]$metadata.Valid) 'The metadata-rescue receipt was rejected.'
  } else {
    Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $Target @('searchAttemptReceipt')) 'Select requires the actual search-attempt receipt.'
  }
  $search = Test-MathSecrSelectedSearchReceipt -Target $Target -Resolution $resolution
  Assert-MathSecrProduction ([bool]$search.Valid) 'Selected search target/candidate/attempt binding was rejected.'
  $body = Test-MathSecrBodyComparisonReceipt -Receipt $Target.bodyComparisonReceipt -Target $Target -ProjectRoot $ProjectRoot -InspectedIds $search.InspectedIds -AttemptId $search.AttemptId
  Assert-MathSecrProduction ([bool]$body.Valid) "Body comparison was rejected: $($body.Errors -join '; ')."
  Assert-MathSecrProduction ($search.Projection.Url -ceq $Session.paper.url) 'Select evidence belongs to another paper URL.'
  return [pscustomobject]@{
    Valid=$true; Step='Select'; SourceProblemNumber=$Target.number; OccurrenceKey=$Target.occurrenceKey
    CandidateId=$Target.selectedId; Resolution=$resolution; SearchObservation=$search.Projection
    SourceRenderSha256=$Target.bodyComparisonReceipt.sourceRenderSha256
    CandidateRenderSha256=$Target.bodyComparisonReceipt.candidateRenderSha256
    TruthScope='receipt-structure-and-artifact-identity-only'
  }
}

function Get-MathSecrProductionPersistedCapture {
  param([pscustomobject]$Session, [string]$ProjectRoot)
  Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $Session @('persistedCardObservationArtifact','persistedCards')) 'AfterReload requires the final persisted-card observation artifact.'
  $full=Get-MathSecrProductionArtifact $Session.persistedCardObservationArtifact $ProjectRoot
  $capture=ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $full -Raw -Encoding UTF8)
  $null=Get-MathSecrProductionArtifact $Session.persistedCardObservationArtifact $ProjectRoot
  Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $capture @('schemaVersion','captureId','collectorVersion','surface','capturedAtUtc','url','title','readEvidenceId','cards')) 'Persisted-card capture provenance or ordered cards are missing.'
  Assert-MathSecrProduction ((Test-IsStrictInteger $capture.schemaVersion) -and $capture.schemaVersion -eq 1 -and $capture.surface -is [string] -and $capture.surface -ceq 'aside-repl') 'Persisted-card capture schema or surface is invalid.'
  Assert-MathSecrProduction ((Test-MathSecrObservationToken $capture.captureId) -and (Test-MathSecrObservationToken $capture.collectorVersion) -and (Test-MathSecrObservationToken $capture.readEvidenceId) -and (Test-MathSecrObservationTimestamp $capture.capturedAtUtc) -and (Test-MathSecrObservationText $capture.title)) 'Persisted-card capture provenance has invalid field types or values.'
  Assert-MathSecrProduction ($capture.url -is [string] -and $capture.url -ceq $Session.paper.url) 'Persisted-card capture belongs to another paper URL.'
  Assert-MathSecrProduction ($capture.cards -is [array] -and $Session.persistedCards -is [array] -and $capture.cards.Count -eq $Session.persistedCards.Count) 'Persisted cards do not cover the full ordered capture.'
  for($i=0;$i -lt $capture.cards.Count;$i++) {
    $observed=$capture.cards[$i];$local=$Session.persistedCards[$i]
    Assert-MathSecrProduction ((Test-MathSecrSearchRequiredProperties $observed @('problemId','rawVisibleDbName')) -and (Test-MathSecrSearchRequiredProperties $local @('problemId','rawVisibleDbName'))) 'Captured and local persisted cards require their actual ID and raw visible DB name.'
    Assert-MathSecrProduction ((Test-IsCanonicalId $observed.problemId) -and $observed.rawVisibleDbName -is [string] -and -not [string]::IsNullOrWhiteSpace($observed.rawVisibleDbName) -and $observed.rawVisibleDbName -notmatch '[\r\n]') 'Captured card identity or raw visible DB name is invalid.'
    Assert-MathSecrProduction ($local.problemId -is [string] -and $local.problemId -ceq $observed.problemId -and $local.rawVisibleDbName -is [string] -and $local.rawVisibleDbName -ceq $observed.rawVisibleDbName) 'Persisted card ID, order or raw visible DB name differs from the final capture.'
  }
  return $capture
}

function ConvertTo-MathSecrProductionSourceRoot {
  param([string]$RawVisibleDbName)
  $root = ($RawVisibleDbName -split '>', 2)[0].Trim()
  $root = ($root -replace '^\s*[0-9]{4}\s*(?:년(?:도)?\s*)?(?:\([^)]*학년도\)\s*)?', '').Trim()
  # Only an organization root is folded. A textbook mentioning an organization
  # later in its title is retained as that textbook's visible root.
  if ($root -match '^(?:한국교육과정)?평가원(?:\s|$)') { return '평가원' }
  if ($root -match '^(?:[가-힣]+(?:시|도|특별시|광역시|특별자치시|특별자치도))?교육청(?:\s|$)') { return '교육청' }
  Assert-MathSecrProduction (-not [string]::IsNullOrWhiteSpace($root)) 'A visible DB name has no source root.'
  return $root
}

function Get-MathSecrProductionReportProjection {
  param([pscustomobject]$Session, [pscustomobject]$StateResult, [string]$ProjectRoot)
  Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $Session @('persistedCards','failureReportPdf')) 'AfterReload requires actual persisted cards and the failure PDF field.'
  Assert-MathSecrProduction ($Session.persistedCards -is [array]) 'Persisted cards must be an ordered array.'
  Assert-MathSecrProduction ($StateResult.State -ceq 'REPORT' -and $StateResult.Status -cin @('완료','부분 완료','검색 완료/0선택')) "AfterReload state is not reportable: $($StateResult.State)/$($StateResult.Status). $($StateResult.EvidenceErrors -join '; ')"
  $capture=Get-MathSecrProductionPersistedCapture $Session $ProjectRoot
  $selectedNumbers = @($StateResult.SelectedSourceNumbers)
  Assert-MathSecrProduction ($selectedNumbers.Count -eq $StateResult.PersistedCount -and $Session.persistedCards.Count -eq $StateResult.PersistedCount) 'Persisted card count differs from validated selected occurrences.'
  $successful = @($Session.snapshot.targets | Where-Object { $number=$_.number; @($selectedNumbers | Where-Object { $_ -ceq $number }).Count -eq 1 })
  Assert-MathSecrProduction ($successful.Count -eq $selectedNumbers.Count) 'Validated selections do not map one-to-one to original occurrences.'
  $sourceRecords = [Collections.Generic.List[object]]::new()
  $groups = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  for ($i=0; $i -lt $Session.persistedCards.Count; $i++) {
    $card=$Session.persistedCards[$i]; $target=$successful[$i]
    Assert-MathSecrProduction (Test-MathSecrSearchRequiredProperties $card @('problemId','occurrenceKey','rawVisibleDbName')) 'Persisted card identity and raw visible DB name are required.'
    Assert-MathSecrProduction ((Test-IsCanonicalId $card.problemId) -and (Test-IsCanonicalOccurrenceKey $card.occurrenceKey) -and $card.problemId -ceq $StateResult.PersistedIds[$i] -and $card.problemId -ceq $target.selectedId -and $card.occurrenceKey -ceq $target.occurrenceKey) 'Persisted card order or occurrence identity differs from the validated bundle.'
    Assert-MathSecrProduction ($card.rawVisibleDbName -is [string] -and -not [string]::IsNullOrWhiteSpace($card.rawVisibleDbName) -and $card.rawVisibleDbName -notmatch '[\r\n]') 'Actual raw visible DB name is missing.'
    $root=ConvertTo-MathSecrProductionSourceRoot $capture.cards[$i].rawVisibleDbName
    $sourceRecords.Add([pscustomobject]@{SourceProblemNumber=$target.number;OccurrenceKey=$target.occurrenceKey;ProblemId=$card.problemId;RawVisibleDbName=$card.rawVisibleDbName;Source=$root})
    if (-not $groups.ContainsKey($root)) { $groups[$root]=[pscustomobject]@{Name=$root;Count=0;FirstOrder=$i} }
    $groups[$root].Count++
  }
  $sources=@($groups.Values | Sort-Object @{Expression='Count';Descending=$true}, @{Expression='FirstOrder';Descending=$false} | Select-Object -First 3)
  $failed=@($Session.sourceTargets | Where-Object { $number=$_.number; @($selectedNumbers | Where-Object { $_ -ceq $number }).Count -eq 0 } | ForEach-Object { $_.number })
  $original=$Session.sourceTargets.Count; $success=$StateResult.PersistedCount
  Assert-MathSecrProduction ($failed.Count -eq ($original-$success)) 'Failure rows do not cover the remaining original occurrences.'
  $diagnosed=@($StateResult.ClosedMissedSourceNumbers)+@($StateResult.UnresolvedSourceNumbers)
  Assert-MathSecrProduction ($diagnosed.Count -eq $failed.Count) 'Every failed occurrence needs a closed-miss or unresolved diagnosis.'
  foreach($number in $failed){Assert-MathSecrProduction (@($diagnosed | Where-Object {$_ -ceq $number}).Count -eq 1) 'A failed occurrence has a missing or duplicate diagnosis.'}
  Assert-MathSecrProduction ($Session.failureReportPdf -is [string]) 'failureReportPdf must be a path or the exact 없음 sentinel.'
  if ($failed.Count -eq 0) {
    Assert-MathSecrProduction ($Session.failureReportPdf -ceq '없음') 'A complete session must use failureReportPdf 없음.'
  } else {
    Assert-MathSecrProduction ($Session.failureReportPdf -cne '없음' -and [IO.Path]::IsPathRooted($Session.failureReportPdf)) 'Per-problem failures require the actual absolute crop-report PDF path.'
  }
  return [pscustomobject]@{
    SchemaVersion=1; SessionId=$Session.sessionId; Status=$StateResult.Status
    SourceTargets=@($Session.sourceTargets); SourceRosterArtifact=$Session.sourceRosterArtifact
    PersistedCardObservationArtifact=$Session.persistedCardObservationArtifact
    PersistedCardCapture=[pscustomobject]@{CaptureId=$capture.captureId;CollectorVersion=$capture.collectorVersion;Surface=$capture.surface;CapturedAtUtc=$capture.capturedAtUtc;Url=$capture.url;Title=$capture.title;ReadEvidenceId=$capture.readEvidenceId}
    PaperName=$Session.paper.name; PaperUrl=$Session.paper.url
    OriginalCount=$original; SuccessCount=$success; FailureCount=($original-$success)
    FailedNumbers=$failed; FailureReportPdf=$Session.failureReportPdf; Sources=$sources; SourceAggregation=@($sourceRecords)
    SelectedIds=@($StateResult.SelectedIds); DraftIds=@($StateResult.DraftIds); PersistedIds=@($StateResult.PersistedIds)
    ClosedMissedSourceNumbers=@($StateResult.ClosedMissedSourceNumbers)
    UnresolvedSourceNumbers=@($StateResult.UnresolvedSourceNumbers); UnresolvedReasons=@($StateResult.UnresolvedReasons)
    SelectionBeforeNextIds=@($StateResult.SelectionBeforeNextIds)
    TruthScope='receipt-structure-and-artifact-identity-only'
  }
}

function New-MathSecrProductionUserSummary {
  param([pscustomobject]$Projection)
  $failureText=if ($Projection.FailedNumbers.Count -eq 0) { '없음' } else { (@($Projection.FailedNumbers | ForEach-Object { "${_}번" }) -join ', ') }
  $pdfText=if ($Projection.FailureReportPdf -ceq '없음') { '- 없음' } else { "- [실패 문제 보고서 PDF](<$($Projection.FailureReportPdf)>)" }
  $sourceText=if ($Projection.Sources.Count -eq 0) { '   1. 없음' } else {
    $rows=@(); for ($i=0; $i -lt $Projection.Sources.Count; $i++) { $rows+="   $($i+1). $($Projection.Sources[$i].Name) — $($Projection.Sources[$i].Count)문제" }; $rows -join "`n"
  }
  return @"
0. 제작한 문제지 링크
   - [$($Projection.PaperName)]($($Projection.PaperUrl))
1. 성공한 문제 $($Projection.SuccessCount)문제/$($Projection.OriginalCount)문제
2. 실패한 문제 $($Projection.FailureCount)문제/$($Projection.OriginalCount)문제
   1. $failureText
3. 실패한 문제 이미지 크롭 보고서 PDF
   $pdfText
4. 출처
$sourceText
"@
}

function Invoke-MathSecrProductionStep {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][ValidateSet('Select','BeforeNext','AfterReload')][string]$Step,
    [Parameter(Mandatory=$true)][pscustomobject]$InputObject,
    [string]$ProjectRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$TargetOccurrenceKey,
    [int]$HistoryDepth=0)
  $ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot)
  if ($Step -ceq 'Select') { return Test-MathSecrProductionSelection -Session $InputObject -TargetOccurrenceKey $TargetOccurrenceKey -ProjectRoot $ProjectRoot }
  Assert-MathSecrProduction ([string]::IsNullOrEmpty($TargetOccurrenceKey)) 'TargetOccurrenceKey is allowed only for Select.'
  Assert-MathSecrProductionRoster $InputObject $ProjectRoot
  $appendProperty=$InputObject.snapshot.PSObject.Properties['editAppendReceipt']
  $priorValidation=$null
  if ($null -ne $appendProperty) {
    Assert-MathSecrProduction ($Step -ceq 'AfterReload' -and $HistoryDepth -ge 0 -and $HistoryDepth -lt 64) 'Edit append requires AfterReload and a bounded prior-session history.'
    $priorPath=Get-MathSecrProductionArtifact $appendProperty.Value.priorSessionArtifact $ProjectRoot
    $priorSession=ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $priorPath -Raw -Encoding UTF8)
    $null=Get-MathSecrProductionArtifact $appendProperty.Value.priorSessionArtifact $ProjectRoot
    Assert-MathSecrProduction ($priorSession.sessionId -is [string] -and $priorSession.sessionId -ceq $InputObject.sessionId -and
      $priorSession.paper.url -is [string] -and $priorSession.paper.url -ceq $InputObject.paper.url -and
      $priorSession.paper.name -is [string] -and $priorSession.paper.name -ceq $InputObject.paper.name -and
      $priorSession.sourceRosterArtifact.path -is [string] -and $priorSession.sourceRosterArtifact.path -ceq $InputObject.sourceRosterArtifact.path -and
      $priorSession.sourceRosterArtifact.sha256 -is [string] -and [string]::Equals($priorSession.sourceRosterArtifact.sha256,$InputObject.sourceRosterArtifact.sha256,[StringComparison]::OrdinalIgnoreCase)) 'Edit append prior session has another session, paper or fixed roster.'
    # Recompute the full prior production boundary. A cached Valid flag or a
    # state-only success cannot replace its persisted capture and PDF gates.
    $priorValidation=Invoke-MathSecrProductionStep -Step AfterReload -InputObject $priorSession -ProjectRoot $ProjectRoot -HistoryDepth ($HistoryDepth+1)
  }
  $state=Invoke-MathSecrStateMachine -Snapshot $InputObject.snapshot -Phase $Step -ProjectRoot $ProjectRoot
  foreach($evidence in @($state.SelectionEvidence)) {
    Assert-MathSecrProduction ($evidence.SearchObservation.Url -ceq $InputObject.paper.url) 'Selection evidence belongs to another paper URL.'
  }
  if ($Step -ceq 'BeforeNext') {
    Assert-MathSecrProduction ($state.State -ceq 'PRE_NEXT_GATE' -and $state.Status -ceq 'ready-for-next' -and $state.CanNextStep -eq $true) "BeforeNext rejected: $($state.State)/$($state.Status)."
    return [pscustomobject]@{Valid=$true;Step=$Step;StateResult=$state;TruthScope='receipt-structure-and-artifact-identity-only'}
  }
  $projection=Get-MathSecrProductionReportProjection $InputObject $state $ProjectRoot
  if ($null -ne $priorValidation) {
    $append=Test-MathSecrEditAppendReceipt $InputObject.snapshot $state.SelectedIds @($state.SelectedSourceNumbers | ForEach-Object {$number=$_;@($InputObject.snapshot.targets | Where-Object {$_.number -ceq $number})[0].occurrenceKey}) $ProjectRoot 0
    Assert-MathSecrProduction ($append.Valid -and $append.PaperUrl -ceq $InputObject.paper.url) 'Edit append receipt is not bound to the current paper.'
    Assert-MathSecrProduction ([DateTimeOffset]::Parse($projection.PersistedCardCapture.CapturedAtUtc,[Globalization.CultureInfo]::InvariantCulture) -ge [DateTimeOffset]::Parse($append.DraftCapturedAtUtc,[Globalization.CultureInfo]::InvariantCulture)) 'Edit append persisted capture predates the confirmed draft.'
    Assert-MathSecrProduction ($projection.PersistedCardCapture.CaptureId -cne $priorValidation.ReportProjection.PersistedCardCapture.CaptureId -and $projection.PersistedCardCapture.ReadEvidenceId -cne $priorValidation.ReportProjection.PersistedCardCapture.ReadEvidenceId) 'Edit append reused the prior persisted read identity.'
  }
  $summary=New-MathSecrProductionUserSummary $projection
  $null=Invoke-MathSecrUserSummaryLint -Text $summary -ExpectedProjection $projection
  return [pscustomobject]@{Valid=$true;Step=$Step;StateResult=$state;ReportProjection=$projection;UserSummary=$summary;TruthScope=$projection.TruthScope}
}

function Invoke-MathSecrTypedUserSummaryLint {
  param([string]$Text, [pscustomobject]$Session, [string]$ProjectRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
  $validated=Invoke-MathSecrProductionStep -Step AfterReload -InputObject $Session -ProjectRoot $ProjectRoot
  return Invoke-MathSecrUserSummaryLint -Text $Text -ExpectedProjection $validated.ReportProjection
}
