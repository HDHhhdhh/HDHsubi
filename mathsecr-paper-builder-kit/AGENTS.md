# MathSecr Paper Builder Hub

이 워크스페이스는 MathSecr/수학비서 문제지 생성 세션과 재사용 skill을 관리하는 허브다. 모든 작업자는 이 문서와 Codex home 아래 `skills/mathsecr-paper-builder/SKILL.md`를 함께 따른다. Codex home은 `CODEX_HOME` 설정값을 우선하고, 없으면 `%USERPROFILE%\.codex`를 사용한다.

## 문서 역할

- `AGENTS.md`: 세션 정책, 보고 형식, 브라우저 소유권, handoff, evidence 관리.
- Codex home의 `skills/mathsecr-paper-builder/SKILL.md`: 검색, 선택, 재시도, 정렬, 저장, 검증 실행 절차.
- `mathsecr-paper-builder-kit/AGENTS.md`는 이 문서의 canonical source이고 workspace root `AGENTS.md`는 installer가 만드는 동기화 mirror다. 둘을 따로 편집하지 않는다.
- 조정/보고/브라우저 소유권 lesson은 `AGENTS.md`에만 승격한다.
- 검색/선택/저장/검증 행동 lesson은 `SKILL.md`에만 승격한다.
- <!-- SEARCH_ATTEMPT_SSOT_REF --> 검색 시도의 provenance, literal ladder, backoff, candidate recovery, miss closure 행동은 Codex home `skills/mathsecr-paper-builder/SKILL.md`의 `Search Attempt Contract` 절만 따른다. 실행 판정은 `mathsecr-paper-builder-kit/scripts/search_attempt_contract.ps1`만 소유하며 AGENTS는 이를 재정의하지 않는다.
- <!-- DB_INFERENCE_SSOT_REF --> DB/source 미지정 추론과 current official-collection scope-lock 행동은 `mathsecr-paper-builder-kit/skills/mathsecr-paper-builder/SKILL.md`의 `DB Inference And Official Collection Contract`만 따른다. 판정 schema와 실행 기준은 `mathsecr-paper-builder-kit/docs/db_inference_contract.md`와 `mathsecr-paper-builder-kit/scripts/db_inference.ps1`이 소유하며 AGENTS는 이를 재정의하지 않는다.
- <!-- METADATA_RESCUE_SSOT_REF --> Metadata rescue와 lazy-result coverage 행동은 kit SKILL의 `Metadata Rescue And Lazy Coverage Contract`만 따른다. Receipt 재계산은 `mathsecr-paper-builder-kit/scripts/state_machine.ps1`, rescue search packet 판정은 `mathsecr-paper-builder-kit/scripts/search_attempt_contract.ps1`이 소유하며 AGENTS는 이를 재정의하지 않는다.
- <!-- BODY_EXACT_SSOT_REF --> Live body-exact 선택 행동은 kit SKILL의 `Body-Exact Selection Contract`만 따른다. 평가 claim 독립성은 별도 `mathsecr-paper-builder-kit/scripts/ground_truth_contract.ps1`이 소유하며 AGENTS는 match 구성요소를 재정의하지 않는다.
- 반복 source occurrence의 offline 상태-machine 계약은 `mathsecr-paper-builder-kit/scripts/state_machine.ps1`와 `docs/mathsecr_success_algorithm.md`가 소유한다. `occurrenceKey`는 앞뒤 공백·쉼표·CR/LF가 없고 exact `없음` 예약값이 아닌 canonical opaque string이며 내부 공백(TAB/NBSP 포함)과 대소문자는 그대로 보존한다. 선택 수가 0보다 크면 selected/edit/persisted occurrence-key bundle은 모두 absent/empty이거나 모두 선택된 target 순서와 정확히 일치해야 하며, 하나만 있거나 ghost/mismatch면 차단한다. 같은 DB `problemId`를 두 번 보존하려면 각 반복 target의 distinct `occurrenceKey`, typed duplicate/add control receipt, selected/edit/persisted occurrence-key bundle이 모두 필요하며, 하나라도 없으면 later occurrence를 `차단`한다.
- Codex home의 installed skill은 kit에서 설치·동기화되는 산출물이다. 이번 계약 변경에서 installed copy를 직접 편집하지 않으며, kit `SKILL.md`가 바뀌는 경우에만 공식 installer/`-Force` 경로로 동기화하고 `SyncContract`를 다시 확인한다.
- 사고 lesson의 구조화 상태는 `mathsecr-paper-builder-kit/test-fixtures/lessons/re0-memo-registry.json`이 소유한다. `high`/`repeated` lesson은 evidence, negative corpus, validator, 전체 runner label을 모두 가진 `gated` 상태여야 하며, 독립 실패 신호가 부족한 관찰은 `record-only`로 남겨 강제 gate처럼 보고하지 않는다.
- 평가 claim의 독립성은 `mathsecr-paper-builder-kit/test-fixtures/evaluation/ground-truth-claims.json`과 `scripts/ground_truth_contract.ps1`이 소유한다. 해시는 artifact identity만 증명하며, source body·candidate body·독립 판정 중 필요한 oracle 면이 빠진 평가는 `dated-characterization` 또는 `offline-contract`로만 PASS할 수 있다. gold, fixture, evidence, evaluator를 서로의 독립 oracle로 재사용하지 않는다. body-exact의 `external-ground-truth` 승격은 typed adjudication receipt가 exact source/candidate artifact hashes를 결합하는 validator가 생길 때까지 금지한다.
- 문서는 간결하게 유지한다. one-off 로그는 evidence/report에 두고, 재사용 규칙만 승격한다.

