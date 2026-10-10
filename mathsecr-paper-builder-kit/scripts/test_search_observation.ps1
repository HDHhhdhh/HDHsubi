[CmdletBinding()]
param(
  [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [ValidateSet('All','Contract','Collector','CuaRestricted')][string]$Case = 'All',
  [string]$NodePath = 'node',
  [string]$PlaywrightModule,
  [string]$BrowserPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'search_observation_contract.ps1')
$KitRoot = Join-Path $ProjectRoot 'mathsecr-paper-builder-kit'

function Read-ObservationTestJson {
  param([string]$Json)
  if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $Json -DateKind String }
  return ConvertFrom-Json -InputObject $Json
}
function Copy-ObservationTestPacket {
  param($Value)
  return Read-ObservationTestJson (ConvertTo-Json -InputObject $Value -Depth 30 -Compress)
}
function New-ObservationTestPacket {
  $criteria = [pscustomobject]@{ scopeMode='내 문제지'; sourceChips=@('교육청, 평가원'); filterChips=@('대수'); chips=@(
    [pscustomobject]@{kind='text';value='직선'}, [pscustomobject]@{kind='text';value='곡선'}) }
  $observations = @()
  foreach ($i in 0..3) {
    $observations += [pscustomobject]@{
      schemaVersion=1; collectorVersion='mathsecr-search-observation-v1'; adapterId='synthetic-adapter'; adapterEvidenceId='synthetic-control-map'
      attemptId='attempt-1'; submitId=$(if ($i -eq 0) { $null } else { 'submit-1' }); readEvidenceId="synthetic-read-$i"
      raw=[pscustomobject]@{
        captureId="capture-$i"; capturedAtUtc=('2026-09-05T12:00:0{0}.000Z' -f $i); timeOriginMs=1000; monotonicMs=($i+1)
        url='https://www.mathsecr.com/mypaper/1'; title='Synthetic fixture'; criteria=(Copy-ObservationTestPacket $criteria); scopeSelectionConfirmed=$true
        result=[pscustomobject]@{ count=2; orderedIds=@('ID-A','ID-B'); loading=$false; observedSubmitId=$null; observedCriteriaKey=$null }
      }
    }
  }
  return [pscustomobject]@{
    schemaVersion=1; attemptId='attempt-1'; submission=[pscustomobject]@{
      submitId='submit-1'; actionEvidenceId='synthetic-search-click'; action='검색하기'; surface='offline-dom-test'
      completedAtUtc='2026-09-05T12:00:00.500Z'; url='https://www.mathsecr.com/mypaper/1'; criteria=$criteria; resultCriteriaKey=$null
    }
    beforeSubmit=$observations[0]; observations=@($observations[1],$observations[2],$observations[3])
  }
}
function Convert-ObservationTestPacketToDateProfile {
  param($Packet)
  foreach ($o in @($Packet.beforeSubmit) + $Packet.observations) {
    $o.schemaVersion=2; $o.collectorVersion='mathsecr-search-observation-v2'
    $o.raw.PSObject.Properties.Remove('timeOriginMs'); $o.raw.PSObject.Properties.Remove('monotonicMs')
    $o.raw.captureId=$o.readEvidenceId
    $o.raw | Add-Member -NotePropertyName clockSource -NotePropertyValue 'date-now'
    $o.raw | Add-Member -NotePropertyName captureSource -NotePropertyValue 'read-evidence-id'
    $o.raw | Add-Member -NotePropertyName wallClockMs -NotePropertyValue ([datetimeoffset]::Parse($o.raw.capturedAtUtc).ToUnixTimeMilliseconds())
  }
  return $Packet
}
$script:Checks = 0
function Assert-Observation {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "FAIL Search Observation: $Name" }
  $script:Checks++
}
function Assert-ObservationRejected {
  param([string]$Name, [scriptblock]$Mutate, [string]$ErrorPattern, [switch]$DateProfile)
  $packet = New-ObservationTestPacket
  if ($DateProfile) { $packet = Convert-ObservationTestPacketToDateProfile $packet }
  & $Mutate $packet
  $result = Test-MathSecrSearchObservation -Packet $packet
  Assert-Observation (-not $result.FreshResultVerified) $Name
  if ($ErrorPattern) { Assert-Observation (($result.Errors -join '; ') -match $ErrorPattern) "$Name reason" }
}

