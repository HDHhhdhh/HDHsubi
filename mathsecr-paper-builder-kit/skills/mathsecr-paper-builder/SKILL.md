---
name: mathsecr-paper-builder
description: Recreate MathSecr/수학비서 problem papers from a PDF or HWPX by finding exact matches, preserving source order, retrying misses in whole DB with bounded Korean clue searches, and stopping before 출제하기 unless explicitly requested.
---

# MathSecr Paper Builder

## Public Runtime Environment

Git 배포본의 공개 설치와 환경 점검은 workspace `docs/installation.md`를 따른다. 비공개 과거 테스트 자료를 설치 조건으로 요구하지 않는다. 새 제작에서는 원본·검색·본문·선택·저장·재로드의 실제 증거와 기존 계약을 유지한다. helper는 workspace root에서 `python scripts/run.py mathsecr-paper-builder-kit/scripts/<파일> <인수>`로 실행한다. macOS는 `python3`도 사용할 수 있다. Runner는 설치한 workspace Python 환경을 사용한다. Python PDF 렌더는 `pymupdf`를 사용할 수 있으며, 실패 크롭 보고서는 설치한 한글 글꼴로 만든다.

## Goal

제공된 PDF/HWPX 원본을 기준으로 MathSecr/수학비서 문제지를 만든다. exact 문제를 원본 순서대로 담고, 일부를 못 찾으면 검증된 부분 완성으로 끝내며, 최종 edit/settings 화면에서 `출제하기` 전 상태로 남긴다.

허브가 범위에 있으면 workspace root `AGENTS.md`를 읽고 그 보고서 템플릿을 사용한다. 모든 사용자 표시 출력은 한국어로 작성한다. UI label, selector, ID, URL, API field는 필요할 때 원문을 유지해도 된다.

## Hard Stops

- `출제하기`는 사용자가 명시 요청하지 않으면 절대 클릭하지 않는다.
- 배점은 설정하거나 추론하지 않는다. 점수는 otherwise identical 후보를 구분할 때만 참고한다.
- live MathSecr 클릭은 primary agent가 소유한다. subagent는 별도 live session을 명시 배정받지 않는 한 read-only다.
- <!-- SURFACE_HARD_STOP --> surface-unavailable block: 세션 입력의 surface가 unavailable, crash, live paper 미검증 상태이면 즉시 `차단`으로 보고한다. 같은 세션에서 다른 browser surface로 전환하지 않는다.
- <!-- ASIDE_OFF_USER_RESPONSE --> 제작 요청의 현재 probe가 Aside 종료를 확인하면 사용자 응답은 `aside 키고 다시 오도록.` 한 줄만 쓴다. 정상 제작의 0–4 보고보다 이 예외를 우선한다. timeout·CLI 부재·로그인 실패를 종료로 단정하지 않는다. 코드 검토·구현은 이 제작 응답 예외와 구분한다. 이 예외는 surface가 aside-repl인 세션에만 적용한다.
- live selection 전 true blocker: source PDF/HWPX 또는 source problem list 없음, login redirect, paper URL/title 미검증, source-paper identity mismatch, live browser/tooling unavailable.
- live paper tab에서 API route, raw backend URL, verification URL, MathSecr help/docs를 열지 않는다. 사고가 나면 paper URL을 다시 열고 저장 상태를 확인한다.
- empty/unverified source scope에서 `검색하기`를 누르지 않는다. 단, DB 미지정 입력의 source 추론을 위한 명시적 read-only blank probe는 예외이며 카드 선택, `전체 선택`, `다음 단계`, `문제지에 담기`를 금지한다. `전체 DB` retry는 visible/selected UI evidence로 `전체 DB` mode가 확인된 상태만 의미한다.

## Required Refresh

문서 확인 범위는 `AGENTS.md`의 Required Refresh를 따른다. 최초에는 두 문서를 전체 읽고 경로·SHA-256을 기록하며, 다음 시점에는 변경 여부와 관련 절만 재확인하고 3줄 이하 checkpoint를 남긴다. 정책이 바뀌거나 문맥이 소실되어 읽은 버전·규칙을 확인할 수 없으면 두 문서를 전체 다시 읽는다. 현재 선택·필터·저장 상태의 실제 확인은 그대로 수행한다.

1. 10문항 선택마다.
2. reconnect, resume, context compaction, Aside REPL reconnect/reopen 후.
3. `문제 검색` re-entry 전.
4. broad chip deletion 또는 filter reset 전.
5. `전체 DB` 포함 DB scope 전환 전.
6. `다음 단계` 클릭 전.
7. 완료 보고 전.

Checkpoint 내용: 선택 수, 활성 필터, 미발견 문제, 대체/범위 밖 선택, 다음 작업.

## Search Attempt Contract

<!-- SEARCH_ATTEMPT_HUMAN_SSOT:START -->

이 절은 검색 시도 행동의 단일 사람용 기준이다. 판정의 단일 실행 기준은 `scripts/search_attempt_contract.ps1`의 `Test-MathSecrSearchAttemptContract`이며, 다른 문서와 prompt는 이 절과 실행 contract를 참조하고 규칙을 다시 정의하지 않는다.