## 임무 원칙

- mission-first completion loop: 원본에서 만들 수 있는 가장 쓸모 있는 MathSecr 문제지를 만든다.
- 임무 완수 우선: 찾은 exact 문제는 원본 순서대로 선택하고, 편집 화면까지 가져가며, 저장 또는 재로드 검증 후 보고한다.
- 부분 완성 기본값: 일부 문제를 못 찾아도 전체를 멈추지 않는다. 검증된 exact를 남기고 미발견 번호를 정확히 보고한다.
- 부분 저장 허용: `requestedAction=partial-save`에서는 검증된 exact 묶음을 저장하고 나머지는 미해결로 보존한다. 미해결 후보는 선택하지 않으며 budget 소진을 final missed로 바꾸지 않는다. scope·원본 identity·선택 증거·저장 순서 오류는 계속 차단한다.
- 신규 문제지 검색 backbone: 사용자 스크린샷의 DB/출처/단원/유형을 최초 범위로 재현하고, 인쇄된 문제번호 순서로 검색한다.
- 최초 세팅 우선: 최초 scope는 첫 pass 기준이지 영구 장벽이 아니다.
- 텍스트 검색 주도: 새 문제지는 source-order text search가 기본이다. metadata, inventory, same-source run은 가속 수단이지 대체물이 아니다.
- DB 미지정 scope 추론: 위 DB inference SSOT의 resolver output을 상태에 직접 사용한다. `pending`/`unresolved` 또는 불완전 receipt는 scope 선택을 막는다.
- 검색 회귀와 miss 처리: SKILL의 `Search Attempt Contract` derived status를 따른다. `exact-found`는 선택/검증으로, `miss-closure-ready`만 미발견으로, 그 밖은 `candidate-recovery-pending`/차단으로 조정한다.
- 안정 지점 저장: 안정 exact batch 후, `전체 DB` 전환 전, 최종 편집 후에는 visible/enabled 저장-equivalent가 있으면 누르고 reload/fresh-tab으로 확인한다.
- exact 범위 밖 선택 허용: `전체 DB` 등 최초 범위 밖 exact는 선택 가능하지만 보고서에 원본 번호, ID, DB/출처, 벗어난 범위를 적는다.
- 본문 기준 exact: 위 body-exact SSOT의 verdict만 선택 근거로 사용한다. 유사/대체 문제는 exact와 분리한다.
- 미발견 번호 정확 보고: budget 내 exact를 못 찾으면 missed로 표시하고 시도 단서어를 남긴다.
- 0선택 상태 분리: exact 0개이고 모든 source row가 contract-derived final missed이면 `검색 완료/0선택`으로만 보고한다. `source_anomaly`/pending row가 있으면 닫지 않으며, `완료`나 `부분 완료`로 쓰지 않는다.
- 유사/대체 문제는 exact와 다르다. 사용자 명시 승인 또는 명시 세션 정책 없이는 선택하지 않는다.

## 성공 기준과 실패 게이트

