param(
  [ValidateSet("All", "CoreRules", "DetectMissingRule", "SessionCoverage", "PromptDrift", "SyncContract")]
  [string]$Scenario = "All",
  [string]$ProjectRoot,
  [string]$CodexHome = $env:CODEX_HOME
)

$ErrorActionPreference = "Stop"

function Resolve-DefaultProjectRoot {
  $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
  $kitRoot = Split-Path -Parent $scriptDir
  return [System.IO.Path]::GetFullPath((Split-Path -Parent $kitRoot))
}

function Resolve-CodexHome {
  param([string]$InputPath)
  if ($InputPath) {
    return [System.IO.Path]::GetFullPath($InputPath)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $HOME ".codex"))
}

function Read-Doc {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing required document: $Path"
  }
  return Get-Content -LiteralPath $Path -Raw
}

function Assert-Contains {
  param(
    [string]$Name,
    [string]$Text,
    [string]$Needle
  )
  if (-not $Text.Contains($Needle)) {
    throw "[$Name] missing required rule marker: $Needle"
  }
}

function Assert-ContainsOnce {
  param(
    [string]$Name,
    [string]$Text,
    [string]$Needle
  )
  $escaped = [regex]::Escape($Needle)
  $count = ([regex]::Matches($Text, $escaped)).Count
  if ($count -ne 1) {
    throw "[$Name] required rule marker must appear exactly once: $Needle (found $count)"
  }
}

function Assert-NotContains {
  param(
    [string]$Name,
    [string]$Text,
    [string]$Needle
  )
  if ($Text.Contains($Needle)) {
    throw "[$Name] contains forbidden weakened wording: $Needle"
  }
}

function Assert-NotMatches {
  param(
    [string]$Name,
    [string]$Text,
    [string]$Pattern,
    [string]$Message
  )
  if ($Text -match $Pattern) {
    throw "[$Name] $Message"
  }
}

function Assert-TextEqual {
  param(
    [string]$Name,
    [string]$Actual,
    [string]$Expected
  )
  $normalizedActual = ($Actual -replace "`r`n", "`n") -replace "`r", "`n"
  $normalizedExpected = ($Expected -replace "`r`n", "`n") -replace "`r", "`n"
  if ($normalizedActual -cne $normalizedExpected) {
    throw "[$Name] documents are out of sync"
  }
}