1. 각 source row packet을 canonical `targetBinding.sourceProblemNumber`와 `occurrenceKey`에 묶는다. 모든 proof attempt는 scope(`initial-scope`, `candidate-recovery`, `whole-db`), phase(`initial`, `refinement`, `backoff`), ordered chips, `submitted`, `freshResultVerified`, result count, exact 여부, reset/removal receipt를 원시 배열로 남긴다. Optional phrase prepass를 사용하면 같은 raw packet의 단일 `phrasePrepass` object에 한 번만 기록한다.
2. Chip provenance는 `literal-body`, `literal-printed-metadata`, `literal-visible-ui-metadata`, `formula`, `semantic-inference`, `verified-index-term`만 허용한다. Literal provenance는 source evidence와 일치해야 한다. `literal-visible-ui-metadata`와 `verified-index-term`은 index-match receipt가, `formula`는 formula-editor commit과 index-match receipt가 있어야 verified다. `semantic-inference`는 항상 unverified이며 exact나 absence proof를 만들지 못한다.
3. 각 proof-carrying scope는 visible clear/removal receipt 뒤 서로 다른 한국어 `literal-body` 단어 2개를 각각 별도 chip으로 시작한다. 실행상 시작 단어는 NFKC 정규화 뒤 1~6자, 한글을 하나 이상 포함한 한글/ASCII 영숫자만 허용한다. 내부 Unicode 공백, 구두점·기호, 수식 문법, 절 종결/연결형은 금지하므로 공백만 지운 문장을 단어로 가장할 수 없다. `실수 t에 대하여`, `만나는 두 점`, `0이 아닌 모든 실수`처럼 여러 어절인 구절 두 개를 AND 시작점으로 쓰지 않는다. Optional phrase prepass는 initial-scope 첫 ladder 앞에서만 쓰는 가속 시도다. 고신뢰 연속 본문 구절 정확히 한 개를 한 chip으로 source row당 최대 한 번 기록하고, no-exact/broad 뒤에는 그 phrase의 removal receipt와 clear receipt를 남긴 다음 단어 2칩 ladder로 reset한다. Phrase-only exact hint나 phrase result count는 proof를 대체하지 않으며 prepass도 ordered attempt summary에 포함한다. 각 chip은 committed control과 evidence receipt가 있어야 하고, mutation 뒤 명시적 submit과 post-submit signature 2회 일치를 다시 확인한다. Transient 0건, count/card 불일치, source/filter mutation 직후처럼 stale 위험이 크면 세 번째 signature까지 일치해야 한다. 동일 signature는 가능하지만 그 자체로 absence를 증명하지 않는다.
4. 직전 결과가 100개를 넘을 때만 기존 ordered chips 뒤에 verified chip 하나를 추가한다. 추가 `literal-body` chip도 위 단어 경계를 만족하는 한국어 1~2어절의 짧은 단서여야 하므로 `두 점`·`서로 다른`은 허용하지만 문장형 구절과 수식 문자열은 허용하지 않는다. 사람용 refinement에서 허용하는 추가 provenance는 기존 정책대로 `literal-body`, `literal-printed-metadata`, `verified-index-term`뿐이다. 실행 schema가 receipt-backed `literal-visible-ui-metadata`와 `formula`를 검증할 수 있어도 이를 사람용 추가 AND 칩 허용으로 해석하지 않는다. 100개 이하면 더 좁히지 말고 body-only exact 후보를 검사한다.
5. Refinement가 no-exact이면 제한어를 누적하지 않는다. 기존 query/formula의 ordered removal receipt와 clear receipt를 남기고 같은 두 `literal-body` 칩으로 final backoff한다. Semantic detour의 result count는 proof에서 제외하며, 모든 attempt에 공통인 unverified chip이 하나라도 남으면 packet은 pending이다. `t>0`을 `양수`로, `overline{AB}`를 `길이`로, A/B 또는 `만나는 두 점`을 `서로 다른`·`교점`·`선분`으로 바꾸는 것은 literal 증거가 아니다.
6. No-exact 뒤에는 candidate recovery를 수행한다. 최소 실행 gate는 receipt가 있는 `metadata-id-run`과 `source-paper-selector` route다. Same-source inventory나 previous candidate map이 존재하면 기존 정책대로 반드시 추가 route로 검사하고, 없으면 그 부재를 packet에 남긴다. Final miss를 위해 각 완료 route의 cumulative inspected IDs가 reported count를 덮고 마지막 세 `endReadSnapshots`가 같아야 한다. `exactMatchIds`는 inspected IDs에서 validator가 다시 계산한다.
7. Miss closure는 initial-scope와 whole-db의 독립 clean literal ladder, 필요한 backoff, candidate recovery, complete coverage, 빈 derived `exactMatchIds`, 빈 common-unverified intersection이 모두 유효할 때만 `miss-closure-ready`다. Exact가 재계산되면 `exact-found`, 그 밖은 `candidate-recovery-pending`이다. Retry 횟수·시간 소진이나 작은 결과 수만으로는 miss를 닫지 않는다.
8. 미발견 row의 report receipt 형식과 원본 번호/occurrenceKey 1:1 결박은 workspace `AGENTS.md`가 소유한다. State/report integration은 위 실행 contract의 derived output을 사용하며 aggregate Boolean 복사로 우회하지 않는다.

실행 보조 도구: 원본 읽기 단계에서 `scripts/search_query_plan.ps1`로 검증한 문항별 `initialChips`를 준비한다. 이 도구는 원문 전사와 제안한 단어의 실제 포함 위치를 재계산하며 OCR이나 본문 exact 판정을 대신하지 않는다. 복구 단서는 hint로만 보관한다. 브라우저 입력 직전에도 해당 원본 위치와 준비한 단어가 맞는지 확인한다.

새 검색의 화면 판독은 `scripts/search_observation.js`의 read-only collector와 현재 관측한 control map을 사용하여 scope·filter·query chips·결과 수·ordered IDs를 한 번에 기록한다. 각 실제 판독에는 새 capture/read identity를 사용하고 `observationReceipt`의 submit-action receipt 및 독립 판독 배열을 `scripts/search_observation_contract.ps1`로 검증한다. 동일 DOM 내용은 허용하지만 판독 identity의 복제는 금지한다. 검증의 `Projection`을 보고서에도 재사용한다. 이는 UI freshness 확인이며 backend 검색 완료나 전체 후보 coverage를 증명하지 않는다. 선택할 exact-producing attempt에는 `inspectedIds`, `exactMatchIds`, `observationReceipt`가 필수이며, exact가 먼저 발견되면 miss용 전체 coverage를 채우기 위해 검색을 계속하지 않는다.

<!-- SEARCH_ATTEMPT_HUMAN_SSOT:END -->

## DB Inference And Official Collection Contract

<!-- DB_INFERENCE_HUMAN_SSOT:START -->