- 초기 성공 루프: `source-order target table -> exact target IDs in source order -> edit-screen count/order repair -> save/reload/fresh-tab verification packet -> 출제하기 not clicked`를 목표 형태로 삼는다. 1차 성공 근거는 `019e82cc-9f18-7601-a9fd-8d6b0403ea76`, `019e827f-e3a3-7023-b665-c68af99c61b6`, `019e8215-409b-7ce1-a531-34c63c808ca3`, `019e916c-dc66-7322-8bec-37d361351ff3`.
- 치명 실패 4게이트: 완료 보고 전 반드시 clean same-URL state, verified scope/search chips, per-problem mismatch 처리, selected-bundle persistence를 확인한다.
- Same-URL fresh restart contamination gate: 같은 URL에서 새로 시작하면 먼저 edit/persisted 문제 ID가 비어 있음을 확인한다. stale ID가 있으면 공식 UI로만 지우고 reload count 0을 검증한다.
- preflight exact mismatch: 위 body-exact SSOT에서 candidate mismatch로 판정된 row만 recovery로 보내며, 별도로 입증된 source-paper identity mismatch만 전체 paper를 차단한다.
- selected-bundle collapse 후에는 완료가 아니다. fresh target ID가 사라지거나 old ID가 나타나면 recovery/blocker로 보고한다.
- 다음 단계 전 검색 완료 / edit-before-search-complete ban: 가능하면 initial-scope pass, candidate-recovery pass, `전체 DB` missed retry를 끝낸 뒤 `다음 단계`로 간다. 편집 화면 진입 후 추가 검색 경로가 검증되지 않은 상태에서 1차 발견분만 조기 저장하면 검색 추진력이 떨어질 수 있다.
- 부분 저장 전이 예외: 위 검색 완료 권고는 승인된 부분 저장을 막지 않는다. 실제 선택 증거를 먼저 검증하고 `BeforeNext` 판정이 허용한 묶음만 편집으로 보낸다. 미해결 목록과 근거를 유지한다. 검색 재진입은 실제 지원 경로를 별도로 확인한다.
- persisted/reloaded 검증은 매 문제마다 하지 않는다. 다만 시작, 위험 전환, `다음 단계` 직후, 최종 보고 전에는 최종 확정 fresh exact target ordered ID bundle이 draft/edit/persisted/reloaded 상태에 유지되는지 비교한다. 대표 ID는 중간 sanity check일 뿐 완료/부분 완료의 최종 증거가 아니다.

## 브라우저 소유권

- live MathSecr 조작은 primary agent만 Aside REPL로 한다. subagent는 read-only unless explicitly assigned a separate live session.
- 원격 작업을 명시 요청받지 않았으면 모든 Aside 호출에 `--host local`을 지정한다. CLI에 저장된 기본 host를 상속하지 않는다. 기기 이름을 해석하기 전에 `[Environment]::MachineName`으로 현재 실행 PC를 확인한다. host 목록의 이름이나 `remote:` 표기는 다른 PC라는 증거가 아니다. local 연결 실패 후 원격 전환이나 기본 host 변경을 자동으로 하지 않는다. 원격 probe는 실제 사용자 지시를 기록하고 `-RemoteRequested`와 `-RemoteRequestEvidence`를 함께 전달한 경우만 허용한다.
- 탭·URL·제목·로그인·프로필·화면 상태는 현재 도구와 실제 관측으로 직접 확인한다. 도구로 확인할 수 있는 정보에 대해 사용자에게 무엇이 보이는지, 탭이 보이는지, 어느 PC인지 반복해서 묻지 않는다. 지원되는 진단을 마친 뒤에도 사용자만 제공할 수 있는 정보나 행동이 진행에 꼭 필요한 경우에만 이유와 필요한 항목을 한 번에 질문한다.
- Aside REPL 우선: `aside-browser` 지침에 따라 `aside --update`, `aside guide`, `aside guide repl`을 확인한 뒤 열린 탭을 먼저 조회하고 관련 탭에 attach한다. 페이지 판독은 `snapshot()`을 기본으로 하며, 새 탭은 관련 기존 탭이 없거나 사용자가 명시 요청한 경우에만 연다.
- Aside REPL 실패 차단: Aside REPL이 unavailable/crash 상태이거나 live paper에 attach하여 URL/title/login을 확인하지 못하면 그 세션은 `차단`으로 보고한다. Codex in-app Browser(`iab`), Chrome, extension, Computer Use로 자동 전환하지 않는다.
- <!-- ASIDE_OFF_USER_RESPONSE --> 제작 요청에서 현재 Aside probe가 브라우저 종료를 확인하면 사용자 응답 전체는 `aside 키고 다시 오도록.` 한 줄이다. 따옴표·설명·0–4 요약을 붙이지 않는다. 내부 차단 기록은 유지한다. 일반 timeout, CLI 부재, 로그인·paper 검증 실패는 종료로 단정하지 않는다. 코드 검토·구현 작업에는 이 제작 응답 예외를 적용하지 않는다.
- idle-tab recovery ownership: 미리 준비된 live tab은 경과 시간만으로 reload/reopen하지 않는다. primary agent가 URL/title/login과 source/query removal receipt를 다시 확인하고 SKILL의 ordinary freshness gate를 적용한다. receipt/login/freshness가 깨진 경우에만 recovery한다. 2026-07-31의 15/30/60분 관찰과 frozen offline fixture는 이 recovery 기준의 dated 근거일 뿐 availability/latency/result-count, standard fresh receipt, exact/miss 계약이 아니다.
- 절대 `출제하기`를 클릭하지 않는다. 사용자가 명시 요청한 경우만 예외다.
- live paper tab에서 API route, raw backend URL, verification URL, MathSecr help/docs를 열지 않는다. 사고가 나면 paper URL을 다시 열고 persisted state를 확인한다.
- Stop only for true blockers: missing source file/list, login redirect, unverified paper URL/title, source-paper identity mismatch, unavailable live browser, unrecoverable state loss.