if ($Case -in @('All','Contract')) {
  foreach ($invalid in @($null, [pscustomobject]@{}, 1, 'invalid')) {
    Assert-Observation (-not (Test-MathSecrSearchObservation -Packet $invalid).SchemaValid) 'invalid root value fails closed'
  }
  $p = New-ObservationTestPacket
  $p.observations = @($p.observations | Select-Object -First 2)
  $r = Test-MathSecrSearchObservation -Packet $p -AttemptId 'attempt-1' -Chips @('직선','곡선') -ResultCount 2
  Assert-Observation ($r.FreshResultVerified -and $r.RequiredReadCount -eq 2) 'normal two independent reads'
  Assert-Observation ($r.Projection.OrderedVisibleIds[0] -ceq 'ID-A' -and -not $r.Projection.BodyExactVerified -and
    -not $r.Projection.BackendCausalityVerified -and -not $r.Projection.CompleteCoverageVerified) 'projection preserves records and limits'
  $projection = ConvertTo-MathSecrSearchObservationReportProjection -Packet $p
  Assert-Observation (($projection.ReadEvidenceIds -join ',') -ceq 'synthetic-read-1,synthetic-read-2') 'same record projection'
  foreach ($binding in @(@{AttemptId='wrong'}, @{Chips=@('곡선','직선')}, @{ResultCount=3}, @{ResultCount='2'})) {
    Assert-Observation (-not (Test-MathSecrSearchObservation -Packet $p @binding).FreshResultVerified) 'expected binding mismatch'
  }
  foreach ($risk in @('scope','zero','partial')) {
    $p = New-ObservationTestPacket
    switch ($risk) {
      'scope' { $p.beforeSubmit.raw.criteria.filterChips = @('이전 필터') }
      'zero' { foreach ($o in $p.observations) { $o.raw.result.count=0; $o.raw.result.orderedIds=@() } }
      'partial' { foreach ($o in $p.observations) { $o.raw.result.count=83; $o.raw.result.orderedIds=@('ID-A') } }
    }
    $r = Test-MathSecrSearchObservation -Packet $p
    Assert-Observation ($r.FreshResultVerified -and $r.RequiredReadCount -eq 3) "$risk requires and accepts three reads"
    $p.observations = @($p.observations | Select-Object -First 2)
    Assert-Observation (-not (Test-MathSecrSearchObservation -Packet $p).FreshResultVerified) "$risk rejects two reads"
  }
  $p = New-ObservationTestPacket
  $fourth = Copy-ObservationTestPacket $p.observations[2]
  $fourth.readEvidenceId='synthetic-read-4'; $fourth.raw.captureId='capture-4'; $fourth.raw.monotonicMs=5; $fourth.raw.capturedAtUtc='2026-09-05T12:00:04.000Z'
  $p.observations += $fourth
  $p.observations[0].raw.result.count=0; $p.observations[0].raw.result.orderedIds=@()
  Assert-Observation (Test-MathSecrSearchObservation -Packet $p).FreshResultVerified 'transient zero then three stable reads'
  $p = New-ObservationTestPacket
  foreach ($o in @($p.beforeSubmit) + $p.observations) { $o.raw.criteria.sourceChips=@(); $o.raw.criteria.scopeMode='전체 DB' }
  $p.submission.criteria.sourceChips=@(); $p.submission.criteria.scopeMode='전체 DB'
  Assert-Observation (Test-MathSecrSearchObservation -Packet $p).FreshResultVerified 'explicit whole DB may omit source chip'

  Assert-ObservationRejected 'replayed record' { param($p) $p.observations[1]=$p.observations[0] } 'replayed'
  Assert-ObservationRejected 'replayed capture ID' { param($p) $p.observations[1].raw.captureId=$p.observations[0].raw.captureId } 'replayed'
  Assert-ObservationRejected 'replayed read ID' { param($p) $p.observations[1].readEvidenceId=$p.observations[0].readEvidenceId } 'replayed'
  Assert-ObservationRejected 'copied raw with new wrapper read ID' { param($p) $p.observations[1].raw=Copy-ObservationTestPacket $p.observations[0].raw } 'replayed'
  Assert-ObservationRejected 'copied clock with new identities' { param($p) $p.observations[1].raw.monotonicMs=$p.observations[0].raw.monotonicMs } 'clock|replayed'
  Assert-ObservationRejected 'action receipt reused' { param($p) $p.observations[0].readEvidenceId=$p.submission.actionEvidenceId } 'action evidence'
  Assert-ObservationRejected 'pre-submit time' { param($p) $p.observations[0].raw.capturedAtUtc='2026-09-05T12:00:00.100Z' } 'pre-submit'
  Assert-ObservationRejected 'baseline after submit' { param($p) $p.beforeSubmit.raw.capturedAtUtc='2026-09-05T12:00:00.900Z' } 'beforeSubmit'
  Assert-ObservationRejected 'baseline carries submit ID' { param($p) $p.beforeSubmit.submitId='submit-1' } 'beforeSubmit'
  Assert-ObservationRejected 'wrong submit' { param($p) $p.observations[0].submitId='old-submit' } 'submit identity'
  Assert-ObservationRejected 'wrong attempt' { param($p) $p.observations[0].attemptId='old-attempt' } 'binding drift'
  Assert-ObservationRejected 'wrong URL' { param($p) $p.observations[0].raw.url='https://example.invalid/' } 'binding drift'
  Assert-ObservationRejected 'wrong title' { param($p) $p.observations[0].raw.title='old-title' } 'binding drift'
  Assert-ObservationRejected 'adapter drift' { param($p) $p.observations[0].adapterEvidenceId='old-map' } 'binding drift'
  Assert-ObservationRejected 'document navigation clock drift' { param($p) $p.observations[0].raw.timeOriginMs=9999 } 'clock'
  Assert-ObservationRejected 'query drift' { param($p) $p.observations[0].raw.criteria.chips[0].value='새 단서' } 'criteria drift'
  Assert-ObservationRejected 'pre-submit query drift' { param($p) $p.beforeSubmit.raw.criteria.chips[0].value='이전 단서' } 'committed chips'
  Assert-ObservationRejected 'scope not selected' { param($p) $p.observations[0].raw.scopeSelectionConfirmed=$false } 'scope control'
  Assert-ObservationRejected 'empty scope not whole DB' { param($p) foreach ($o in $p.observations) { $o.raw.criteria.sourceChips=@() }; $p.submission.criteria.sourceChips=@() } 'empty source scope'
  Assert-ObservationRejected 'native stale submit identity' { param($p) $p.observations[0].raw.result.observedSubmitId='old-submit' } 'stale'
  Assert-ObservationRejected 'native stale criteria identity' { param($p) $p.observations[0].raw.result.observedCriteriaKey='old-criteria' } 'stale'
  Assert-ObservationRejected 'unstable order' { param($p) $p.observations[2].raw.result.orderedIds=@('ID-B','ID-A') } 'stable result'
  Assert-ObservationRejected 'loading tail' { param($p) $p.observations[2].raw.result.loading=$true } 'stable result'
  Assert-ObservationRejected 'duplicate candidate ID' { param($p) $p.observations[0].raw.result.orderedIds=@('ID-A','ID-A') } 'duplicate'
  Assert-ObservationRejected 'more cards than count' { param($p) $p.observations[0].raw.result.count=1 } 'exceeds'
  Assert-ObservationRejected 'positive count no candidates' { param($p) foreach ($o in $p.observations) { $o.raw.result.orderedIds=@() } } 'no visible candidate'
  foreach ($change in @(
    { param($p) $p.schemaVersion='1' }, { param($p) $p.observations[0].raw.result.count='2' },
    { param($p) $p.observations[0].raw.result.count=2.0 }, { param($p) $p.observations[0].raw.result.loading='false' },
    { param($p) $p.observations[0].raw.scopeSelectionConfirmed=1 }, { param($p) $p.observations[0].raw.monotonicMs='2' },
    { param($p) $p.observations[0].raw.capturedAtUtc=[datetime]'2026-09-05T12:00:01Z' },
    { param($p) $p.observations[0].raw.result.orderedIds=@(' ID-A','ID-B') },
    { param($p) $p.observations[0].raw.result.orderedIds=@('없음','ID-B') },
    { param($p) $p | Add-Member -NotePropertyName freshResultVerified -NotePropertyValue $true }
  )) { Assert-ObservationRejected 'strict malformed field' $change 'schema' }
  $p = New-ObservationTestPacket
  foreach ($o in @($p.beforeSubmit) + $p.observations) { $o.raw.result.orderedIds=@('ID-A','id-a') }
  Assert-Observation (Test-MathSecrSearchObservation -Packet $p).FreshResultVerified 'ordinal candidate IDs preserve case'
  $p.observations=@()
  $blocked=$false
  try { $null = ConvertTo-MathSecrSearchObservationReportProjection -Packet $p } catch { $blocked=$true }
  Assert-Observation $blocked 'invalid projection throws'
  $p = Convert-ObservationTestPacketToDateProfile (New-ObservationTestPacket)
  $p.observations = @($p.observations | Select-Object -First 2)
  $r = Test-MathSecrSearchObservation -Packet $p -AttemptId 'attempt-1' -Chips @('직선','곡선') -ResultCount 2
  Assert-Observation ($r.FreshResultVerified -and $r.RequiredReadCount -eq 2) 'explicit Date profile two reads'
  Assert-Observation ($r.Projection.ClockSource -ceq 'date-now' -and $r.Projection.CaptureSource -ceq 'read-evidence-id' -and
    -not $r.Projection.MonotonicClockVerified -and -not $r.Projection.DocumentClockContinuityVerified) 'Date profile exposes weaker clock claims'
  $p.observations[1].raw.capturedAtUtc=$p.observations[0].raw.capturedAtUtc
  $p.observations[1].raw.wallClockMs=$p.observations[0].raw.wallClockMs
  Assert-Observation (Test-MathSecrSearchObservation -Packet $p).FreshResultVerified 'Date resolution collision with distinct receipts is allowed'
  Assert-ObservationRejected 'Date replayed actual read receipt' { param($p) $p.observations[1].readEvidenceId=$p.observations[0].readEvidenceId; $p.observations[1].raw.captureId=$p.observations[0].raw.captureId } 'replayed' -DateProfile
  Assert-ObservationRejected 'Date action evidence reuse' { param($p) $p.observations[0].readEvidenceId=$p.submission.actionEvidenceId; $p.observations[0].raw.captureId=$p.submission.actionEvidenceId } 'action evidence' -DateProfile
  Assert-ObservationRejected 'Date capture source falsely claims UUID' { param($p) $p.observations[0].raw.captureSource='crypto.randomUUID' } 'schema' -DateProfile
  Assert-ObservationRejected 'Date clock source falsely claims performance' { param($p) $p.observations[0].raw.clockSource='performance' } 'schema' -DateProfile
  foreach ($field in @('clockSource','captureSource')) {
    $profileText = if ($field -ceq 'clockSource') { 'date-now' } else { 'read-evidence-id' }
    foreach ($invalid in @(
      [pscustomobject]@{Name='Boolean true'; Value=$true},
      [pscustomobject]@{Name='Boolean false'; Value=$false},
      [pscustomobject]@{Name='singleton correct-text array'; Value=@($profileText)},
      [pscustomobject]@{Name='duplicate correct-text array'; Value=@($profileText,$profileText)},
      [pscustomobject]@{Name='empty array'; Value=@()},
      [pscustomobject]@{Name='integer'; Value=1},
      [pscustomobject]@{Name='null'; Value=$null}
    )) {
      $p = Convert-ObservationTestPacketToDateProfile (New-ObservationTestPacket)
      $p.observations[0].raw.$field = $invalid.Value
      $r = Test-MathSecrSearchObservation -Packet $p
      Assert-Observation (-not $r.SchemaValid -and -not $r.FreshResultVerified) ("Date $field rejects non-string " + $invalid.Name)
    }
  }
  Assert-ObservationRejected 'Date fabricated capture ID' { param($p) $p.observations[0].raw.captureId='invented-uuid' } 'schema' -DateProfile
  Assert-ObservationRejected 'Date fabricated monotonic clock' { param($p) $p.observations[0].raw | Add-Member -NotePropertyName monotonicMs -NotePropertyValue 2 } 'schema' -DateProfile
  Assert-ObservationRejected 'Date timestamp differs from actual milliseconds' { param($p) $p.observations[0].raw.wallClockMs++ } 'schema' -DateProfile
  Assert-ObservationRejected 'Date numeric string rejected' { param($p) $p.observations[0].raw.wallClockMs=[string]$p.observations[0].raw.wallClockMs } 'schema' -DateProfile
  Assert-ObservationRejected 'Date clock regression rejected' { param($p) $p.observations[1].raw.capturedAtUtc='2026-09-05T12:00:00.900Z'; $p.observations[1].raw.wallClockMs=[datetimeoffset]::Parse($p.observations[1].raw.capturedAtUtc).ToUnixTimeMilliseconds() } 'clock' -DateProfile
  Assert-ObservationRejected 'mixed capture profiles rejected' { param($p) $p.observations[1]=(New-ObservationTestPacket).observations[1] } 'profile drift' -DateProfile
  Write-Output "PASS Search Observation Contract: $script:Checks checks; source_mode=offline-contract; normal2/risk3, strict schema, replay/drift rejection, bounded claims"
}