이 절은 DB/source가 지정되지 않았을 때의 단일 사람용 절차다. 판정 schema와 실행 기준은 workspace `mathsecr-paper-builder-kit/docs/db_inference_contract.md`와 `mathsecr-paper-builder-kit/scripts/db_inference.ps1`의 `Invoke-MathSecrDbInference`가 소유한다. 다른 문서와 prompt는 이 절을 참조하고 추론 조건이나 selector 경로를 다시 정의하지 않는다.

1. PDF의 printed source/year/organization/course/exam metadata를 problem별 cluster로 만들고, 결론 전에 exact printed evidence와 body-exact probe evidence를 모두 교차검증한다. 같은 cluster의 normalized-distinct 두 문제에서 공식 `교육청/평가원` collection metadata가 반복되면 canonical collection `교육청, 평가원`, 동일 exact 교재 leaf가 반복되면 그 leaf만 후보가 된다. `other` family, 다른 leaf/collection, printed-probe 충돌, folder/unit, non-exact 또는 missing evidence는 unresolved다.
2. Printed metadata가 없으면 blank source에서 distinctive Korean 2-chip probe를 read-only로 수행한다. Chip commit·submit·freshness는 위 `Search Attempt Contract`를 따르고, blank-probe receipt에는 committed chips, explicit submit, stable result signature와 zero mutation을 남긴다. 카드 선택, `전체 선택`, `다음 단계`, `문제지에 담기`는 금지한다.
3. Blank probe는 정규화 후 서로 다른 세 source problem의 body-exact가 하나의 normalized textbook leaf 또는 canonical selectable official collection `교육청, 평가원`에 모두 동의할 때만 후보를 만든다. `1`, `01`, `１`, `1번`, `문제 1`은 한 문제로 센다. Collection 후보는 세 probe 모두 `scopeKind=collection`, normalized scope exact `교육청, 평가원`, 완결된 phase-bound `blankProbe`·`scopeLock`·`scopedSearch` receipt를 가져야 한다. Top-card plurality, `DB명 -`, substring scope match, 재사용 Boolean은 근거가 아니다.
4. Current `/mypaper/<id>` 상단 `내 문제지` 검색 모드의 `교육청, 평가원` scope-lock은 `나만의 DB 선택` dropdown의 단일 visible checkbox/label을 클릭하고 selected chip과 `교육청, 평가원 제거` receipt를 확인하는 경로다. `내 문제지 선택`, `DB 검색`, `보유 DB` 상단 folder-navigation/radio selector는 이 경로가 아니다. 과거 `작업공간` 표현은 dated evidence일 뿐 현재 route 지시가 아니다. 일반 leaf는 selector search를 visible `입력 초기화`로 비운 뒤 canonical full breadcrumb와 exact selected identity를 확인한다.
5. Blank probe, selector scope-lock, inferred-scope search receipt는 서로 재사용하지 않는다. Strict cluster packet을 `Invoke-MathSecrDbInference`에 전달하고 direct output을 state snapshot의 `dbInference`로 유지한다. Aggregate Boolean이나 별도 `scope.verified`로 우회하지 않으며 `pending`/`unresolved`는 evidence/receipt recovery만 허용한다.

<!-- DB_INFERENCE_HUMAN_SSOT:END -->

## Metadata Rescue And Lazy Coverage Contract

<!-- METADATA_RESCUE_HUMAN_SSOT:START -->

이 절은 candidate recovery 뒤의 metadata rescue와 lazy-result miss coverage에 대한 단일 사람용 절차다. Receipt 재계산과 전이 기준은 workspace `mathsecr-paper-builder-kit/scripts/state_machine.ps1`의 `Test-MathSecrMetadataRescueReceipt`가 소유하고, rescue query chip의 provenance·submit·freshness는 위 `Search Attempt Contract`가 소유한다. 다른 문서와 prompt는 이 절을 참조하고 수치·partition·coverage 절차를 다시 정의하지 않는다.

1. Printed source family·subject·year가 있는 candidate-recovery miss는 whole DB 또는 final miss 전에 rescue한다. 기존 text/formula chip을 모두 제거하고 visible removal receipt를 남긴 뒤 exact organization family, subject, printed year `[Y-1,Y+1]`, 정확히 한 개의 high-recall 한국어 function-family chip으로 명시적 submit한다. `이차함수`보다 DB 분류상 `다항함수`가 명확히 더 넓으면 그처럼 검증 가능한 family 수준으로 완화할 수 있다.
2. 3-year 결과가 100개를 넘으면 두 번째 text/formula AND chip을 추가하지 않는다. `Y-1`, `Y`, `Y+1` single-year bucket으로 나누고 필요할 때만 target의 printed month·grade metadata를 추가한다. 이 경우 `partitionKey`는 target의 `printedMonth`/`printedGrade`에서 exact `month=<value>;grade=<value>` 순서로 결정적으로 파생되어야 하며 임의·부분·다중 partition은 거부한다.
3. 결과가 100개 이하면 exact를 찾을 때까지 lazy-load한다. Exact를 먼저 찾으면 inspected ID와 selected ID가 일치하는 즉시 선택할 수 있어 전체 소진은 필요 없다. Exact가 없거나 `source_anomaly`로 닫으려면 cumulative unique inspected card IDs가 UI reported count를 덮고, cumulative `endReadSnapshots`의 끝 경계에서 기준 1회와 동일 no-growth 판독 2회 이상을 기록해야 한다. 상태 머신이 마지막 세 snapshot으로 `stableNoGrowthReads`와 `endOfResultsVerified`를 재계산한다.
4. 적분·도형·그래프처럼 시각 단서가 강하면 먼저 끝까지 load한 뒤 bottom-up으로 검사할 수 있지만 이는 효율 휴리스틱이지 정렬 계약이 아니다. 현재 DOM 일부, 첫 화면, top plausible candidate만 본 상태나 작은 result count는 final miss 증거가 아니다.
5. Receipt가 complete coverage로 exact 없이 끝난 row만 verified whole DB에서 새 search-attempt packet으로 재시도한다. `metadata-rescue-required`/`metadata-rescue-receipt-invalid` 또는 coverage 미완료는 pending/blocked이며 retry budget 소진으로 missed로 바뀌지 않는다.