## Scope 선택 규칙

- `검색하기` 전에는 DB/source/problem-paper scope를 확인한다. 빈 범위 검색은 실패가 아니라 대량 broad result를 낼 수 있다.
- 빈 범위 검색 또는 예상 밖 huge result는 scope failure다. 카드 선택, `전체 선택`, `다음 단계` 금지.
- `전체 DB` retry는 visible/selected UI evidence로 `전체 DB` mode가 확인된 상태만 의미한다. empty/unverified source scope는 `전체 DB`가 아니다.
- `교육청, 평가원` 직접 체크박스 예외 (version-aware current route): current selector 경로와 receipt 요건은 위 DB inference SSOT에서만 읽는다. Dated route wording이나 navigation state를 live scope-lock 지시로 재사용하지 않는다.
- 일반 DB/과목/단원/유형/문제지 scope는 검색창이 있으면 검색어를 입력한 뒤 matching row 왼쪽 checkbox/label을 클릭한다.

## Required Refresh

세션 최초에는 이 문서와 `SKILL.md`를 전체 읽고 각 파일의 경로와 SHA-256을 기록한다. 다음 시점에는 파일 해시와 현재 작업에 관련된 짧은 절만 재확인하고 3줄 이하 checkpoint를 남긴다. 정책 파일이 바뀌거나 문맥이 소실되어 읽은 버전·규칙을 확인할 수 없으면 두 문서를 전체 다시 읽는다.

문서 재확인과 별도로 현재 선택·필터·저장 상태는 기존 위험 단계 및 persistence 계약대로 실제 확인한다.

- 10문항 선택마다.
- reconnect, resume, context compaction, Aside REPL reconnect/reopen 후.
- `문제 검색` re-entry 전.
- broad chip deletion 또는 filter reset 전.
- `전체 DB` 포함 DB scope 전환 전.
- `다음 단계` 클릭 전.
- 최종 편집 화면에서 완료 보고 전.

체크포인트 형식:

```text
체크포인트: 선택 N/T, 필터: ..., 미발견: ...
범위 밖/대체: ...
다음 작업: ...
```

## 상태와 복구

- 위험 행동 스냅샷: `문제 검색` re-entry, broad chip deletion, `전체 DB`, `다음 단계`, edit add/reorder/save 전에는 URL/title, 선택 N/T, chips, result count, DOM card count, target IDs, misses/out-of-scope/replacements, next click, save-equivalent state를 기록한다.
- 이전 세션 target ID는 같은 source/session retry에서만 strong hint다. 새 문제지의 기본 mental model로 쓰지 않는다.
- edit-screen source selectors can reset. modal `검색하기` 전에는 source chip/checkbox를 다시 확인한다.
- browser Back은 collapse/route 사고 복구 수단으로 쓰지 않는다. paper URL을 다시 열고 visible MathSecr controls만 사용한다.
- `번호순 정렬`은 arbitrary source order에 신뢰하지 않는다. 사용했다면 즉시 order를 확인한다.

## Persist Before Reporting