function Assert-FileExists {
  param([string]$Name, [string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "[$Name] missing source file: $Path"
  }
}

function Assert-SearchAttemptSsotConsumer {
  param(
    [string]$Name,
    [string]$Text
  )
  Assert-ContainsOnce $Name $Text "<!-- SEARCH_ATTEMPT_SSOT_REF -->"
  Assert-NotContains $Name $Text "<!-- SEARCH_ATTEMPT_HUMAN_SSOT:START -->"
  Assert-NotContains $Name $Text "<!-- SEARCH_ATTEMPT_HUMAN_SSOT:END -->"
  foreach ($duplicate in @(
    'literal-body',
    'literal-printed-metadata',
    'literal-visible-ui-metadata',
    'semantic-inference',
    'verified-index-term',
    'CommonUnverifiedChips',
    'candidateRecoveryEvidence.coverage',
    't>0→양수',
    'overline{AB}→길이'
  )) {
    Assert-NotContains $Name $Text $duplicate
  }
}

function Assert-DbInferenceSsotConsumer {
  param(
    [string]$Name,
    [string]$Text
  )
  Assert-ContainsOnce $Name $Text "<!-- DB_INFERENCE_SSOT_REF -->"
  Assert-Contains $Name $Text "DB Inference And Official Collection Contract"
  Assert-NotContains $Name $Text "<!-- DB_INFERENCE_HUMAN_SSOT:START -->"
  Assert-NotContains $Name $Text "<!-- DB_INFERENCE_HUMAN_SSOT:END -->"
  foreach ($duplicate in @(
    'scopeKind=collection',
    '"blankProbe"',
    '"scopeLock"',
    '"scopedSearch"',
    '작업공간 > 교육청, 평가원',
    'month=<value>;grade=<value>'
  )) {
    Assert-NotContains $Name $Text $duplicate
  }
}

function Assert-MetadataRescueSsotConsumer {
  param(
    [string]$Name,
    [string]$Text
  )
  Assert-ContainsOnce $Name $Text "<!-- METADATA_RESCUE_SSOT_REF -->"
  Assert-Contains $Name $Text "Metadata Rescue And Lazy Coverage Contract"
  Assert-NotContains $Name $Text "<!-- METADATA_RESCUE_HUMAN_SSOT:START -->"
  Assert-NotContains $Name $Text "<!-- METADATA_RESCUE_HUMAN_SSOT:END -->"
  foreach ($duplicate in @(
    '`[Y-1,Y+1]`',
    'endReadSnapshots',
    'stableNoGrowthReads',
    'partitionKey',
    'month=<value>;grade=<value>',
    'cumulative unique inspected card IDs'
  )) {
    Assert-NotContains $Name $Text $duplicate
  }
}

function Assert-BodyExactSsotConsumer {
  param(
    [string]$Name,
    [string]$Text
  )
  Assert-ContainsOnce $Name $Text "<!-- BODY_EXACT_SSOT_REF -->"
  Assert-Contains $Name $Text "Body-Exact Selection Contract"
  Assert-NotContains $Name $Text "<!-- BODY_EXACT_HUMAN_SSOT:START -->"
  Assert-NotContains $Name $Text "<!-- BODY_EXACT_HUMAN_SSOT:END -->"
  foreach ($duplicate in @(
    '객관식 선지(①~⑤ answer choices)',
    '문제 본문, 조건, 도형/그래프/표, 수식',
    'sourceRenderArtifact',
    'candidateRenderArtifact'
  )) {
    Assert-NotContains $Name $Text $duplicate
  }
}

function Get-DocSet {
  param([string]$Root, [string]$CodexHomePath)
  $kitRoot = Join-Path $Root "mathsecr-paper-builder-kit"
  return @{
    RootAgents = Join-Path $Root "AGENTS.md"
    KitAgents = Join-Path $kitRoot "AGENTS.md"
    KitSkill = Join-Path $kitRoot "skills\mathsecr-paper-builder\SKILL.md"
    InstalledSkill = Join-Path $CodexHomePath "skills\mathsecr-paper-builder\SKILL.md"
    SuccessAlgorithm = Join-Path $kitRoot "docs\mathsecr_success_algorithm.md"
    StateMachine = Join-Path $kitRoot "scripts\state_machine.ps1"
    SearchAttemptContract = Join-Path $kitRoot "scripts\search_attempt_contract.ps1"
    SearchAttemptFixture = Join-Path $kitRoot "test-fixtures\search-attempts\goguk2-mid-q2.json"
    ReusablePrompt = Join-Path $kitRoot "prompts\mathsecr_new_paper_prompt.md"
    Readme = Join-Path $kitRoot "README.md"
  }
}

function Test-SyncContract {
  param([hashtable]$Docs)

  $rootAgents = Read-Doc $Docs.RootAgents
  $kitAgents = Read-Doc $Docs.KitAgents
  $kitSkill = Read-Doc $Docs.KitSkill
  $installedSkill = Read-Doc $Docs.InstalledSkill

  Assert-TextEqual "Root and kit AGENTS" $rootAgents $kitAgents
  Assert-TextEqual "Kit and installed SKILL" $kitSkill $installedSkill
  Assert-TextEqual "Synthetic newline normalization" "line1`r`nline2`r" "line1`nline2`n"

  $detected = $false
  try {
    Assert-TextEqual "Synthetic sync drift" "canonical" "drifted"
  } catch {
    $detected = $true
    Write-Host "SyncContract observed expected failure: $($_.Exception.Message)"
  }
  if (-not $detected) {
    throw "SyncContract failed to detect a document mismatch"
  }
  Write-Host "SyncContract PASS"
}

function Test-CoreRules {
  param([hashtable]$Docs)
  $rootAgents = Read-Doc $Docs.RootAgents
  $kitAgents = Read-Doc $Docs.KitAgents
  $kitSkill = Read-Doc $Docs.KitSkill
  $installedSkill = Read-Doc $Docs.InstalledSkill
  $successAlgorithm = Read-Doc $Docs.SuccessAlgorithm
  $stateMachine = Read-Doc $Docs.StateMachine
  $searchAttemptContract = Read-Doc $Docs.SearchAttemptContract
  $searchAttemptFixture = Read-Doc $Docs.SearchAttemptFixture
  $reusablePrompt = Read-Doc $Docs.ReusablePrompt
  $readme = Read-Doc $Docs.Readme

  foreach ($entry in @(
    @{ Name = "Root AGENTS"; Text = $rootAgents },
    @{ Name = "Kit AGENTS"; Text = $kitAgents }
  )) {
    Assert-Contains $entry.Name $entry.Text "세션 근거 인덱스"
    Assert-Contains $entry.Name $entry.Text "위험 행동 스냅샷"
    Assert-Contains $entry.Name $entry.Text "검증 패킷"
    Assert-Contains $entry.Name $entry.Text "빈 범위 검색"
    Assert-Contains $entry.Name $entry.Text "재시작 결과 패킷"
    Assert-Contains $entry.Name $entry.Text "preflight exact mismatch"
    Assert-Contains $entry.Name $entry.Text "이전 세션 target ID"
    Assert-Contains $entry.Name $entry.Text "임무 완수 우선"
    Assert-Contains $entry.Name $entry.Text "mission-first completion loop"
    Assert-Contains $entry.Name $entry.Text "부분 완성 기본값"
    Assert-Contains $entry.Name $entry.Text "안정 지점 저장"
    Assert-Contains $entry.Name $entry.Text "exact 범위 밖 선택 허용"
    Assert-Contains $entry.Name $entry.Text "신규 문제지 검색 backbone"
    Assert-Contains $entry.Name $entry.Text "최초 세팅 우선"
    Assert-Contains $entry.Name $entry.Text "텍스트 검색 주도"
    Assert-Contains $entry.Name $entry.Text "edit-before-search-complete ban"
    Assert-Contains $entry.Name $entry.Text "Same-URL fresh restart contamination gate"
    Assert-Contains $entry.Name $entry.Text "0선택 상태 분리"
    Assert-Contains $entry.Name $entry.Text "검색 완료/0선택"
    Assert-Contains $entry.Name $entry.Text "초기 성공 루프"
    Assert-Contains $entry.Name $entry.Text "치명 실패 4게이트"
    Assert-Contains $entry.Name $entry.Text "Aside REPL 실패 차단"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- ASIDE_OFF_USER_RESPONSE -->"
    Assert-Contains $entry.Name $entry.Text 'aside 키고 다시 오도록.'
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- PRODUCTION_VALIDATION_REF -->"
    Assert-Contains $entry.Name $entry.Text 'requestedAction=partial-save'
    Assert-Contains $entry.Name $entry.Text 'UnresolvedSourceNumbers'
    Assert-Contains $entry.Name $entry.Text "idle-tab recovery ownership"
    Assert-Contains $entry.Name $entry.Text "fresh exact target ordered ID bundle"
    Assert-Contains $entry.Name $entry.Text "대표 ID는 중간 sanity check"
    Assert-Contains $entry.Name $entry.Text "visible/selected UI evidence"
    Assert-Contains $entry.Name $entry.Text "비-Aside REPL live 조작 발생"
    Assert-Contains $entry.Name $entry.Text "Codex home"
    Assert-Contains $entry.Name $entry.Text "mathsecr_formula_search_feature_test_2026-06-08.md"
    Assert-Contains $entry.Name $entry.Text "mathsecr_search_feature_live_verification_2026-07-29.md"
    Assert-Contains $entry.Name $entry.Text "mathsecr_db_inference_search_test_2026-07-29.md"
    Assert-Contains $entry.Name $entry.Text "내부 검증 패킷"
    Assert-Contains $entry.Name $entry.Text "사용자 표시 최종 응답은 아래 0–4 항목만 출력한다."
    Assert-Contains $entry.Name $entry.Text "3. 실패한 문제 이미지 크롭 보고서 PDF"
    Assert-Contains $entry.Name $entry.Text "4. 출처"
    Assert-Contains $entry.Name $entry.Text "일반적인 문제별 실패가 하나라도 있으면"
    Assert-Contains $entry.Name $entry.Text '공개 형식에는 `#`와 `@`를 쓰지 않는다.'
    Assert-Contains $entry.Name $entry.Text "최종 persisted 카드 출처 집계:"
    Assert-Contains $entry.Name $entry.Text "raw visible DB명"
    Assert-Contains $entry.Name $entry.Text "count/top3 receipt"
    Assert-Contains $entry.Name $entry.Text "출처 집계 규칙:"
    Assert-NotContains $entry.Name $entry.Text "모든 MathSecr worker/session은 성공하더라도 한국어"
    Assert-Contains $entry.Name $entry.Text 'artifact=<path>; sha256=<64 hex>; identity=<구체 설명>'
    Assert-Contains $entry.Name $entry.Text "ProjectRoot 내부 상대 경로"
    Assert-Contains $entry.Name $entry.Text "실제 파일이 존재"
    Assert-Contains $entry.Name $entry.Text "SHA-256과 일치"
    Assert-Contains $entry.Name $entry.Text "canonical source"
    Assert-Contains $entry.Name $entry.Text "Search Attempt Contract"
    Assert-Contains $entry.Name $entry.Text "search_attempt_contract.ps1"
    Assert-SearchAttemptSsotConsumer $entry.Name $entry.Text
    Assert-DbInferenceSsotConsumer $entry.Name $entry.Text
    Assert-MetadataRescueSsotConsumer $entry.Name $entry.Text
    Assert-BodyExactSsotConsumer $entry.Name $entry.Text
  }

  Assert-Contains "Success algorithm report contract" $successAlgorithm "The internal Korean verification packet must include:"
  Assert-Contains "Success algorithm report contract" $successAlgorithm "The user-facing paper result is a closed 0–4 projection:"
  Assert-Contains "Success algorithm report contract" $successAlgorithm "0. 제작한 문제지 링크"
  Assert-Contains "Success algorithm report contract" $successAlgorithm "1. 성공한 문제 S문제/T문제"
  Assert-Contains "Success algorithm report contract" $successAlgorithm "2. 실패한 문제 F문제/T문제"
  Assert-Contains "Success algorithm report contract" $successAlgorithm "3. 실패한 문제 이미지 크롭 보고서 PDF"
  Assert-Contains "Success algorithm report contract" $successAlgorithm "4. 출처"
  Assert-Contains "Success algorithm report contract" $successAlgorithm "Sort by descending frequency"
  Assert-NotContains "Success algorithm report contract" $successAlgorithm "The final Korean report must include:"
  Assert-Contains "Success algorithm idle boundary" $successAlgorithm "elapsed idle time is not itself a reason to reload"
  Assert-Contains "Success algorithm duplicate boundary" $successAlgorithm "not a service-wide toggle contract"
  Assert-Contains "Success algorithm metadata rescue state" $successAlgorithm '`METADATA_RESCUE`'
  Assert-Contains "Success algorithm search SSOT reference" $successAlgorithm "Test-MathSecrSearchAttemptContract"
  Assert-SearchAttemptSsotConsumer "Success algorithm search SSOT" $successAlgorithm
  Assert-DbInferenceSsotConsumer "Success algorithm DB inference SSOT" $successAlgorithm
  Assert-MetadataRescueSsotConsumer "Success algorithm metadata rescue SSOT" $successAlgorithm
  Assert-BodyExactSsotConsumer "Success algorithm body-exact SSOT" $successAlgorithm
  Assert-Contains "Success algorithm lazy-result guard" $successAlgorithm "Incomplete lazy-result traversal"
  Assert-Contains "Success algorithm transcription guard" $successAlgorithm "Transcription-conflict overconfidence"
  Assert-Contains "State machine metadata receipt validator" $stateMachine "Test-MathSecrMetadataRescueReceipt"
  Assert-Contains "State machine metadata required gate" $stateMachine "metadata-rescue-required"
  Assert-Contains "State machine metadata invalid gate" $stateMachine "metadata-rescue-receipt-invalid"
  Assert-Contains "State machine lazy exhaustion proof" $stateMachine "stableNoGrowthReads"
  Assert-Contains "State machine end-read snapshot proof" $stateMachine "endReadSnapshots"
  Assert-Contains "State machine metadata partition proof" $stateMachine "partitionKey"
  Assert-Contains "State machine source anomaly status" $stateMachine '"source_anomaly"'
  Assert-Contains "Search attempt validator" $searchAttemptContract "Test-MathSecrSearchAttemptContract"
  Assert-ContainsOnce "Search attempt executable SSOT" $searchAttemptContract "# SEARCH_ATTEMPT_EXECUTABLE_SSOT"
  Assert-Contains "Search attempt provenance enum" $searchAttemptContract '"literal-body"'
  Assert-Contains "Search attempt semantic provenance" $searchAttemptContract '"semantic-inference"'
  Assert-Contains "Search attempt common-chip derivation" $searchAttemptContract "CommonUnverifiedChips"
  Assert-Contains "Search attempt target binding" $searchAttemptContract '"targetBinding"'
  Assert-Contains "Search attempt scope contract" $searchAttemptContract '"initial-scope", "candidate-recovery", "whole-db"'
  Assert-Contains "Search attempt exact-match derivation" $searchAttemptContract "ExactMatchIds"
  Assert-Contains "Search attempt pending status" $searchAttemptContract '"candidate-recovery-pending"'
  Assert-Contains "Search attempt ready status" $searchAttemptContract '"miss-closure-ready"'
  Assert-Contains "Search attempt exact status" $searchAttemptContract '"exact-found"'
  Assert-Contains "Search attempt bad incident fixture" $searchAttemptFixture '"bad-common-semantic-and"'
  Assert-Contains "Search attempt exact incident fixture" $searchAttemptFixture '"goguk2-q2-exact-found"'
  Assert-Contains "Search attempt absence control fixture" $searchAttemptFixture '"synthetic-absence-control"'
  Assert-Contains "Search attempt toxic chip fixture" $searchAttemptFixture '"양수"'
  Assert-Contains "README reusable guardrails" $readme "## Current Reusable Guardrails"
  Assert-Contains "README idle recovery rule" $readme "recover only when one of those checks fails"
  Assert-Contains "README idle claim boundary" $readme "does not prove current service availability, latency, result count"
  Assert-Contains "README occurrence rule" $readme "Every printed source position keeps its own stable"
  Assert-Contains "README duplicate rule" $readme "never use a re-click as duplicate insertion"
  Assert-Contains "README search SSOT function" $readme "scripts/search_attempt_contract.ps1"
  Assert-Contains "README search SSOT procedure" $readme "Search Attempt Contract"
  Assert-SearchAttemptSsotConsumer "README search SSOT" $readme
  Assert-DbInferenceSsotConsumer "README DB inference SSOT" $readme
  Assert-MetadataRescueSsotConsumer "README metadata rescue SSOT" $readme
  Assert-BodyExactSsotConsumer "README body-exact SSOT" $readme
  Assert-SearchAttemptSsotConsumer "Reusable prompt search SSOT" $reusablePrompt
  Assert-DbInferenceSsotConsumer "Reusable prompt DB inference SSOT" $reusablePrompt
  Assert-MetadataRescueSsotConsumer "Reusable prompt metadata rescue SSOT" $reusablePrompt
  Assert-BodyExactSsotConsumer "Reusable prompt body-exact SSOT" $reusablePrompt

  foreach ($entry in @(
    @{ Name = "Kit SKILL"; Text = $kitSkill },
    @{ Name = "Installed SKILL"; Text = $installedSkill }
  )) {
    Assert-ContainsOnce $entry.Name $entry.Text "검색 전 scope gate"
    Assert-ContainsOnce $entry.Name $entry.Text "결과 cardinality guard"
    Assert-ContainsOnce $entry.Name $entry.Text "위험 행동 스냅샷"
    Assert-ContainsOnce $entry.Name $entry.Text "저장 검증 패킷"
    Assert-ContainsOnce $entry.Name $entry.Text "탐색 URL 격리"
    Assert-ContainsOnce $entry.Name $entry.Text "preflight exact mismatch stop"
    Assert-ContainsOnce $entry.Name $entry.Text "selection-bundle persistence gate"
    Assert-ContainsOnce $entry.Name $entry.Text "edit-modal source gate"
    Assert-ContainsOnce $entry.Name $entry.Text "completion-first retry budget"
    Assert-ContainsOnce $entry.Name $entry.Text "whole-DB text retry gate"
    Assert-ContainsOnce $entry.Name $entry.Text "missed-number finalization"
    Assert-ContainsOnce $entry.Name $entry.Text "mission-first build loop"
    Assert-ContainsOnce $entry.Name $entry.Text "initial-scope fast pass"
    Assert-ContainsOnce $entry.Name $entry.Text "phrase-preserving optional prepass"
    Assert-ContainsOnce $entry.Name $entry.Text "candidate-map assist ladder"
    Assert-ContainsOnce $entry.Name $entry.Text "## Search Attempt Contract"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- SEARCH_ATTEMPT_HUMAN_SSOT:START -->"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- SEARCH_ATTEMPT_HUMAN_SSOT:END -->"
    Assert-ContainsOnce $entry.Name $entry.Text "Test-MathSecrSearchAttemptContract"
    Assert-ContainsOnce $entry.Name $entry.Text "## DB Inference And Official Collection Contract"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- DB_INFERENCE_HUMAN_SSOT:START -->"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- DB_INFERENCE_HUMAN_SSOT:END -->"
    Assert-ContainsOnce $entry.Name $entry.Text "## Metadata Rescue And Lazy Coverage Contract"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- METADATA_RESCUE_HUMAN_SSOT:START -->"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- METADATA_RESCUE_HUMAN_SSOT:END -->"
    Assert-ContainsOnce $entry.Name $entry.Text "## Body-Exact Selection Contract"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- BODY_EXACT_HUMAN_SSOT:START -->"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- BODY_EXACT_HUMAN_SSOT:END -->"
    Assert-ContainsOnce $entry.Name $entry.Text "scopeKind=collection"
    Assert-ContainsOnce $entry.Name $entry.Text '`작업공간` 표현은 dated evidence'
    Assert-ContainsOnce $entry.Name $entry.Text '`Test-MathSecrMetadataRescueReceipt`'
    Assert-ContainsOnce $entry.Name $entry.Text '`[Y-1,Y+1]`'
    Assert-ContainsOnce $entry.Name $entry.Text "cumulative unique inspected card IDs"
    Assert-ContainsOnce $entry.Name $entry.Text "객관식 선지(①~⑤ answer choices)"
    Assert-ContainsOnce $entry.Name $entry.Text "bounded whole-DB retry"
    Assert-ContainsOnce $entry.Name $entry.Text "partial finalization"
    Assert-ContainsOnce $entry.Name $entry.Text "recovery before stop"
    Assert-ContainsOnce $entry.Name $entry.Text "fresh-paper search backbone"
    Assert-ContainsOnce $entry.Name $entry.Text "search-momentum ladder"
    Assert-ContainsOnce $entry.Name $entry.Text "prior-ID fast lane"
    Assert-ContainsOnce $entry.Name $entry.Text "same-URL fresh restart contamination gate"
    Assert-ContainsOnce $entry.Name $entry.Text "text-search escape hatch"
    Assert-ContainsOnce $entry.Name $entry.Text "near-miss scan budget"
    Assert-ContainsOnce $entry.Name $entry.Text "stable-save checkpoint"
    Assert-ContainsOnce $entry.Name $entry.Text "edit-before-search-complete ban"
    Assert-ContainsOnce $entry.Name $entry.Text "zero-selection completion label"
    Assert-ContainsOnce $entry.Name $entry.Text "official-guide search contract"
    Assert-ContainsOnce $entry.Name $entry.Text "fresh-result after criteria mutation"
    Assert-ContainsOnce $entry.Name $entry.Text "formula-zero recovery"
    Assert-ContainsOnce $entry.Name $entry.Text "source-occurrence identity gate"
    Assert-ContainsOnce $entry.Name $entry.Text "append-only resume boundary"
    Assert-ContainsOnce $entry.Name $entry.Text "reference success loop"
    Assert-ContainsOnce $entry.Name $entry.Text "fatal-failure four-gate"
    Assert-ContainsOnce $entry.Name $entry.Text "aside-repl-unavailable block"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- ASIDE_OFF_USER_RESPONSE -->"
    Assert-ContainsOnce $entry.Name $entry.Text "<!-- PRODUCTION_VALIDATION_REF -->"
    Assert-Contains $entry.Name $entry.Text 'aside 키고 다시 오도록.'
    Assert-Contains $entry.Name $entry.Text 'requestedAction=partial-save'
    Assert-Contains $entry.Name $entry.Text 'validate_production_step.ps1'
    Assert-Contains $entry.Name $entry.Text "Miss closure는 initial-scope와 whole-db의 독립 clean literal ladder"
    Assert-Contains $entry.Name $entry.Text "fresh exact target ordered ID bundle"
    Assert-Contains $entry.Name $entry.Text "대표 ID는 중간 sanity check"
    Assert-Contains $entry.Name $entry.Text "visible/selected UI evidence"
    Assert-Contains $entry.Name $entry.Text "같은 Aside REPL 세션 안의 UI 조작"
    Assert-Contains $entry.Name $entry.Text "Aside REPL reconnect/reopen"
    Assert-Contains $entry.Name $entry.Text "검색결과 : 4,280개"
    Assert-Contains $entry.Name $entry.Text "scope-dependent evidence"
    Assert-Contains $entry.Name $entry.Text "same-card second activation"
    Assert-Contains $entry.Name $entry.Text "service-wide toggle 계약"
    Assert-ContainsOnce $entry.Name $entry.Text "0. 제작한 문제지 링크"
    Assert-ContainsOnce $entry.Name $entry.Text "1. 성공한 문제 <성공 문제 수>문제/<전체 문제 수>문제"
    Assert-ContainsOnce $entry.Name $entry.Text "2. 실패한 문제 <실패 문제 수>문제/<전체 문제 수>문제"
    Assert-ContainsOnce $entry.Name $entry.Text "3. 실패한 문제 이미지 크롭 보고서 PDF"
    Assert-ContainsOnce $entry.Name $entry.Text "4. 출처"
    Assert-Contains $entry.Name $entry.Text "내부 검증 패킷"
    Assert-Contains $entry.Name $entry.Text "일반적인 실패가 하나라도 있으면 실패 번호에 대응하는 실제 PDF 크롭 보고서 링크가 필수다."
    Assert-Contains $entry.Name $entry.Text '공개 형식에는 `#`와 `@`를 쓰지 않는다.'
    Assert-Contains $entry.Name $entry.Text "최종 persisted/reload 검증된 성공 카드"
    Assert-NotContains $entry.Name $entry.Text "모든 세션은 한국어 보고서로 끝낸다"
    Assert-NotContains $entry.Name $entry.Text "검색결과 : 10,002개"
  }

  Assert-ContainsOnce "State machine canonical search source" $stateMachine '. (Join-Path $PSScriptRoot "search_attempt_contract.ps1")'
  Assert-Contains "State machine canonical search call" $stateMachine "Test-MathSecrSearchAttemptContract"
  $reportContractPath = Join-Path (Split-Path -Parent $Docs.SearchAttemptContract) "report_contract.ps1"
  $reportContractText = Read-Doc $reportContractPath
  Assert-ContainsOnce "Report contract canonical search source" $reportContractText '. (Join-Path $PSScriptRoot "search_attempt_contract.ps1")'
  Assert-Contains "Report contract canonical search call" $reportContractText "Test-MathSecrSearchAttemptContract"
  foreach ($relativePath in @(
    'scripts/aside_preflight.ps1', 'scripts/check_aside_repl.ps1', 'scripts/test_aside_preflight.ps1',
    'scripts/production_validation.ps1', 'scripts/validate_production_step.ps1', 'scripts/test_production_validation.ps1',
    'scripts/test_partial_save_phases.ps1', 'docs/production_validation.md',
    'test-fixtures/production-validation/source-roster.json'
  )) {
    Assert-FileExists 'Production validation asset' (Join-Path $ProjectRoot ("mathsecr-paper-builder-kit/" + $relativePath))
  }

  foreach ($entry in @(
    @{ Name = "Root AGENTS"; Text = $rootAgents },
    @{ Name = "Kit AGENTS"; Text = $kitAgents },
    @{ Name = "Kit SKILL"; Text = $kitSkill },
    @{ Name = "Installed SKILL"; Text = $installedSkill }
  )) {
    Assert-NotContains $entry.Name $entry.Text "묵시"
    Assert-NotContains $entry.Name $entry.Text "비-Aside REPL fallback 사유"
    Assert-NotContains $entry.Name $entry.Text "미완성(0선택)"
    Assert-NotContains $entry.Name $entry.Text "count/order 또는 대표 ID"
    Assert-NotContains $entry.Name $entry.Text "browser recovery"
    Assert-NotContains $entry.Name $entry.Text "fallback click"
    Assert-NotMatches $entry.Name $entry.Text "C:\\Users\\[^\\\r\n]+" "contains a user-specific absolute Windows path"
  }

  Write-Host "CoreRules PASS"
}

function Test-DetectMissingRule {
  $detected = $false
  try {
    Assert-Contains "Synthetic AGENTS" "세션 보고서만 있음" "세션 근거 인덱스"
  } catch {
    $detected = $true
    Write-Host "DetectMissingRule observed expected failure: $($_.Exception.Message)"
  }
  if (-not $detected) {
    throw "DetectMissingRule failed to detect a missing required marker"
  }
  $syntheticDuplicates = @(
    'provenance(literal-body, literal-printed-metadata) is copied here.',
    'Copy CommonUnverifiedChips into the prompt.',
    'candidateRecoveryEvidence.coverage is reconstructed here.',
    'Translate t>0→양수 before searching.',
    'Translate overline{AB}→길이 before searching.'
  )
  foreach ($syntheticDuplicate in $syntheticDuplicates) {
    $duplicateDetected = $false
    try {
      Assert-SearchAttemptSsotConsumer "Synthetic search SSOT duplicate" "<!-- SEARCH_ATTEMPT_SSOT_REF -->`n$syntheticDuplicate"
    } catch {
      $duplicateDetected = $true
      Write-Host "DetectMissingRule observed expected SSOT failure: $($_.Exception.Message)"
    }
    if (-not $duplicateDetected) {
      throw "DetectMissingRule failed to detect duplicated search-attempt wording: $syntheticDuplicate"
    }
  }

  $syntheticDbDuplicates = @(
    'Use scopeKind=collection for this branch.',
    '`작업공간 > 교육청, 평가원` 왼쪽 체크박스를 클릭한다.',
    'Copy the "blankProbe" receipt here.',
    'Copy the "scopeLock" and "scopedSearch" receipts here.'
  )
  foreach ($syntheticDuplicate in $syntheticDbDuplicates) {
    $duplicateDetected = $false
    try {
      Assert-DbInferenceSsotConsumer "Synthetic DB inference SSOT duplicate" "<!-- DB_INFERENCE_SSOT_REF -->`nDB Inference And Official Collection Contract`n$syntheticDuplicate"
    } catch {
      $duplicateDetected = $true
      Write-Host "DetectMissingRule observed expected DB SSOT failure: $($_.Exception.Message)"
    }
    if (-not $duplicateDetected) {
      throw "DetectMissingRule failed to detect duplicated DB-inference wording: $syntheticDuplicate"
    }
  }

  $syntheticMetadataDuplicates = @(
    '연도 `[Y-1,Y+1]` 규칙을 복사한다.',
    'cumulative unique inspected card IDs를 다시 계산한다.',
    'endReadSnapshots와 stableNoGrowthReads를 prompt에 둔다.',
    'partitionKey=month=<value>;grade=<value>로 만든다.'
  )
  foreach ($syntheticDuplicate in $syntheticMetadataDuplicates) {
    $duplicateDetected = $false
    try {
      Assert-MetadataRescueSsotConsumer "Synthetic metadata rescue SSOT duplicate" "<!-- METADATA_RESCUE_SSOT_REF -->`nMetadata Rescue And Lazy Coverage Contract`n$syntheticDuplicate"
    } catch {
      $duplicateDetected = $true
      Write-Host "DetectMissingRule observed expected metadata SSOT failure: $($_.Exception.Message)"
    }
    if (-not $duplicateDetected) {
      throw "DetectMissingRule failed to detect duplicated metadata-rescue wording: $syntheticDuplicate"
    }
  }

  $syntheticBodyDuplicates = @(
    '객관식 선지(①~⑤ answer choices) 규칙을 복사한다.',
    '문제 본문, 조건, 도형/그래프/표, 수식 목록을 복사한다.',
    'sourceRenderArtifact와 candidateRenderArtifact를 prompt가 재정의한다.'
  )
  foreach ($syntheticDuplicate in $syntheticBodyDuplicates) {
    $duplicateDetected = $false
    try {
      Assert-BodyExactSsotConsumer "Synthetic body-exact SSOT duplicate" "<!-- BODY_EXACT_SSOT_REF -->`nBody-Exact Selection Contract`n$syntheticDuplicate"
    } catch {
      $duplicateDetected = $true
      Write-Host "DetectMissingRule observed expected body-exact SSOT failure: $($_.Exception.Message)"
    }
    if (-not $duplicateDetected) {
      throw "DetectMissingRule failed to detect duplicated body-exact wording: $syntheticDuplicate"
    }
  }
  Write-Host "DetectMissingRule PASS"
}

function Test-SessionCoverage {
  param([string]$Root, [hashtable]$Docs)
  $rootAgents = Read-Doc $Docs.RootAgents
  $kitAgents = Read-Doc $Docs.KitAgents
  $kitSkill = Read-Doc $Docs.KitSkill
  $installedSkill = Read-Doc $Docs.InstalledSkill
  $allDocs = "$rootAgents`n$kitAgents`n$kitSkill`n$installedSkill"

  $requiredSources = @(
    @{ Name = "feature exploration notes"; RelativePath = "mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_feature_exploration.md" },
    @{ Name = "card inventory"; RelativePath = "mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_card_inventory_2000.json" },
    @{ Name = "candidate summary"; RelativePath = "mathsecr-paper-builder-kit/test-fixtures/docs/gajwa2_candidate_summary.json" },
    @{ Name = "source selector evidence"; RelativePath = ".omo/evidence/mathsecr_source_selector_exception_2026-06-05.md" },
    @{ Name = "restart evidence"; RelativePath = ".omo/evidence/mathsecr_restart_results_2026-06-05.md" },
    @{ Name = "mission-first evidence"; RelativePath = ".omo/evidence/mathsecr_mission_first_review_2026-06-05.md" },
    @{ Name = "search momentum evidence"; RelativePath = ".omo/evidence/mathsecr_search_momentum_review_2026-06-05.md" },
    @{ Name = "state contamination evidence"; RelativePath = ".omo/evidence/mathsecr_state_contamination_2026-06-05.md" },
    @{ Name = "adaptive search evidence"; RelativePath = ".omo/evidence/mathsecr_new_paper_adaptive_search_policy_2026-06-05.md" },
    @{ Name = "scheduled retry evidence"; RelativePath = ".omo/evidence/mathsecr_scheduled_retry_results_2026-06-05.md" },
    @{ Name = "minimal failure evidence"; RelativePath = ".omo/evidence/mathsecr_minimal_failure_rules_2026-06-06.md" },
    @{ Name = "body-only exact evidence"; RelativePath = ".omo/evidence/mathsecr_body_only_exact_policy_2026-06-07.md" },
    @{ Name = "search regression evidence"; RelativePath = ".omo/evidence/mathsecr_search_regression_recovery_policy_2026-06-07.md" },
    @{ Name = "formula search evidence"; RelativePath = ".omo/evidence/mathsecr_formula_search_feature_test_2026-06-08.md" },
    @{ Name = "live search feature evidence"; RelativePath = ".omo/evidence/mathsecr_search_feature_live_verification_2026-07-29.md" },
    @{ Name = "DB inference search evidence"; RelativePath = ".omo/evidence/mathsecr_db_inference_search_test_2026-07-29.md" },
    @{ Name = "external handoff gap-fill evidence"; RelativePath = ".omo/evidence/mathsecr_external_handoff_gap_fill_2026-07-31.md" },
    @{ Name = "selection journal evidence"; RelativePath = ".omo/evidence/mathsecr_selection_journal_resume_2026-07-31.md" },
    @{ Name = "PDF segmentation corpus evidence"; RelativePath = ".omo/evidence/mathsecr_pdf_segmentation_corpus_2026-07-31.md" },
    @{ Name = "idle search characterization evidence"; RelativePath = ".omo/evidence/mathsecr_idle_search_characterization_2026-07-31.md" }
  )
  foreach ($source in $requiredSources) {
    $nativeRelativePath = $source.RelativePath -replace '/', '\'
    Assert-FileExists $source.Name (Join-Path $Root $nativeRelativePath)
    Assert-Contains "Root AGENTS evidence index" $rootAgents $source.RelativePath
  }

  $liveEvidenceRelativePath = ".omo/evidence/mathsecr_search_feature_live_verification_2026-07-29.md"
  $liveTraceRelativePath = "mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_search_feature_live_trace_2026-07-29.txt"
  $liveEvidencePath = Join-Path $Root ($liveEvidenceRelativePath -replace '/', '\')
  $liveTracePath = Join-Path $Root ($liveTraceRelativePath -replace '/', '\')
  Assert-FileExists "live search feature trace" $liveTracePath
  $liveTraceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $liveTracePath).Hash
  $liveEvidenceText = Read-Doc $liveEvidencePath
  Assert-Contains "live search feature artifact receipt" $liveEvidenceText "artifact=$liveTraceRelativePath; sha256=$liveTraceHash;"

  $dbInferenceEvidenceRelativePath = ".omo/evidence/mathsecr_db_inference_search_test_2026-07-29.md"
  $dbInferenceFixtureRelativePath = "mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_db_inference_search_matrix_2026-07-29.json"
  $dbInferenceEvidencePath = Join-Path $Root ($dbInferenceEvidenceRelativePath -replace '/', '\')
  $dbInferenceFixturePath = Join-Path $Root ($dbInferenceFixtureRelativePath -replace '/', '\')
  Assert-FileExists "DB inference search matrix" $dbInferenceFixturePath
  $dbInferenceFixtureHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dbInferenceFixturePath).Hash
  $dbInferenceEvidenceText = Read-Doc $dbInferenceEvidencePath
  Assert-Contains "DB inference artifact receipt" $dbInferenceEvidenceText "artifact=$dbInferenceFixtureRelativePath; sha256=$dbInferenceFixtureHash;"
  $dbInferenceFixture = Get-Content -Raw -LiteralPath $dbInferenceFixturePath | ConvertFrom-Json
  $dbInferenceStartedAt = [DateTimeOffset]::Parse([string]$dbInferenceFixture.session.startedAt)
  $dbInferenceEndedAt = [DateTimeOffset]::Parse([string]$dbInferenceFixture.session.endedAt)
  if (($dbInferenceEndedAt - $dbInferenceStartedAt).TotalSeconds -lt 3600 -or [int]$dbInferenceFixture.session.elapsedSeconds -lt 3600) {
    throw "[DB inference one-hour receipt] elapsed time is below 3600 seconds."
  }
  if (-not $dbInferenceFixture.session.finalState.filtersClearedWithVisibleRemovalControls -or
      [int]$dbInferenceFixture.session.finalState.selectedProblemCount -ne 0 -or
      $dbInferenceFixture.session.clickedIssueButton) {
    throw "[DB inference final browser state] clean zero-selection receipt is missing."
  }
  $dbInferenceTraceRelativePath = "mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_db_inference_live_trace_2026-07-29.txt"
  $dbInferenceTracePath = Join-Path $Root ($dbInferenceTraceRelativePath -replace '/', '\')
  Assert-FileExists "DB inference live trace" $dbInferenceTracePath
  $dbInferenceTraceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dbInferenceTracePath).Hash
  Assert-Contains "DB inference live trace receipt" $dbInferenceEvidenceText "artifact=$dbInferenceTraceRelativePath; sha256=$dbInferenceTraceHash;"
  $dbInferenceContractPath = Join-Path $Root "mathsecr-paper-builder-kit\docs\db_inference_contract.md"
  Assert-FileExists "DB inference contract" $dbInferenceContractPath
  $dbInferenceContractText = Read-Doc $dbInferenceContractPath
  Assert-Contains "DB inference contract" $dbInferenceContractText "ScopeLockReady=true"
  Assert-Contains "DB inference contract" $dbInferenceContractText "FreshSearchReceiptReady=true"
  Assert-Contains "DB inference contract" $dbInferenceContractText '"blankProbe"'
  Assert-Contains "DB inference contract" $dbInferenceContractText '"scopeLock"'
  Assert-Contains "DB inference contract" $dbInferenceContractText '"scopedSearch"'
  Assert-Contains "DB inference contract" $dbInferenceContractText '"scopeMappings"'
  Assert-Contains "DB inference contract" $dbInferenceContractText "canonical full scope"
  Assert-Contains "DB inference contract" $dbInferenceContractText "문제 1"

  $searchCharacterizationEvidenceRelativePath = ".omo/evidence/mathsecr_external_handoff_gap_fill_2026-07-31.md"
  $searchCharacterizationFixtureRelativePath = "mathsecr-paper-builder-kit/test-fixtures/search-characterization/phrase-stability-2026-07-31.json"
  $searchCharacterizationTestRelativePath = "mathsecr-paper-builder-kit/scripts/test_search_characterization.ps1"
  $searchCharacterizationEvidencePath = Join-Path $Root ($searchCharacterizationEvidenceRelativePath -replace '/', '\')
  $searchCharacterizationFixturePath = Join-Path $Root ($searchCharacterizationFixtureRelativePath -replace '/', '\')
  $searchCharacterizationTestPath = Join-Path $Root ($searchCharacterizationTestRelativePath -replace '/', '\')
  Assert-FileExists "search characterization fixture" $searchCharacterizationFixturePath
  Assert-FileExists "search characterization test" $searchCharacterizationTestPath
  $searchCharacterizationEvidenceText = Read-Doc $searchCharacterizationEvidencePath
  $searchCharacterizationFixtureHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $searchCharacterizationFixturePath).Hash
  $searchCharacterizationTestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $searchCharacterizationTestPath).Hash
  Assert-Contains "search characterization fixture receipt" $searchCharacterizationEvidenceText "artifact=$searchCharacterizationFixtureRelativePath; sha256=$searchCharacterizationFixtureHash;"
  Assert-Contains "search characterization test receipt" $searchCharacterizationEvidenceText "artifact=$searchCharacterizationTestRelativePath; sha256=$searchCharacterizationTestHash;"

  $idleSearchEvidenceRelativePath = ".omo/evidence/mathsecr_idle_search_characterization_2026-07-31.md"
  $idleSearchFixtureRelativePath = "mathsecr-paper-builder-kit/test-fixtures/search-characterization/idle-first-query-2026-07-31.json"
  $idleSearchTestRelativePath = "mathsecr-paper-builder-kit/scripts/test_idle_search_characterization.ps1"
  $idleSearchEvidencePath = Join-Path $Root ($idleSearchEvidenceRelativePath -replace '/', '\')
  $idleSearchFixturePath = Join-Path $Root ($idleSearchFixtureRelativePath -replace '/', '\')
  $idleSearchTestPath = Join-Path $Root ($idleSearchTestRelativePath -replace '/', '\')
  Assert-FileExists "idle search characterization fixture" $idleSearchFixturePath
  Assert-FileExists "idle search characterization test" $idleSearchTestPath
  $idleSearchEvidenceText = Read-Doc $idleSearchEvidencePath
  $idleSearchFixtureHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $idleSearchFixturePath).Hash
  $idleSearchTestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $idleSearchTestPath).Hash
  Assert-Contains "idle search characterization fixture receipt" $idleSearchEvidenceText "artifact=$idleSearchFixtureRelativePath; sha256=$idleSearchFixtureHash;"
  Assert-Contains "idle search characterization test receipt" $idleSearchEvidenceText "artifact=$idleSearchTestRelativePath; sha256=$idleSearchTestHash;"
  Assert-Contains "idle search characterization evidence result" $idleSearchEvidenceText "IdleSearchCharacterization PASS"
  Assert-Contains "idle search characterization scope boundary" $idleSearchEvidenceText "not a service availability, latency, or result-count contract"
  Assert-Contains "idle search recovery rule" $kitSkill "idle-first-search recovery rule"
  Assert-Contains "idle search standard-receipt boundary" $kitSkill "standard fresh receipt"
  Assert-Contains "idle search elapsed-time rule" $kitSkill "유휴 시간만으로 live paper를 선제 reload하지 않는다"

  $selectionEvidenceRelativePath = ".omo/evidence/mathsecr_selection_journal_resume_2026-07-31.md"
  $selectionEvidencePath = Join-Path $Root ($selectionEvidenceRelativePath -replace '/', '\')
  $selectionEvidenceText = Read-Doc $selectionEvidencePath
  foreach ($selectionArtifactRelativePath in @(
    "mathsecr-paper-builder-kit/scripts/selection_journal.ps1",
    "mathsecr-paper-builder-kit/scripts/test_selection_journal.ps1",
    "mathsecr-paper-builder-kit/test-fixtures/selection-journal/cases.json"
  )) {
    $selectionArtifactPath = Join-Path $Root ($selectionArtifactRelativePath -replace '/', '\')
    Assert-FileExists "selection journal artifact $selectionArtifactRelativePath" $selectionArtifactPath
    $selectionArtifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectionArtifactPath).Hash
    Assert-Contains "selection journal artifact receipt" $selectionEvidenceText "artifact=$selectionArtifactRelativePath; sha256=$selectionArtifactHash;"
  }
  Assert-Contains "selection journal evidence result" $selectionEvidenceText "SelectionJournal PASS"

  $pdfEvidenceRelativePath = ".omo/evidence/mathsecr_pdf_segmentation_corpus_2026-07-31.md"
  $pdfEvidencePath = Join-Path $Root ($pdfEvidenceRelativePath -replace '/', '\')
  $pdfEvidenceText = Read-Doc $pdfEvidencePath
  $pdfManifestRelativePath = "mathsecr-paper-builder-kit/test-fixtures/pdf-segmentation/segmentation-corpus-2026-07-31.json"
  $pdfTestRelativePath = "mathsecr-paper-builder-kit/scripts/test_pdf_segmentation.ps1"
  $pdfManifestPath = Join-Path $Root ($pdfManifestRelativePath -replace '/', '\')
  $pdfTestPath = Join-Path $Root ($pdfTestRelativePath -replace '/', '\')
  Assert-FileExists "PDF segmentation corpus manifest" $pdfManifestPath
  Assert-FileExists "PDF segmentation test" $pdfTestPath
  $pdfManifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pdfManifestPath).Hash
  $pdfTestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pdfTestPath).Hash
  Assert-Contains "PDF segmentation manifest receipt" $pdfEvidenceText "artifact=$pdfManifestRelativePath; sha256=$pdfManifestHash;"
  Assert-Contains "PDF segmentation test receipt" $pdfEvidenceText "artifact=$pdfTestRelativePath; sha256=$pdfTestHash;"

  try {
    $pdfManifest = Get-Content -LiteralPath $pdfManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    throw "[PDF segmentation corpus] manifest is not valid JSON: $pdfManifestPath. $($_.Exception.Message)"
  }
  $pdfFixtureRoot = [IO.Path]::GetFullPath((Join-Path $Root "mathsecr-paper-builder-kit\test-fixtures\pdf-segmentation")).TrimEnd('\')
  $pdfFixturePrefix = $pdfFixtureRoot + '\'
  $pdfArtifacts = @($pdfManifest.artifacts)
  if ($pdfArtifacts.Count -eq 0) {
    throw "[PDF segmentation corpus] manifest declares no packaged render artifacts."
  }
  foreach ($pdfArtifact in $pdfArtifacts) {
    $pdfArtifactRelativePath = [string]$pdfArtifact.path
    if ([string]::IsNullOrWhiteSpace($pdfArtifactRelativePath) -or [IO.Path]::IsPathRooted($pdfArtifactRelativePath)) {
      throw "[PDF segmentation corpus] artifact path is not relative: $pdfArtifactRelativePath"
    }
    $pdfArtifactPath = [IO.Path]::GetFullPath((Join-Path $pdfFixtureRoot $pdfArtifactRelativePath))
    if (-not $pdfArtifactPath.StartsWith($pdfFixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "[PDF segmentation corpus] artifact escaped fixture root: $pdfArtifactRelativePath"
    }
    Assert-FileExists "PDF segmentation packaged artifact $pdfArtifactRelativePath" $pdfArtifactPath
    $observedPdfArtifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pdfArtifactPath).Hash
    Assert-Contains "PDF segmentation artifact hash" $pdfEvidenceText $observedPdfArtifactHash
    if ($observedPdfArtifactHash -cne ([string]$pdfArtifact.sha256).ToUpperInvariant()) {
      throw "[PDF segmentation corpus] packaged artifact hash mismatch: $pdfArtifactRelativePath"
    }
  }

  $reportContractPath = Join-Path $Root "mathsecr-paper-builder-kit\scripts\report_contract.ps1"
  $reportTestPath = Join-Path $Root "mathsecr-paper-builder-kit\scripts\test_report_lint.ps1"
  Assert-FileExists "report contract" $reportContractPath
  Assert-FileExists "report contract tests" $reportTestPath
  $reportContractText = Read-Doc $reportContractPath
  Assert-Contains "report contract" $reportContractText "function Invoke-MathSecrUserSummaryLint"
  Assert-Contains "report contract" $reportContractText "4. 출처"
  Assert-Contains "report contract" $reportContractText "User summary must not contain # or @ symbols"
  $reportTestText = Read-Doc $reportTestPath
  Assert-Contains "report contract tests" $reportTestText "ValidUserSummary"
  Assert-Contains "report contract tests" $reportTestText "validSingleSourceUserSummary"
  Assert-Contains "report contract tests" $reportTestText "ValidUserSummaryNone"
  Assert-Contains "report contract tests" $reportTestText "ValidUserSummaryBlocked"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryExtraLines"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryInternalLeak"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryPreamble"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryMissingPdf"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryPdfMissing"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryPdfUrl"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryPdfExtension"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryPaperUrl"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryCounts"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryRefs"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryUnexpectedPdf"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryBlockerCounts"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryLeadingZero"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryFourSources"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryFrequency"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryDuplicateSource"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummaryZeroSuccessSource"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummarySymbol"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummarySourceUrl"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummarySourceId"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummarySourceInternal"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummarySourceCount"
  Assert-Contains "report contract tests" $reportTestText "InvalidUserSummarySourceSum"

  Assert-Contains "Session coverage" $allDocs "197,341"
  Assert-Contains "Formula provenance" $kitSkill "tracked 2026-06-08 scoped session"
  Assert-Contains "Formula provenance" $kitSkill "검색결과 : 4,280개"
  Write-Host "SessionCoverage PASS"
}

function Assert-AsideReplPromptPolicy {
  param(
    [string]$Name,
    [string]$Text,
    [string]$CanonicalHardStop
  )

  Assert-ContainsOnce $Name $Text $CanonicalHardStop

  $policyBody = $Text.Replace($CanonicalHardStop, "")
  Assert-NotMatches $Name $policyBody "(?i)(?:\bin-app\s+Browser\b|\biab\b|\bChrome\b|\bComputer\s+Use\b|\bextension\b|크롬|컴퓨터\s*사용|확장\s*프로그램)" "mentions a forbidden non-Aside-REPL live-browser surface outside the canonical hard stop"
}

function Test-PromptDrift {
  param([string]$Root)
  $canonicalAsideReplHardStop = 'ASIDE_REPL_HARD_STOP: If Aside REPL is unavailable or cannot attach to and verify the live paper, report `차단`. Do not switch that session to the Codex in-app Browser, Chrome, an extension, or Computer Use.'
  $kitReusablePrompt = Join-Path $Root "mathsecr-paper-builder-kit\prompts\mathsecr_new_paper_prompt.md"
  Assert-FileExists "versioned reusable MathSecr prompt" $kitReusablePrompt
  $kitReusablePromptText = Read-Doc $kitReusablePrompt
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "0–4 항목만 사용한다"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "1. 성공한 문제 S문제/T문제"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "2. 실패한 문제 F문제/T문제"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "3. 실패한 문제 이미지 크롭 보고서 PDF"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "4. 출처"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText '공개 형식에는 `#`와 `@`를 쓰지 않는다.'
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "내부 검증 패킷"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "경과 시간만으로 reload하지 않는다"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "같은 ID가 반복되어도 원본 row를 합치지 않는다"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "same-card second activation"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "별도 visible 복제/추가 control"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "edit/persisted ordered-bundle 증거"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "Search Attempt Contract"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "search_attempt_contract.ps1"
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText "derived status"
  Assert-SearchAttemptSsotConsumer "versioned reusable MathSecr prompt" $kitReusablePromptText
  Assert-DbInferenceSsotConsumer "versioned reusable MathSecr prompt" $kitReusablePromptText
  Assert-MetadataRescueSsotConsumer "versioned reusable MathSecr prompt" $kitReusablePromptText
  Assert-BodyExactSsotConsumer "versioned reusable MathSecr prompt" $kitReusablePromptText
  Assert-Contains "versioned reusable MathSecr prompt" $kitReusablePromptText '`source_anomaly`/pending'
  Assert-NotContains "versioned reusable MathSecr prompt" $kitReusablePromptText '최종 출력은 한국어 `MathSecr 세션 보고서`로 한다'
  $localReusablePrompt = Join-Path $Root ".omo\prompts\mathsecr_new_paper_prompt.md"
  if (Test-Path -LiteralPath $localReusablePrompt) {
    $localReusablePromptText = Read-Doc $localReusablePrompt
    Assert-SearchAttemptSsotConsumer "local reusable MathSecr prompt" $localReusablePromptText
    Assert-DbInferenceSsotConsumer "local reusable MathSecr prompt" $localReusablePromptText
    Assert-MetadataRescueSsotConsumer "local reusable MathSecr prompt" $localReusablePromptText
    Assert-BodyExactSsotConsumer "local reusable MathSecr prompt" $localReusablePromptText
  }
  $startPrompt = Join-Path $Root "mathsecr-paper-builder-kit\prompts\start-prompt.md"
  Assert-FileExists "MathSecr start prompt" $startPrompt
  $startPromptText = Read-Doc $startPrompt
  Assert-Contains "MathSecr start prompt" $startPromptText "Do not reload a long-idle live tab solely because time elapsed"
  Assert-Contains "MathSecr start prompt" $startPromptText "Reload or reopen only when one of those checks fails"
  Assert-Contains "MathSecr start prompt" $startPromptText "offline characterization, not a live availability, latency, result-count, standard-freshness, or exact/miss contract"
  Assert-Contains "MathSecr start prompt" $startPromptText "Keep repeated source positions distinct by stable"
  Assert-Contains "MathSecr start prompt" $startPromptText "same-card second activation cleared the only selection"
  Assert-Contains "MathSecr start prompt" $startPromptText "verified visible duplicate/add control plus edit/persisted ordered-bundle proof"

  $promptDirs = @(
    (Join-Path $Root ".omo\prompts"),
    (Join-Path $Root "mathsecr-paper-builder-kit\prompts")
  )
  $promptFiles = @(
    foreach ($promptDir in $promptDirs) {
      if (Test-Path -LiteralPath $promptDir) {
        Get-ChildItem -LiteralPath $promptDir -File -Filter "*.md"
      }
    }
  )
  if ($promptFiles.Count -eq 0) {
    throw "PromptDrift found no prompt files in the project or installed kit"
  }

  foreach ($prompt in $promptFiles) {
    $text = Read-Doc $prompt.FullName
    Assert-AsideReplPromptPolicy $prompt.FullName $text $canonicalAsideReplHardStop
    Assert-NotContains $prompt.FullName $text "묵시"
    Assert-NotContains $prompt.FullName $text "비-Aside REPL fallback 사유"
    Assert-NotContains $prompt.FullName $text "미완성(0선택)"
    Assert-NotContains $prompt.FullName $text "count/order 또는 대표 ID"
    Assert-NotContains $prompt.FullName $text "browser recovery"
    Assert-NotContains $prompt.FullName $text "fallback click"
    Assert-NotMatches $prompt.FullName $text "C:\\Users\\[^\\\r\n]+" "contains a user-specific absolute Windows path"
  }

  $missingHardStopDetected = $false
  try {
    Assert-AsideReplPromptPolicy "Synthetic prompt missing hard stop" "Use Aside REPL for live MathSecr work." $canonicalAsideReplHardStop
  } catch {
    $missingHardStopDetected = $true
    Write-Host "PromptDrift observed expected missing-hard-stop failure: $($_.Exception.Message)"
  }
  if (-not $missingHardStopDetected) {
    throw "PromptDrift failed to detect a missing canonical Aside REPL hard stop"
  }

  $browserSwitchDetected = $false
  try {
    $oppositePrompt = "$canonicalAsideReplHardStop`nIf Aside REPL fails, rely on the in-app Browser."
    Assert-AsideReplPromptPolicy "Synthetic prompt with opposite browser policy" $oppositePrompt $canonicalAsideReplHardStop
  } catch {
    $browserSwitchDetected = $true
    Write-Host "PromptDrift observed expected browser-switch failure: $($_.Exception.Message)"
  }
  if (-not $browserSwitchDetected) {
    throw "PromptDrift failed to detect an explicit non-Aside-REPL switch after Aside REPL failure"
  }

  $pathDetected = $false
  try {
    Assert-NotMatches "Synthetic prompt" 'Read C:\Users\alice\.codex\skills\mathsecr-paper-builder\SKILL.md' "C:\\Users\\[^\\\r\n]+" "contains a user-specific absolute Windows path"
  } catch {
    $pathDetected = $true
    Write-Host "PromptDrift observed expected portable-path failure: $($_.Exception.Message)"
  }
  if (-not $pathDetected) {
    throw "PromptDrift failed to detect a user-specific absolute Windows path"
  }

  Write-Host "PromptDrift PASS"
}

if (-not $ProjectRoot) {
  $ProjectRoot = Resolve-DefaultProjectRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$CodexHome = Resolve-CodexHome $CodexHome
$docs = Get-DocSet $ProjectRoot $CodexHome

Write-Host "MathSecr docs validator"
Write-Host "Scenario:     $Scenario"
Write-Host "Project root: $ProjectRoot"
Write-Host "Codex home:   $CodexHome"

if ($Scenario -eq "All" -or $Scenario -eq "CoreRules") {
  Test-CoreRules $docs
}
if ($Scenario -eq "All" -or $Scenario -eq "DetectMissingRule") {
  Test-DetectMissingRule
}
if ($Scenario -eq "All" -or $Scenario -eq "SyncContract") {
  Test-SyncContract $docs
}
if ($Scenario -eq "All" -or $Scenario -eq "SessionCoverage") {
  Test-SessionCoverage $ProjectRoot $docs
}
if ($Scenario -eq "All" -or $Scenario -eq "PromptDrift") {
  Test-PromptDrift $ProjectRoot
}

Write-Host "Validation complete"