<!-- METADATA_RESCUE_HUMAN_SSOT:END -->

## Body-Exact Selection Contract

<!-- BODY_EXACT_HUMAN_SSOT:START -->

이 절은 live 후보의 exact 선택에 대한 단일 사람용 기준이다. 평가 claim의 독립성·등급은 별도 workspace `mathsecr-paper-builder-kit/scripts/ground_truth_contract.ps1`가 소유하며, dated benchmark/evidence는 이 live 선택 기준의 독립 oracle이 아니다. 다른 문서와 prompt는 이 절을 참조하고 match 구성요소를 다시 열거하지 않는다.

1. Exact는 문제 body로 판정한다. 객관식 선지(①~⑤ answer choices)의 값·문구·순서 차이는 rejection 사유가 아니다. 문제 본문, 조건, 도형/그래프/표, 수식, 점 이름, 요구값, 본문 내부 `[보기]`와 ㄱㄴㄷ statements가 일치하면 body-exact다.
2. 위 body 구성요소 중 하나라도 mismatch이면 그 candidate 또는 source row만 reject/recovery로 보낸다. Source-paper identity mismatch가 별도로 입증된 경우에만 전체 paper를 차단한다. Previous candidate map, metadata, source ID는 비교 우선순위용 hint일 뿐 blind selection이나 mismatch override 근거가 아니다.
3. 저해상도 PDF/OCR과 후보가 연산자, 부호, prime, 극한 방향, 부등호, 지수·첨자 같은 작은 glyph에서 충돌하면 원본 crop과 후보를 확대 재렌더한다. 원본 번호/`occurrenceKey`, 실제 inspected candidate ID, ProjectRoot-relative source/candidate render artifact, 각 실제 SHA-256과 확대 배율을 raw receipt에 결박한다. 수학적 미결정/모순은 재검토 신호이지 body 증거가 아니다. 충돌이 남으면 `source_anomaly`/pending으로 기록하고 자동 선택하지 않으며, state machine이 artifact bytes와 target/candidate binding을 재검산하기 전에는 이 상태도 인정하지 않는다.
4. Search contract의 `exact-found`도 이 비교를 통과한 inspected/selected identity가 있어야 live 선택으로 확정된다. 유사/대체 문제는 사용자 명시 승인 또는 명시 세션 정책 없이는 exact로 승격하지 않는다.

일반 exact와 metadata-rescue exact 모두 target의 `sourceBodyArtifact`와 `bodyComparisonReceipt`를 남기고 `scripts/body_comparison_contract.ps1`를 사용하는 state machine으로 검증한다. Receipt는 원본 번호/occurrenceKey, 실제 선택 후보 ID, 해당 검색 attempt, 원본·후보 render 경로/해시/배율, `body-only-v1` 정책, 항목별 비교 판정, 비교자/시각, 미해결 glyph 유무를 결합한다. 잘못된 binding, 미해결 또는 mismatch는 선택 및 다음 단계 진입을 막는다. Metadata exact는 선택 후보를 포함하는 bucket의 `observationReceipt`를 `metadata-rescue` attempt로 묶는다. 해시와 receipt 검증은 기록의 일관성만 증명하며 실제 본문 정답이나 독립 평가 oracle을 만들지 않는다. 사용 형식은 `docs/search_preparation_and_selection_evidence.md`를 참조한다.

<!-- BODY_EXACT_HUMAN_SSOT:END -->

## Mission Guards