- 검증 패킷 없이 완료 보고하지 않는다.
- 검증 패킷은 `다음 단계` 전, edit-screen 변경 후, reload/fresh-tab 후 갱신한다.
- <!-- PRODUCTION_VALIDATION_REF --> 실제 제작은 `scripts/check_aside_repl.ps1`의 현재 probe, `scripts/validate_production_step.ps1`의 Select·BeforeNext·AfterReload 검사를 사용한다. 선택 판단·시각·동작을 자동으로 채우지 않는다. 보고는 동일한 버전 있는 세션 결과의 원본 roster·persisted 카드·raw visible DB명에 결합한다. 세부 입력은 `docs/production_validation.md`를 따른다.
- 최소 필드: original source count, selected count, draft/local count before save, persisted/reloaded count and order after save, `확인` clicked/absent, fresh reload/fresh tab, missed/out-of-scope/replacement lists, live tab route/help/docs accident, `출제하기` not clicked, and the final persisted-card source aggregation receipt (`raw visible DB명` → normalized source family/root → count/top3).
- 미발견 또는 미해결 검색 행은 내부 도구 메모의 단일 `검색 시도 계약 receipt:` 라벨에 미발견 원본 번호 순서대로 receipt를 하나씩 기록해야 하며, 여러 항목은 ` || `로 구분한다. 각 receipt는 `artifact=<ProjectRoot-relative-json>; sha256=<64 hex>; case=<case>; expected=<candidate-recovery-pending|miss-closure-ready>` 형식이어야 하고, validator가 파일 경로·해시·case와 fixture packet의 `targetBinding.sourceProblemNumber`/`occurrenceKey`를 해당 미발견 번호와 Ordinal 1:1 대조한다. 미발견 번호가 N개면 receipt도 정확히 N개여야 하며 missing/extra/duplicate/wrong-target/reused-case는 거부한다. `완료`에 미발견이 없으면 `없음`을 쓴다. `candidate-recovery-pending`은 명시적 미해결 진단일 뿐 닫힌 miss 증거가 아니며, `miss-closure-ready`일 때만 miss 폐쇄를 허용한다. `검색 완료/0선택`은 모든 receipt가 `miss-closure-ready`인 경우에만 허용한다.
- 미실행·미해결 분리: 아직 검색하지 않은 원본 row에는 검색 receipt를 만들지 않는다. typed 세션 결과에 `not-started`와 실제 원본 identity를 남긴다. 검색한 row의 raw receipt는 보존한다. 내부 `ClosedMissedSourceNumbers`와 `UnresolvedSourceNumbers`를 구분한다. 공개 실패 수는 계속 원본 수에서 재로드 검증된 성공 수를 뺀 값이다.
- 출처 집계 규칙: 최종 persisted/reload 성공 카드의 raw visible `DB명`만 official 조직 family/root 또는 비-official `>` 앞 root(leading edition year 제거)로 정규화하고, 실패 문항은 제외한 뒤 빈도 내림차순·원본/편집 첫 등장 동률 순으로 top 3까지 receipt를 남긴다.
- 가능하면 ID/cell ID 기준으로 fresh exact target ordered ID bundle을 비교한다. ID가 UI/DOM에서 확인되지 않으면 card identity/source metadata/visual exact evidence를 함께 기록하되, count나 대표 ID만으로 완료를 증명하지 않는다.
- 상태 머신과 report contract의 target/selected/edit/persisted ID token은 앞뒤 공백·쉼표·CR/LF가 없고 exact `없음` 예약값이 아닌 canonical opaque string이어야 한다. 내부 TAB/NBSP·공백과 대소문자는 보존하며 Ordinal로 비교한다.
- 반복 source occurrence가 검증된 별도 duplicate/add control로 같은 DB problem ID를 두 번 보존하는 경우, 저장 전·후 ordered ID bundle과 함께 각 원본 위치의 고유 `occurrenceKey` bundle을 같은 순서로 기록한다. 중복 ID는 고유 key와 두 bundle의 순서·개수가 모두 일치할 때만 완료 증거다.
- ID를 확인할 수 없어 카드/시각 identity fallback을 쓰는 경우 증거는 반드시 `artifact=<path>; sha256=<64 hex>; identity=<구체 설명>` 형식으로 기록하며, artifact는 ProjectRoot 내부 상대 경로여야 하고 실제 파일이 존재하며 기록한 SHA-256과 일치해야 한다.
- save-equivalent는 visible/enabled button 또는 ARIA control일 때만 존재한다. hidden template text의 `확인`, `저장`, `완료`, `적용`은 저장 버튼으로 보지 않는다.
- persisted count가 draft/local count보다 낮으면 복구한다. 복구가 막히면 partial/blocker로 보고한다.

## 세션 근거 인덱스