if ($Case -in @('All','CuaRestricted')) {
  $temp = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-search-observation-' + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Path $temp
  try {
    $scriptPath = Join-Path $temp 'cua-restricted-test.cjs'
    $packetPath = Join-Path $temp 'cua-packet.json'
    $js = @'
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
const element = (textContent, attrs = {}, order = 0) => ({textContent, isConnected:true,
  getAttribute:name=>attrs[name]??null, getClientRects:()=>[{}], closest:()=>null, order});
const dom = {'#mode':[element('내 문제지')], '#source':[element('교육청, 평가원')],
  '#selected':[element('', {'aria-checked':'true'})], '#count':[element('검색결과 : 2개')],
  '.chip':[element('직선',{},1),element('곡선',{},2)],
  '.card':[element('',{'data-id':'ID-A'}),element('',{'data-id':'ID-B'})]};
dom['.first-chip']=[dom['.chip'][0]]; dom['.second-chip']=[dom['.chip'][1]];
for (const nodes of Object.values(dom)) for (const el of nodes) el.matches=selector=>(dom[selector]??[]).includes(el);
const adapter = {id:'restricted-adapter', evidenceId:'restricted-dom-map',
  scopeMode:{selector:'#mode',read:'text'}, sourceChips:{selector:'#source',read:'text'},filterChips:null,
  selectedScopeChecks:[{selector:'#selected',read:'attribute',attribute:'aria-checked',equals:'true'}],
  queryChips:[{selector:'.second-chip',read:'text',kind:'text'},{selector:'.first-chip',read:'text',kind:'text'}],
  resultCount:{selector:'#count',read:'text',pattern:'^검색결과 : ([0-9]+)개$'},
  resultIds:{selector:'.card',read:'attribute',attribute:'data-id'},loading:null};
function read(index, overrides={}) {
  const input={adapter,context:{attemptId:'restricted-attempt',submitId:index===0?null:'restricted-submit',
    readEvidenceId:`restricted-tool-read-${index}`,clockSource:'date-now',captureSource:'read-evidence-id',...overrides}};
  const sandbox={globalThis:undefined,crypto:undefined,performance:undefined,window:{}, Date,
    location:{href:'https://www.mathsecr.com/mypaper/1'},
    document:{title:'Restricted synthetic DOM',querySelectorAll:selector=>[...new Set(selector.split(',').flatMap(part=>dom[part]??[]))].sort((a,b)=>a.order-b.order)},
    getComputedStyle:()=>({display:'block',visibility:'visible'}), input};
  assert.equal(vm.runInNewContext('[typeof globalThis,typeof crypto,typeof performance,typeof window.crypto,typeof window.performance].join(",")',sandbox),
    'undefined,undefined,undefined,undefined,undefined');
  return JSON.parse(JSON.stringify(vm.runInNewContext(source+'\ncollectMathSecrSearchObservation(input);',sandbox)));
}
(async()=>{
  assert.throws(()=>read(0,{clockSource:undefined,captureSource:undefined}),/capture UUID unavailable/);
  assert.throws(()=>read(0,{captureSource:undefined}),/unsupported explicit/);
  const before=read(0);
  const submission={submitId:'restricted-submit',actionEvidenceId:'restricted-search-click',action:'검색하기',
    surface:'offline-dom-test',completedAtUtc:new Date().toISOString(),url:before.raw.url,criteria:before.raw.criteria,resultCriteriaKey:null};
  const observations=[];
  for(let i=1;i<=2;i++) { await new Promise(resolve=>setTimeout(resolve,2)); observations.push(read(i)); }
  for(const item of [before,...observations]) {
    assert.equal(item.schemaVersion,2); assert.equal(item.raw.captureId,item.readEvidenceId);
    assert.equal(item.raw.capturedAtUtc,new Date(item.raw.wallClockMs).toISOString());
    assert.equal('monotonicMs' in item.raw,false); assert.equal('timeOriginMs' in item.raw,false);
    assert.deepEqual(item.raw.result.orderedIds,['ID-A','ID-B']);
    assert.deepEqual(item.raw.criteria.chips.map(chip=>chip.value),['직선','곡선']);
    assert.equal(typeof dom['.chip'][0].compareDocumentPosition,'undefined');
    assert.equal(typeof dom['.chip'][0].isSameNode,'undefined');
    assert.equal(typeof dom['.chip'][0].matches,'function');
  }
  fs.writeFileSync(process.argv[3],JSON.stringify({schemaVersion:1,attemptId:'restricted-attempt',submission,beforeSubmit:before,observations}));
  process.stdout.write('PASS CUA restricted collector: absent globals, actual Date reads, explicit receipt identities; synthetic DOM only\n');
})().catch(error=>{console.error(error);process.exitCode=1;});
'@
    [IO.File]::WriteAllText($scriptPath, $js, (New-Object Text.UTF8Encoding($false)))
    & $NodePath $scriptPath (Join-Path $PSScriptRoot 'search_observation.js') $packetPath
    if ($LASTEXITCODE -ne 0) { throw "Restricted collector subprocess failed with exit code $LASTEXITCODE" }
    $packet = Read-ObservationTestJson ([IO.File]::ReadAllText($packetPath))
    $result = Test-MathSecrSearchObservation -Packet $packet -AttemptId 'restricted-attempt' -Chips @('직선','곡선') -ResultCount 2
    Assert-Observation $result.FreshResultVerified ('restricted actual Date collector packet: ' + ($result.Errors -join '; '))
    Write-Output 'PASS Search Observation CUA Restricted Packet: DOM-only globals and Date/receipt v2 accepted; no live availability claim'
  } finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temp)
    $resolvedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemp.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTemp) -notlike 'mathsecr-search-observation-*') { throw 'Refusing cleanup outside the dedicated temp root.' }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}