- mission-first build loop: source order를 준비하고, 최초 scope pass를 돌린 뒤, verified exact를 선택하고, candidate-recovery miss는 applicable metadata rescue를 거친 뒤 남은 misses만 `전체 DB`에서 재시도하고, found exact를 저장/검증한 뒤 misses/out-of-scope/replacements를 보고한다.
- reference success loop: source-order target table, verified exact target IDs in source order, edit-screen order repair, visible save/confirm, reload/fresh-tab fresh exact target ordered ID bundle verification, `출제하기` unclicked 상태를 성공 형태로 삼는다.
- fatal-failure four-gate: risky transition 전 clean same-URL state, scope/search-chip, per-problem mismatch, selected-bundle persistence를 확인한다. 실패한 gate는 recovery, blocker, partial/0-selection reporting이지 `완료`가 아니다.
- fresh-paper search backbone: 새 문제지는 사용자 screenshot scope가 있으면 재현하고, 없으면 위 `DB Inference And Official Collection Contract`로 scope를 판정한 뒤 인쇄된 문제번호 순서로 위 `Search Attempt Contract`를 수행한다. Pending row는 위 `Metadata Rescue And Lazy Coverage Contract`를 거친 뒤 eligible row만 whole DB로 보낸다.
- search-momentum ladder: scope verification -> source-order contract packets -> applicable metadata rescue -> eligible whole-DB contract packet 순서로 간다. 각 단계의 세부 판정은 위 세 canonical contract에서만 읽는다.
- search-attempt SSOT gate: 모든 proof-carrying 검색은 위 `Search Attempt Contract` 절을 따른다. Textbox 잔류값, submit 전 결과, validator가 재계산하지 않은 aggregate Boolean은 검색 증거가 아니다.
- idle-first-search recovery rule: 유휴 시간만으로 live paper를 선제 reload하지 않는다. 2026-07-31 한 authenticated iab session에서 미리 준비한 서로 다른 탭 3개에 동일 query를 각 1회 실행해 source/query `제거` receipt, 명시적 submit, 동일 signature 2회를 관찰했다. 이 frozen 관찰은 availability/latency/result-count 계약도, scope mutation 뒤의 standard fresh receipt나 exact/miss 판정도 아니다. 실제 첫 검색은 기존 freshness gate를 그대로 적용하고, receipt 소실·login redirect·필요한 판독 수 미달·signature 불안정/누락일 때만 reload/reopen recovery로 간다.
- source-occurrence identity gate: 원본의 각 인쇄 위치에는 stable `occurrenceKey`를 주고 DB `problemId`와 분리한다. 2026-07-31 한 live same-card probe에서 first activation은 ID 하나를 선택했고 same-card second activation은 그 선택을 해제했다. 이 dated 관찰을 service-wide toggle 계약으로 일반화하지 않지만, 동일 카드 재클릭을 duplicate insertion으로 쓰지 않는다. 반복 문제가 있으면 별도 visible 복제/추가 control과 ordered bundle 증거가 검증된 경우에만 두 occurrence를 완료 처리하고, 아니면 두 번째 occurrence를 `차단`으로 남긴다.
- append-only resume boundary: reconnect/crash를 넘는 선택 자동화는 `scripts/selection_journal.ps1`의 occurrence-level append/replay를 사용할 수 있다. Journal의 effective occurrence는 offline intent/ACK 상태일 뿐 live selected/edit/persisted bundle 증거가 아니며, 최종 UI 검증을 대체하지 않는다.
- official-guide search contract: 공식 도움말의 기본 흐름은 새 문제지의 `문제 검색` 단계에서 출처와 필터를 먼저 지정하고, 연도/난이도/정답 종류/제외 조건/콘텐츠/텍스트·수식 조건을 필요한 만큼 채운 뒤 `검색하기`, 결과 미리보기, exact 체크, `문제지에 담기` 순서다. 자동 갱신이나 빈 출처 기본값을 계약으로 가정하지 않는다.
- fresh-result after criteria mutation: 출처/단원/텍스트/수식 chip을 추가·삭제한 뒤에는 위 `Search Attempt Contract`의 submit/freshness 절차를 새로 수행한다.
- formula-zero recovery: rendered formula chip과 `<수식> 제거` control은 입력 성공 증거일 뿐 match 성공 증거가 아니다. text+formula가 0건이면 formula chip을 제거하고 동일 Korean text chips로 fresh search를 한 번 복구 실행한 뒤에만 missed/retry를 판단한다.
- prior-ID fast lane: 같은 source retry/handoff에서만 이전 successful/partial session의 target IDs를 빠른 후보 map으로 쓴다. 새 문제지의 기본 mental model로 쓰지 않는다.
- same-URL fresh restart contamination gate: 같은 paper URL에서 scratch retry를 할 때는 edit/persisted IDs를 먼저 확인한다. stale ID가 있으면 visible official controls로 지우고 reload count 0을 확인하거나 새 blank paper를 사용하거나 멈춘다.
- initial-scope fast pass: 사용자 initial DB/source/unit/type scope를 먼저 쓰되, early evidence가 scope 밖을 가리키면 오래 매달리지 않는다. 단, whole DB 전환 전 각 source problem은 selected 또는 initial-scope missed 상태여야 한다.
- phrase-preserving optional prepass: 허용 위치, 1회/1칩 제한, 제거 후 단어 ladder 전환, proof 경계는 위 `Search Attempt Contract` 3항만 따른다.
- candidate-map assist ladder: 위 `Search Attempt Contract`의 candidate recovery에서 previous candidate map은 위 `Body-Exact Selection Contract` 재검증용 hint로만 사용하며 blind select하지 않는다.
- bounded whole-DB retry: 최초 범위 misses만 문제별 최대 4 query attempts 또는 약 5분을 쓴다. 이 값은 비용 상한이며 closure는 위 `Search Attempt Contract`의 derived status만 따른다.
- partial finalization: `requestedAction=partial-save`에서 검증된 found exact만 원본 순서대로 edit screen에 남기고 저장/재로드 검증한다. 나머지는 미해결로 보존한다. final missed는 검색 계약의 폐쇄 판정이 있는 row만 쓴다.
- recovery before stop: UI collapse 또는 modal filter reset이 생기면 ordered reselection, verified edit-screen recovery, Aside REPL reconnect/reopen을 먼저 시도하고, 막히면 blocker로 보고한다.
- text-search escape hatch: 검색 contract가 pending을 반환해도 그 문제만 recovery에 남기고 verified exact 작업은 계속한다. Pending은 전체 중단이나 near-miss 선택 사유가 아니다.
- near-miss scan budget: initial 2-chip pass에서 비슷하지만 non-exact 후보가 많으면 top plausible same-source/metadata만 보고 metadata rescue로 넘길 수 있다. 이 제한은 final miss 근거가 아니며, metadata rescue의 complete lazy-result coverage를 생략하지 못한다.
- 검색 전 scope gate: 모든 `검색하기` 전 source/problem-paper chip, unit/type chip, query chip, current mode를 기록한다. whole DB 중이면 visible/selected UI evidence로 의도적 `전체 DB`임을 남긴다.
- 결과 cardinality guard: blank-source 또는 예상 밖 huge results는 scope failure다. 카드 선택, `전체 선택`, `다음 단계` 금지.
- 위험 행동 스냅샷: `문제 검색` re-entry, broad chip deletion, `전체 DB`, `다음 단계`, edit add/reorder/save 전 URL/title, selected N/T, 위 contract의 raw packet과 derived status, result/DOM count, ordered target IDs, misses/out-of-scope/replacements, intended click, save-equivalent state를 기록한다.
- 저장 검증 패킷: save/reload 전후 source target count, draft/local count, final confirmed fresh exact target ordered ID bundle, persisted/reloaded count and order, `확인` clicked/absent, fresh reload/fresh tab, `출제하기` not-clicked를 기록한다.
- 탐색 URL 격리: help/docs/API/raw route는 live paper tab 밖에서만 본다. live tab이 이동하면 paper URL로 돌아가 저장 상태를 확인한다.
- preflight exact mismatch stop: 위 `Body-Exact Selection Contract`의 verdict를 따른다. Candidate mismatch는 해당 row만 recovery로 보내고, 별도로 입증된 source-paper identity mismatch만 전체 paper를 차단한다.
- selection-bundle persistence gate: `다음 단계` 직후 search UI 선택 묶음이 draft/edit state에 유지됐는지 확인한다. selected 18이 draft 1로 줄거나 old IDs가 나타나면 contaminated collapse로 보고한다.
- edit-modal source gate: edit-screen `문제 추가하기` 또는 `문제 검색` modal은 source selector를 reset할 수 있다. modal `검색하기` 전 source chip/checkbox를 다시 확인한다.
- completion-first retry budget: found exact를 먼저 살리고, 남은 misses에만 제한 retry를 쓴다. 일부 미발견 때문에 전체를 포기하지 않는다.
- edit-before-search-complete ban: pre-edit search completion gate means 가능하면 initial-scope search, candidate-recovery pass, applicable metadata rescue, and whole-DB missed retry를 끝낸 뒤 `다음 단계`로 간다. 추가 검색 경로가 검증되지 않은 편집 화면으로 너무 빨리 들어가면 검색력 회귀가 생긴다.
- 승인된 부분 저장은 위 권고의 예외다. 검색을 닫지 못한 row 때문에 검증된 묶음의 저장을 막지 않는다. `BeforeNext` 판정과 실제 선택 순서를 확인한 뒤 진행하고 미해결 목록을 유지한다.
- stable-save checkpoint: stable exact batches 후, metadata rescue 전후, initial scope에서 `전체 DB` 전환 전, whole-DB additions 후, final ordering 후 visible save-equivalent가 있으면 누르고 reload/fresh-tab fresh exact target ordered ID bundle을 확인한다.
- whole-DB text retry gate: metadata rescue가 exact 없이 complete coverage로 끝난 missed row만 whole DB scope에서 위 `Search Attempt Contract`를 새 packet으로 수행한다.
- missed-number finalization: 각 미발견 row는 위 실행 contract가 `miss-closure-ready`를 반환하고 workspace `AGENTS.md`의 report receipt 결박을 통과한 경우에만 missed로 확정한다.
- zero-selection completion label: 모든 source problem이 missed이고 selected count 0이면 paper build `완료`나 `부분 완료`가 아니다. `검색 완료/0선택`으로만 보고한다.