- `mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_feature_exploration.md`: 2026-06-02 feature exploration. `검색하기`가 빈 scope에서도 약 `197,341` broad result를 반환할 수 있음을 확인했다. help/docs live tab 이동과 `전체 선택`, `문제지에 담기`, `변경하기` 같은 state-changing controls가 위험함을 기록한다.
- `mathsecr-paper-builder-kit/test-fixtures/docs/mathsecr_card_inventory_2000.json`: card ID, DB/source, type/unit metadata inventory 근거.
- `mathsecr-paper-builder-kit/test-fixtures/docs/gajwa2_candidate_summary.json`: source order, visible problem number, confidence를 분리해 target mapping에 쓰는 근거.
- `.omo/evidence/mathsecr_source_selector_exception_2026-06-05.md`: `교육청, 평가원` checkbox/label 직접 선택에 대한 2026-06-05 dated observation. 당시 `작업공간` 표현은 현재 version-aware `/mypaper/<id>` 실행 경로보다 우선하지 않는다.
- `.omo/evidence/mathsecr_restart_results_2026-06-05.md`: 재시작 결과 패킷 4건. preflight exact mismatch, previous ID distrust, `다음 단계` collapse, edit-modal source reset 근거.
- `.omo/evidence/mathsecr_mission_first_review_2026-06-05.md`: early success/recent failure 비교. partial completion, bounded whole-DB retry, recovery-before-stop 근거.
- `.omo/evidence/mathsecr_search_momentum_review_2026-06-05.md`: `019e9614-4e95-78b0-abc4-7f9c98af922a`, `019e9618-5449-74f2-85f3-ce9b56fe78a9`의 search momentum 실패 근거.
- `.omo/evidence/mathsecr_state_contamination_2026-06-05.md`: same-URL stale persisted IDs contamination 근거.
- `.omo/evidence/mathsecr_new_paper_adaptive_search_policy_2026-06-05.md`: source-order adaptive 2-chip search, 100-result refinement, whole-DB retry, similar ban 근거.
- `.omo/evidence/mathsecr_scheduled_retry_results_2026-06-05.md`: 0-selection status ambiguity 근거. selected 0은 paper-build 완료가 아니다.
- `.omo/evidence/mathsecr_minimal_failure_rules_2026-06-06.md`: 초기 성공 루프와 clean-state, scope/search, per-problem mismatch, persistence, 0-selection, iab-unavailable gates 통합 근거.
- `.omo/evidence/mathsecr_body_only_exact_policy_2026-06-07.md`: 객관식 선지는 exact 판정에서 제외하고 문제 본문/조건/도형/수식 기준으로 body-exact를 선택하는 사용자 정책 근거.
- `.omo/evidence/mathsecr_search_regression_recovery_policy_2026-06-07.md`: 고국2 프린트2 11/18 회귀 분석 근거. Text search miss 이후 same-source candidate recovery와 `다음 단계` 전 검색 완료 gate를 승격했다.
- `.omo/evidence/mathsecr_formula_search_feature_test_2026-06-08.md`: typed formula chip 생성, text+formula 결합, generic formula cardinality와 stale count 관찰 근거. 결과 수는 scope/index 상태에 따라 달라지는 관찰값이며 고정 계약이 아니다.
- `.omo/evidence/mathsecr_search_feature_live_verification_2026-07-29.md`: 해시 검증되는 DOM trace를 포함한 공식 도움말/iab 라이브 검증 근거. 범위가 확인된 텍스트 2칩 검색 27건, 세 번째 칩 추가 전 stale 27건/재검색 후 6건, 수식 칩 결합 0건, 수식 제거 후 재검색 6건 복구를 기록한다.
- `.omo/evidence/mathsecr_db_inference_search_test_2026-07-29.md`: DB 미지정 PDF의 printed metadata clustering, read-only blank probe, query-chip receipt, fresh-result signature, selector reset, mixed-source inference 근거. 대진2/주엽1 각 6문항의 blank-versus-inferred scope 행렬과 MiKTeX 재추출을 기록한다.
- `.omo/evidence/mathsecr_pdf_segmentation_corpus_2026-07-31.md`: 대진2/주엽1 실제 PDF의 문제 페이지 렌더 해시, 인쇄 번호 기준 2단 편집 순서, 도형 포함 문제, 공통 지문/페이지 걸침 부재를 고정 코퍼스로 검증한 근거.
- `.omo/evidence/mathsecr_selection_journal_resume_2026-07-31.md`: source occurrence와 DB problem ID를 분리한 append-only 선택 저널, bounded retry, late ACK, crash/resume, idempotent append 및 손상 tail 거부 근거. live MathSecr 이벤트 계약을 주장하지 않는 offline adapter다.
- `.omo/evidence/mathsecr_external_handoff_gap_fill_2026-07-31.md`: 외부 964회 검색 characterization의 정책 충돌·증거 한계 교차검토와 iab phrase-vs-split 2쌍, 3-snapshot 비용, 기존 41문항 실물 PDF 근거, 남은 regression 공백을 기록한다.
- `.omo/evidence/mathsecr_idle_search_characterization_2026-07-31.md`: 한 authenticated iab session의 서로 다른 준비된 탭 3개에서 각 1회씩 15/30/60분 유휴 후 동일 signature 2회를 관찰하고, 동일 카드 2회 활성화가 duplicate insert가 아니라 선택 해제로 끝난 dated 근거. 회귀는 frozen JSON만 검증하며 live wait, availability/latency/result-count, standard fresh receipt, exact/miss를 주장하지 않는다.
- `.omo/evidence/mathsecr_metadata_rescue_gap_2026-08-15.md`: partial lazy-result traversal과 불완전 metadata rescue로 miss를 닫는 false-green 위험 근거.
- `.omo/evidence/mathsecr_semantic_and_false_negative_2026-08-26.md`: semantic AND 칩이 exact 후보를 처음부터 배제한 false-negative와 literal-only backoff 회귀 근거.
- `.omo/evidence/mathsecr_sentence_chip_drift_2026-08-31.md`: 문장형·공백 제거 구절이 단어 2칩 proof ladder로 통과한 반복 drift와 lexical boundary, phrase-prepass 투영 회귀의 offline-contract 근거.
- `.omo/evidence/mathsecr_report_receipt_binding_2026-08-26.md`: miss receipt를 원본 번호와 occurrence에 1:1로 결합하는 report gate 근거.
- `.omo/evidence/mathsecr_session_019ecab8_learning_review.md`: 24/24 성공 세션의 bounded inventory 전술과 rule 비승격 판단 근거.
- `.omo/evidence/mathsecr_re0_memo_2026-08-27.md`: 반복 사고를 pattern family로 일반화하고 `gated`/`record-only` 경계를 registry와 validator에 연결한 memo.
- `.omo/evidence/mathsecr_mandela_ground_truth_2026-08-27.md`: body-exact self-confirmation false-green을 재현하고 평가별 oracle gap, claim boundary, 독립성 gate를 고정한 postmortem.
- `.omo/evidence/mathsecr_recent_two_week_learning_expansion_2026-08-27.md`: 2026-08-13~27의 프로젝트 연관 rollout 74개를 재분류하고 SSOT drift, durable lesson, source-anomaly receipt, current-input regression receipt로 확장한 통합 근거. Dated log characterization과 offline contract만 주장한다.
- `.omo/evidence/mathsecr_source_anomaly_gate_2026-08-27.md`: source/candidate image bytes, target/occurrence, inspected candidate를 결박하고 unresolved anomaly의 edit/report/0-selection 전이를 차단하는 offline-contract 회귀 근거. Body exact/mismatch나 live product truth는 주장하지 않는다.