if ($Case -in @('All','Collector')) {
  if (-not $PlaywrightModule) {
    $candidates = @((Join-Path $KitRoot 'node_modules/playwright'),
      (Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright'))
    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if ($found.Count -gt 0) { $PlaywrightModule = $found[0] }
  }
  if (-not $BrowserPath) {
    $candidates = @((Join-Path $env:ProgramFiles 'Google/Chrome/Application/chrome.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'))
    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if ($found.Count -gt 0) { $BrowserPath=$found[0] }
  }
  if (-not $PlaywrightModule -or -not $BrowserPath) { throw 'Collector DOM test requires Playwright module and a browser executable; pass -PlaywrightModule and -BrowserPath explicitly.' }
  $temp = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-search-observation-' + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Path $temp
  try {
    $packetPath = Join-Path $temp 'dom-packet.json'
    & $NodePath (Join-Path $KitRoot 'test-fixtures/search-observation/collector_dom_test.js') $PlaywrightModule $BrowserPath $packetPath
    if ($LASTEXITCODE -ne 0) { throw "Collector DOM subprocess failed with exit code $LASTEXITCODE" }
    $packet = Read-ObservationTestJson ([IO.File]::ReadAllText($packetPath))
    $result = Test-MathSecrSearchObservation -Packet $packet -AttemptId 'offline-attempt-1' -Chips @('공차','자연수') -ResultCount 8
    Assert-Observation ($result.FreshResultVerified -and $result.RequiredReadCount -eq 2) ('real collector packet contract: ' + ($result.Errors -join '; '))
    Write-Output 'PASS Search Observation Collector Packet: actual isolated browser DOM observations accepted by the PowerShell contract; no live MathSecr verification'
  } finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temp)
    $resolvedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemp.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTemp) -notlike 'mathsecr-search-observation-*') { throw 'Refusing cleanup outside the dedicated temp root.' }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