## Workflow

### 1. Source Order 준비

1. PDF/HWPX를 읽고 원본 순서 working list를 만든다.
2. text extraction이 약하면 page render/contact sheet/image extraction으로 시각 확인한다.
3. 4페이지 초과 PDF는 4-page read-only batch로 나눈다.
4. answer/solution pages가 분리되어 있으면 problem pages만 inventory한다.
5. two-up/booklet/left-right/mixed-section print는 OCR 순서보다 printed problem number를 믿는다.
6. visible source metadata가 있으면 source, year, organization, course, month/exam, problem number, notes를 먼저 표로 만든다.
7. printed metadata block이 같은 문제끼리 cluster하고, 한 PDF가 단일 source인지 혼합 source인지 표시한다.
8. target table은 source number, stable occurrence key, printed source family/subject/year, metadata cluster, transcription confidence/conflict, clues, initial candidate, metadata-rescue receipt, cumulative inspected result IDs, whole-DB candidate, selected ID, status(`selected`, `missed`, `source_anomaly`, `replacement`, `blocked`)를 가진다. 같은 DB problem ID가 반복되어도 occurrence row를 합치지 않는다.
9. 원문 전사와 제안 단어로 query plan을 미리 검증한다. `ready`인 문항의 ordered initial chips만 입력 준비에 쓰고, `blocked`인 문항은 전사/단어를 다시 읽는다. `sourceBodyArtifact`는 해당 occurrence의 원본 crop 경로와 실제 SHA-256으로 고정한다.

### 2. Browser 안정화

1. 기본 selection viewport는 `1440x900`이다.
2. surface가 aside-repl이면 Aside REPL을 쓴다. `aside-browser` 지침에 따라 CLI/guide를 확인하고, `listBrowserTabs()`로 열린 탭을 먼저 조회한 뒤 관련 MathSecr 탭에 `attachBrowserTab(targetId)`로 attach한다. 현재 활성 탭 자체가 사용자 지목 대상일 때만 `attachActiveBrowserTab()`을 쓴다. 판독은 `snapshot(page, { interactive: true })`부터 시작해 필요한 경우 전체 snapshot과 screenshot으로 확장하며, 실제 관측을 바탕으로 `나만의 DB 선택`, `내 문제지 선택`, `단원 및 유형 선택`, text/formula search input, `검색하기`, sidebar collapse, `다음 단계`, edit-screen `문제 검색`, save-equivalent `확인` control map을 만든다.
3. viewport, modal, scroll, reconnect/resume, chip wrapping 후 control map을 갱신한다.
4. `/mypaper/<id>` URL, 로그인 상태, visible paper title을 확인한다.
5. 같은 URL에서 start-over면 기존 edit/persisted 문제 존재 여부를 먼저 확인한다.
6. 오래 열린 tab도 경과 시간만으로 reload하지 않는다. source/query removal receipt와 로그인 상태를 확인하고 기존 freshness gate의 필요한 판독 수를 충족하면 계속하며, receipt/login/freshness gate가 깨진 경우에만 recovery한다.

### 3. Initial Scoped Pass

1. 사용자 screenshot의 DB/source/unit/type scope가 있으면 설정한다. 없으면 위 `DB Inference And Official Collection Contract`를 수행하고 resolver의 direct `dbInference` output을 state snapshot에 둔다.
2. Inference가 `pending`/`unresolved`이면 evidence/receipt만 복구하고 selection을 막는다. Ready candidate의 scope-lock도 위 DB contract의 current route를 따른다.
3. 새 문제지는 printed problem-number order로 검색한다.
4. 각 source row는 위 `Search Attempt Contract`의 initial-scope packet으로 검색한다. `exact-found`이면 위 `Body-Exact Selection Contract`를 통과한 candidate만 선택하고, 아니면 derived status를 그대로 유지한다.
5. `candidate-recovery-pending`은 contract-owned routes를 수행한다. Previous IDs와 metadata는 검증 가속 수단일 뿐 blind selection 근거가 아니다.
6. Printed metadata가 있어 rescue 대상인 pending row는 whole DB 전에 위 `Metadata Rescue And Lazy Coverage Contract`를 수행한다. Rescue 뒤 whole-DB 전환과 최종 miss도 canonical derived status만 따른다.