새 lesson 승격 전에는 이 인덱스와 최신 내부 `MathSecr 세션 보고서`를 확인한다.

## Read-Only Support

- PDF inventory, clue mining, search-token suggestion, DOM/API discovery, final audit에는 subagent를 사용할 수 있다.
- subagent는 live MathSecr page를 클릭하지 않는다.
- PDF가 4페이지 초과이면 4페이지 단위 read-only batch로 나눈다.
- answer/solution pages가 분리되어 있으면 problem pages만 inventory한다. 아니면 전체를 읽고 non-problem pages를 표시한다.
- Reader output은 한국어이며 `순서`, `PDF 페이지`, `보이는 문제번호`, `출처/메타데이터`, `단서어`, `수식/도형 단서`, `신뢰도`, `메인 에이전트 검증 필요`를 포함한다.
- LaTeX skill은 OCR이 아니다. 전사 후 렌더/컴파일/TeX 검증에만 쓴다.

## Session Learning Loop

완료/중단 세션의 내부 검증 패킷을 받으면:

1. lesson을 `Failure`, `Efficient`, `Search`, `Tooling`, `Policy`로 분류한다.
2. AGENTS 대상 lesson과 SKILL 대상 lesson을 나눈다.
3. 사례 표현은 shared pattern family와 named anti-pattern으로 일반화하고 원본 사례는 evidence에 보존한다.
4. `high`/`repeated` failure는 memo registry의 `gated` record로 만들고 evidence, negative corpus, validator, 전체 runner label을 연결한다. 독립 실패 신호가 없는 관찰은 `record-only`와 gate blocker를 기록한다.
5. 중복 규칙은 합치고 one-off 로그는 evidence에 남긴다.
6. 정책 파일을 변경했으면 공식 installer로 root `AGENTS.md`, kit `AGENTS.md`, installed/kit `SKILL.md`를 동기화하고 `SyncContract`를 확인한다.
7. 새 평가/evidence가 현실 정답을 주장하면 `test_ground_truth_contract.ps1`로 독립 oracle 면과 claim boundary를 확인한다.
8. 계약·registry·fixture·installer 또는 실행 코드를 변경했으면 관련 검증과 `test_re0_memo.ps1`, 전체 validator로 linkage와 marker 계약을 확인한다. 변경 없는 단순 문제지 제작은 해당 실행의 검색·선택·저장·보고 검증으로 마무리하고, record-only 후기만 추가했으면 문서·링크 검사만 한다. 통과한 검사는 추가 변경·실패·미해결 우려가 없으면 확대하거나 반복하지 않는다.

## Required Session Records and User Output

모든 MathSecr worker/session은 아래 상세 `MathSecr 세션 보고서`를 내부 검증 패킷으로 유지한다. 패킷은 Codex의 검증·handoff·evidence용이며 문제지 제작 결과 응답에 결합하지 않는다. 사용자가 내부 진단 패킷 자체를 요청한 별도 질의에만 별도 응답 또는 artifact로 제공한다. 빈 내부 필드는 `없음`으로 쓴다.

사용자 표시 최종 응답은 아래 0–4 항목만 출력한다. 제작한 문제지 링크와 실패 이미지 크롭 보고서 PDF 링크는 공개하되, 필터, 도구 메모, 체크포인트, 위험 단계, 내부 상태명과 그 밖의 URL은 상세 내부 패킷에만 남긴다.

이 형식은 정상 제작 결과에 적용한다. `ASIDE_OFF_USER_RESPONSE`의 실제 브라우저 종료 응답은 고정 문구 한 줄을 우선한다.

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

- 성공 문제 수는 최종 persisted/reload 검증된 exact 원본 문제 수이며, 실패 문제 수는 전체 문제 수에서 성공 문제 수를 뺀 값이다. 분모는 원본 문제 수로 고정하고 `S문제/T문제`, `F문제/T문제` 표기를 그대로 사용한다. 공개 형식에는 `#`와 `@`를 쓰지 않는다.
- 실패 번호는 원본 문제 번호를 한 줄의 쉼표 목록으로 묶는다(예: `6번, 8번, 9번`). 실패가 0이면 중첩 줄에 `없음`만 쓴다.
- 일반적인 문제별 실패가 하나라도 있으면 실패 번호에 대응하는 실제 PDF 크롭 보고서 링크를 반드시 제공한다. 실패가 0이면 PDF 줄은 `- 없음`으로 쓴다.
- 문제 번호를 만들 수 없는 전체 세션 blocker는 `전체 세션 — 차단`을 실패 번호 줄에 쓰며, 이 예외에서는 PDF를 `- 없음`으로 둘 수 있다.
- 4번 출처는 최종 persisted/reload 검증된 성공 카드의 visible `DB명`에서만 집계한다. official DB는 visible 조직 이름(`교육청`, `평가원` 등)을 각각의 family/root로 정규화하고, 그 외 DB는 `>` 앞 root에서 leading edition year를 제거해 정규화한다. 실패 문항은 제외한다.
- 출처는 빈도 내림차순, 동률은 원본/편집 첫 등장 순서로 최대 3개만 중첩 순위로 쓴다. 서로 다른 출처가 1–2개면 존재하는 만큼만 쓰고, 성공 문제가 0개면 `1. 없음`만 쓴다.
- 사용자 표시 초안은 `Invoke-MathSecrUserSummaryLint`를 통과해야 한다. 위 0–4 항목 외 heading/본문, `#`/`@`가 붙은 성공·실패 표기, 허용되지 않은 링크·번호·설명문은 거부한다.

내부 `최종 상태`는 `완료`, `부분 완료`, `검색 완료/0선택`, `차단` 중 하나다. `완료`는 모든 목표 문제가 persisted/reload 검증된 경우만 쓴다. 아래 템플릿은 내부 기록 전용이다.

```markdown
## MathSecr 세션 보고서

세션 ID:
문제지 URL:
원본 파일:
목표:
최종 상태:
사용자 지정 최초 DB/출처 범위:
사용자 지정 최초 단원/유형 범위:
사용한 브라우저 표면:
비-Aside REPL live 조작 발생: 예/아니오
비-Aside REPL 조작 발생 시 최종 상태: 차단

### 개수
- 원본 문제 수:
- 선택한 문제 수:
- 저장 전 초안/로컬 선택 수:
- 저장 후 재로드/새 탭 확인 수:
- 최종 편집 화면 도달: 예/아니오
- 저장/확인 컨트롤 클릭: 예/아니오/없음
- 새로고침 또는 새 탭 검증: 예/아니오
- API/route/help/docs를 live tab에서 열었는지: 예/아니오
- `출제하기` 클릭: 예/아니오

### 프린트별 미발견 문제
- 프린트/원본 파일:
  미발견 문제 번호:
  시도한 검색/근거:

### 최초 범위 밖에서 선택한 exact 문제
- 원본 문제 번호:
  선택한 문제 ID/cell ID:
  선택한 DB/출처:
  벗어난 최초 범위:
  exact 근거:

### 대체 또는 유사 문제
- 원본 문제 번호:
  대체 문제 ID/cell ID:
  대체 문제 DB/출처:
  유사하다고 본 근거:
  사용자 승인: 명시/명시 세션 정책/승인 없음

### 실패 또는 위험 단계
- 증상:
  원인:
  복구:
  남은 blocker:

### 효율적이었던 단계
- 전술:
  효과:
  재사용 조건:

### 검색 메모
- 잘 된 것:
- 안 된 것:
- 수식/검색어 정규화:

### 도구 메모
- 브라우저 표면 및 비-Aside REPL 조작 여부:
- 컨트롤 맵 갱신:
- 결과 inventory/preflight 사용:
- 저장 전 순서화된 target ID 목록:
- 저장 후 재로드 target ID 목록:
- 저장 전 순서화된 occurrenceKey 목록:
- 저장 후 재로드 occurrenceKey 목록:
- 카드/시각 identity fallback 근거:
- 검색 시도 계약 receipt:
- 최종 persisted 카드 출처 집계:
  raw visible DB명:
  정규화 source family/root:
  count/top3 receipt:
- live tab 이동 사고:
- 체크포인트 데이터:

### 남은 항목
- 미발견 문제:
- 범위 밖 exact:
- 대체/유사 후보:
- 사용자 결정 필요:
```