### 4. Text Search 세부

- 검색 chip, provenance, submit/freshness, adaptive refinement, backoff, candidate coverage, outcome 판정은 위 `Search Attempt Contract`만 따른다. 기호·도형은 literal/index receipt가 없으면 result-card visual scan 우선순위로만 쓴다.
- formula search는 2~3개 normalized variant 후 멈춘다. 수식은 일반 `텍스트 및 수식 검색` 입력칸에 literal string으로 넣지 말고, 반드시 `f(x)` button -> `수식입력` modal -> `수식 수정` 입력칸 -> `추가하기`로 formula chip을 만든 뒤 검색한다. `손글씨 입력기` tab은 클릭하지 않는다.
- `수식입력` preview buttons append to the current `수식 수정` value. 새 수식 전에는 visible `입력 초기화`로 값을 비우고, `fill("")`만으로 React state가 비워졌다고 가정하지 않는다.
- 2026-06-08 formula preview grammar observed in MathSecr: `x^a` -> `x^{a}`, `x_a` -> `x_{a}`, root -> `\sqrt{x}`, nth root -> `\sqrt[n]{x}`, absolute -> `\left|x\right|`, log -> `\log_{a}x`, sum -> `\sum_{k=1}^{n}a_{k}`, integral -> `\int_{a}^{b}f(x)dx`, limit -> `\lim_{n\to\infty}f(x)`, overline -> `\overline{AB}`, vector -> `\overrightarrow{AB}`, angle -> `\angle ABC`, sin/cos/tan -> `\sin\theta` / `\cos\theta` / `\tan\theta`, derivative -> `\frac{dy}{dx}`, pi -> `\pi`. The fraction-looking `a/b` preview inserted `\overline{AB}` in this session; verify before using it as a fraction clue.
- Formula chip search was observed to execute (`\pi` chip returned `검색결과 : 4,280개` in the tracked 2026-06-08 scoped session) but it is broad and fragile. Result cardinality is scope-dependent evidence, not a stable product contract. Scope gate still applies before `검색하기`; if no source/problem-paper chip can be verified, record it as scope-risk evidence and never select/add from broad formula-only results.
- generic/global `추가`가 Tag/modal을 열면 `취소`하고 control map을 다시 잡는다.

### 5. Select And Track

- 위 `Body-Exact Selection Contract`를 통과한 exact만 선택한다.
- 현재 Aside REPL에서 증거에 맞는 snapshot/DOM 판독 또는 스크린샷을 사용한다. ID·선택 상태·검색 chip은 확인된 DOM/control을, 본문·수식·도형과 시각 배치는 화면을 보고 판단한다. 필요한 증거가 충분하면 형식만 바꿔 중복 판독하지 않는다. 검색 observation과 body 비교 receipt 요건은 그대로 충족한다.
- sidebar가 checkbox를 가리면 접는다.
- 지원되는 locator가 대상을 명확히 가리키면 사용하고, 화면에서만 명확한 visible label은 현재 스크린샷/위치 근거로 클릭할 수 있다.
- coordinate/menu fallback 후 selected count, selected ID/order, checkbox/label state를 즉시 확인한다. 이것은 같은 Aside REPL 세션 안의 UI 조작이며 다른 browser surface fallback이 아니다.
- previous-session target IDs, reader reports, candidate summaries는 reverified 전까지 hints다.
- 동일 result card를 다시 누르는 동작은 duplicate insert로 쓰지 않는다. Dated same-card second activation은 관찰된 경로에서 기존 선택을 해제했으며, live UI가 검증된 별도 복제/추가 control을 제공하지 않으면 반복 occurrence 하나를 선택 하나로 축약하지 말고 해당 occurrence를 blocked로 유지한다. 별도 control을 썼다면 edit/persisted ordered bundle에 두 occurrence가 실제로 남았는지 검증한다.

### 6. Metadata Rescue And Misses Retry

1. DB 전환 전 checkpoint를 남긴다.
2. Eligible row는 위 `Metadata Rescue And Lazy Coverage Contract`를 수행하고 raw receipt를 상태 머신이 재계산하게 한다.
3. Rescue가 exact를 찾으면 위 `Body-Exact Selection Contract`를 거쳐 선택한다. Exact 없이 complete coverage가 파생된 row만 verified whole DB에서 위 `Search Attempt Contract`를 새 scope packet으로 수행한다.
4. Whole-DB contract가 `exact-found`를 반환하면 body-exact를 재확인해 선택하고 outside-initial-range로 기록한다. `miss-closure-ready`만 missed로 닫고 그 밖은 pending/blocked로 유지한다.
5. Similar/replacement/`source_anomaly`는 사용자 명시 승인 또는 명시 세션 정책 없이는 선택하지 않는다.

### 7. Final Edit, Order, Persistence

1. selected count가 0이면 `다음 단계`를 누르지 않는다. 모든 source row가 contract-derived final `missed`일 때만 `검색 완료/0선택`으로 보고하며, `source_anomaly`/pending row가 하나라도 있으면 0-selection을 닫지 않는다.
2. `requestedAction=partial-save`에서는 선택된 row의 검색·본문 증거를 먼저 검증한다. 검증된 exact가 1개 이상이면 미선택 pending·`source_anomaly`·미실행 row를 미해결로 보존하고 선택 묶음만 편집·저장한다. 미해결 후보는 선택하지 않는다. 부분 저장 동작이 아니면 기존 검색 완료 후 편집 경로를 따른다. exact 0개나 scope·원본 identity·선택 증거·저장 순서 오류에는 이 예외를 적용하지 않는다.
3. `다음 단계` 후 final confirmed fresh exact target ordered ID bundle이 draft/edit state에 보존됐는지 확인한다.
4. edit screen에서 fresh target order와 card order를 비교한다. 대표 ID는 중간 sanity check일 뿐 완료/부분 완료의 최종 증거가 아니다.
5. unknown old IDs 또는 missing fresh IDs가 보이면 contaminated state로 표시한다.
6. browser Back은 쓰지 말고 paper URL을 다시 열어 visible controls로 복구한다.
7. position-specific reorder는 visible card menu `...` -> `문제 이동`을 우선한다.
8. keyboard/drag/coordinate fallback은 즉시 order 확인이 가능할 때만 쓴다.
9. `번호순 정렬`은 임의 source order에 신뢰하지 않는다.
10. visible enabled `확인`이 있으면 add/reorder 후 누른다. hidden/body template text는 저장 버튼으로 보지 않는다.
11. 최종 보고 전 reload 또는 fresh tab으로 fresh exact target ordered ID bundle, replacements, misses, `출제하기` not-clicked를 확인한다. ID가 UI/DOM에서 확인되지 않으면 card identity/source metadata/visual exact evidence를 함께 기록하되 count만으로 완료를 증명하지 않는다.

## Report

모든 세션은 상세 `MathSecr 세션 보고서`를 내부 검증 패킷으로 유지한다. 허브가 범위에 있으면 `AGENTS.md`의 내부 템플릿을 채우고 기존 report contract로 검증한다. 패킷은 문제지 제작 결과 응답에 결합하지 않으며, 사용자가 내부 진단 패킷 자체를 요청한 별도 질의에만 별도 응답 또는 artifact로 제공한다.

일반 text-search의 receipt는 `scripts/prepare_selection_evidence.ps1`로 실제 target JSON을 검증·조립하고, metadata-rescue는 기존 검증 경로를 사용한다(`docs/selection_evidence_preparation.md`). 검증된 `Projection`/`SelectionEvidence`를 보고서에 재사용해 형식만을 위한 재판독이나 수기 복사를 줄인다. 실제 판독 횟수·동작·비교자·시각을 만들어 넣거나 본문 판정을 자동으로 exact로 채우지 않는다.

<!-- PRODUCTION_VALIDATION_REF --> 실제 제작에서는 `scripts/check_browser_surface.ps1 -Surface <surface>`로 현재 브라우저 응답을 기록하고 `scripts/validate_production_step.ps1`로 Select·BeforeNext·AfterReload를 검사한다. Select를 통과한 후보만 실제 UI에서 선택한다. BeforeNext는 미래 편집·저장·재로드를 요구하거나 생성하지 않는다. AfterReload는 실제 persisted 묶음에서 보고서를 파생하고 검증한다. 입력과 실행 예시는 `docs/production_validation.md`를 따른다.

사용자 표시 최종 응답은 한국어 0–4 항목만 쓴다. 제작한 문제지 링크와 실패 이미지 크롭 보고서 PDF 링크만 공개 링크이며, 필터·내부 상태·도구·검증 설명은 상세 패킷에 남긴다.

실제 Aside 종료가 확인된 제작 요청은 `ASIDE_OFF_USER_RESPONSE`의 한 줄 응답을 쓴다. 미실행 row의 검색 근거는 만들어 넣지 않으며 typed 결과에서 `not-started`로 보존한다. 공개 실패 번호와 PDF는 저장하지 못한 원본 문항에 대응한다.

```markdown
0. 제작한 문제지 링크
   - [문제지 이름](https://www.mathsecr.com/mypaper/<paper-id>)
1. 성공한 문제 <성공 문제 수>문제/<전체 문제 수>문제
2. 실패한 문제 <실패 문제 수>문제/<전체 문제 수>문제
   1. <원본 문제 번호를 쉼표로 묶은 목록 또는 없음>
3. 실패한 문제 이미지 크롭 보고서 PDF
   - [실패 문제 보고서 PDF](<실제 PDF 파일 경로>)
4. 출처
   1. <정규화한 출처> — <성공 문제 수>문제
```

- 성공 수는 최종 persisted/reload 검증을 통과한 exact 원본 문제 수이고, 실패 수는 원본 전체 수에서 성공 수를 뺀 값이다. 표기는 `S문제/T문제`, `F문제/T문제`를 그대로 유지하며 공개 형식에는 `#`와 `@`를 쓰지 않는다.
- 실패 번호는 `1번, 2번`처럼 원본 번호를 쉼표로 묶은 한 줄로 쓰며, 실패가 0이면 `없음`만 쓴다. 문제 번호가 없는 session-wide blocker는 `전체 세션 — 차단`으로 쓴다.
- 일반적인 실패가 하나라도 있으면 실패 번호에 대응하는 실제 PDF 크롭 보고서 링크가 필수다. 실패가 0이면 PDF 줄은 `- 없음`으로 쓰고, 전체 세션 blocker 예외에서도 `- 없음`을 허용한다.
- 4번 출처는 최종 persisted/reload 검증된 성공 카드의 visible `DB명`에서 source family/root를 정규화해 집계한다. `교육청`, `평가원` 등 official DB는 조직 family/root로 묶고, 그 외 DB는 `>` 앞 root에서 leading edition year를 제거한다. 실패 문항은 제외한다.
- 출처는 빈도 내림차순, 동률은 원본/편집 첫 등장 순서로 최대 3개 순위만 쓴다. 서로 다른 출처가 1–2개면 그만큼만 쓰고, 성공 0이면 `1. 없음`만 쓴다. 예: `교육청 — 9문제`, `EBS 올림포스 고난도 공통수학1 — 2문제`, `블랙라벨 공통수학1 — 1문제`.
- 사용자 표시 초안은 `Invoke-MathSecrUserSummaryLint`로 검증한다. 위 0–4 항목 외 heading/본문, 내부 URL, ID, 검색어, counts/status 설명, `#`/`@`가 붙은 성공·실패 표기, 허용되지 않은 번호·링크가 있으면 출력하지 않고 수정한다.

## Notes

- LaTeX skill은 OCR이 아니다. formula transcription 후 rendering/compile/runtime checks에만 쓴다.
- official MathSecr guides는 용어 확인에 유용하지만 live paper tab에서 열지 않는다.
- feature exploration은 `변경하기`, `추가하기`, `전체 선택`, `선택 삭제`, `출제하기` 같은 state-changing controls를 사용자 요청 없이 누르지 않는다.
