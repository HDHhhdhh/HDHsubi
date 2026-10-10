# MathSecr Success Algorithm

이 문서는 `AGENTS.md`와 `mathsecr-paper-builder/SKILL.md`의 실행 규칙을 상태 머신으로 풀어 쓴다. 새 정책이 아니라, 기존 정책을 테스트 가능한 의사결정표로 만든 것이다.

<!-- SEARCH_ATTEMPT_SSOT_REF --> 검색 시도의 사람용 절차는 kit `skills/mathsecr-paper-builder/SKILL.md`의 [Search Attempt Contract](../skills/mathsecr-paper-builder/SKILL.md#search-attempt-contract), packet 판정은 [`Test-MathSecrSearchAttemptContract`](../scripts/search_attempt_contract.ps1)가 각각 소유한다. 이 문서는 그 derived status를 상태 전이에 연결할 뿐 provenance·ladder·backoff·miss closure를 재정의하지 않는다.

<!-- DB_INFERENCE_SSOT_REF --> DB/source 추론과 current official-collection scope-lock의 사람용 절차는 kit SKILL의 [DB Inference And Official Collection Contract](../skills/mathsecr-paper-builder/SKILL.md#db-inference-and-official-collection-contract), schema와 판정은 [DB inference specification](db_inference_contract.md) 및 [`Invoke-MathSecrDbInference`](../scripts/db_inference.ps1)가 소유한다. 이 문서는 resolver verdict를 상태 전이에 연결할 뿐 추론·selector 절차를 재정의하지 않는다.

<!-- METADATA_RESCUE_SSOT_REF --> Metadata rescue와 lazy coverage의 사람용 절차는 kit SKILL의 [Metadata Rescue And Lazy Coverage Contract](../skills/mathsecr-paper-builder/SKILL.md#metadata-rescue-and-lazy-coverage-contract), receipt 재계산은 [`Test-MathSecrMetadataRescueReceipt`](../scripts/state_machine.ps1)가 소유한다. 이 문서는 derived receipt 상태만 전이에 연결한다.

<!-- BODY_EXACT_SSOT_REF --> Live candidate 선택의 사람용 기준은 kit SKILL의 [Body-Exact Selection Contract](../skills/mathsecr-paper-builder/SKILL.md#body-exact-selection-contract)가 소유한다. 이 문서는 verdict의 row/whole-paper 전이만 표현하며, 아래 dated evaluation은 live match 절차를 재정의하지 않는다.

## Phase And Partial Save Contract

`Invoke-MathSecrStateMachine -Phase BeforeNext`는 현재 선택 묶음을 검사한다. 선택된 모든 원본 문항의 검색과 본문 receipt를 미해결 행의 조기 반환보다 먼저 검증한다. `nextClicked=false`가 필요하다. 아직 발생하지 않은 편집·저장·재로드 근거는 요구하지 않는다. 입력에 `edit`와 `persistence`를 생략할 수 있다. 입력에 있다면 빈 ID 배열과 미실행 상태만 허용한다. 통과 결과는 `PRE_NEXT_GATE/ready-for-next`, `CanNextStep=true`다. 실제 UI 동작은 이 판정 후 primary가 실행한다.

`-Phase AfterReload`는 기본값이다. 실제 `nextClicked=true`, 편집 카드, 재로드 카드의 전체 ID·순서를 비교한다. 반복 ID에는 각 원본 위치의 occurrence key와 duplicate/add control receipt가 필요하다. `BeforeNext`는 현재 선택 occurrence bundle만 검사한다. `AfterReload`는 선택·편집·저장 bundle 모두를 검사한다. 검사기는 snapshot이나 receipt를 생성·변경하지 않는다.

`requestedAction="partial-save"`가 명시되고 검증된 선택이 1개 이상이면 선택된 원본 문항만 편집·저장할 수 있다. 나머지는 `not-started`, 검색 pending, 유효한 source anomaly, miss closure 부족 상태로 유지한다. 잘못된 선택 receipt, scope·문제지 identity failure, stale ID, 손상된 선택·저장 묶음, 잘못된 target binding은 이 예외를 통과하지 못한다. Source anomaly 자체와 그 근거의 무결성 실패를 구분한다. 전자는 미해결 행이다. 후자는 검증 실패다.

미실행 또는 정상 불완전 작업은 미해결로 남기며 검증된 subset을 저장할 수 있다. 이미 제출한 receipt의 schema, 원본·occurrence 결박, 실제 artifact hash가 잘못되면 먼저 기록을 복구하도록 전체 전이를 차단한다. 부분 저장은 기존 metadata-rescue receipt 검증을 완화하지 않는다. `Test-MathSecrTargetRowState`는 상태 필드를 strict string·Ordinal enum으로 검사한다. 미선택 행의 `selectedId`는 absent, null, 빈 문자열만 허용한다. 그 밖의 값은 선택 주장으로 보고 거부한다. 후보 힌트는 `selectedId`와 분리한다.

결과는 검증된 `SelectedSourceNumbers`, closure를 통과한 `ClosedMissedSourceNumbers`, 나머지 `UnresolvedSourceNumbers`와 `UnresolvedReasons`를 원본 순서로 반환한다. 사유에는 `SourceProblemNumber`, `OccurrenceKey`, `Reason`이 있다. 미해결을 미발견으로 승격하지 않는다. 선택이 0개이면 모든 행의 miss closure가 검증된 경우에만 기존 `검색 완료/0선택`을 허용한다.

이번 `BeforeNext` phase는 최초 검색에서 편집으로 들어가는 경로를 지원한다. 부분 저장 후 기존 카드가 있는 편집 화면에서 추가 검색하는 재진입은 별도의 현재 배치 관측 계약이 필요하다. 그 입력은 `before-next-edit-reentry-unsupported`로 거부한다.

## State Table

| State | Inputs | Entry Checks | Allowed Actions | Exit Evidence | Failure Output |
| --- | --- | --- | --- | --- | --- |
| `PREPARE` | paper URL, source PDF/HWPX or rendered fixture, optional initial scope screenshot/text | root `AGENTS.md` and installed `SKILL.md` reread; source order table and metadata clusters exist | build source-order target table; extract source/year/organization/course/exam metadata; classify fixtures as original or synthetic | target count, source path, metadata clusters, scope notes, fixture provenance | `차단` if source list/file is missing |
| `ASIDE_REPL_READY` | Aside REPL browser surface, paper URL or local simulator URL | Aside REPL available and attached to the intended tab; no login redirect for live read-only check; simulator URL confirmed for tests | list existing tabs, attach the relevant tab, inspect URL/title/login with `snapshot()`; use local simulator for mutating practice | URL/title/auth state, browser surface, non-Aside-REPL flag | `차단` if Aside REPL is unavailable or the live paper cannot be attached and verified |
| `CLEAN_STATE` | current paper/edit state, prior persisted IDs if any | same URL restart has no stale IDs, or stale IDs are cleared only with official visible controls and reload verification | inspect existing edit/persisted count; choose new blank paper or stop when not clean | clean count/order or explicit stale-ID blocker | `차단` if clean state cannot be proven |
| `DB_INFERENCE` | direct `Invoke-MathSecrDbInference` output when DB/source was unspecified | output has nonempty per-cluster results; every inferred row has exactly one canonical scope and nested phase payloads; aggregate flags agree with row payloads | no selection action; keep `pending`/well-formed incomplete receipts recoverable; re-collect evidence or receipts | direct resolver output with `Status`, row reasons, canonical scopes, and phase-bound receipts | `pending`/`unresolved` or malformed/forged payload blocks `select_cards`, `select_all`, and `next_step` |
| `SCOPE_LOCK` | explicit scope or per-cluster inferred candidate | explicit identity is verified or DB resolver verdict is `inferred`; canonical scope-lock receipt is valid under the DB inference SSOT | perform only the scope-lock action owned by the DB inference SSOT | resolver status/reason and canonical scope-lock receipt | `pending`/`unresolved`, malformed receipt, or identity mismatch blocks selection |
| `INITIAL_SEARCH` | source row, locked scope, search-attempt packet | packet follows the SKILL `Search Attempt Contract`; executable contract is called without copied aggregate claims | perform only the human procedures owned by the search and body-exact SSOT sections | canonical search output plus body verdict and selected identity when status is `exact-found` | `candidate-recovery-pending` routes to recovery; malformed/stale search evidence or unresolved body verdict stays blocked |
| `CANDIDATE_RECOVERY` | canonical search output, same-source metadata, prior same-source candidate maps | status is not miss-closure-ready; candidate IDs are hints only | complete the contract-owned recovery routes and coverage, then recompute the same packet | `exact-found`, `miss-closure-ready`, or `candidate-recovery-pending` from the canonical function | never promote pending to missed locally |
| `METADATA_RESCUE` | candidate-recovery row for which the state machine requires rescue | raw receipt is target-bound and the canonical human procedure was used | pass the raw receipt to `Test-MathSecrMetadataRescueReceipt`; do not reconstruct its claims locally | exact body verdict, state-machine-derived complete-coverage verdict, or artifact-bound unresolved anomaly observation | `metadata-rescue-required`, `metadata-rescue-receipt-invalid`, incomplete coverage, or valid-but-unresolved `source-anomaly-pending` remains pending/blocked |
| `WHOLE_DB_RETRY` | metadata-rescue-complete initial-scope rows, or pending rows without usable printed metadata | whole DB has visible/selected UI evidence; a new whole-db contract scope is recorded | execute the SKILL procedure and recompute the canonical packet | `exact-found`, `miss-closure-ready`, or `candidate-recovery-pending`; out-of-initial exact is separately recorded | only `miss-closure-ready` becomes final missed; similar/replacement is not exact and `source_anomaly` remains pending |
| `PRE_NEXT_GATE` | ordered selected IDs, closed missed/unresolved rows, requested action, phase | every selected row has validated search/body evidence; normally every other row is final missed; explicit partial-save permits unresolved rows outside the selected bundle | record risky-action snapshot; click `다음 단계` only when `BeforeNext` returns `CanNextStep=true` | ordered selected target ID bundle, closed misses, unresolved reasons, intended click | scope/identity/binding/bundle failure blocks; zero selection with unresolved rows cannot complete |
| `EDIT_VERIFY` | edit-screen cards, draft/local IDs | edit IDs match fresh selected bundle; no old IDs appear | repair order with visible controls; avoid `번호순 정렬` unless verified | draft/local count and ordered IDs; orderMatchesExpected | recovery-required or `차단` on collapse/stale IDs |
| `PERSIST_VERIFY` | save-equivalent state, reload/fresh tab | visible enabled save/confirm exists or is recorded absent; `출제하기` is not clicked | click visible save-equivalent if present; reload/fresh-tab verify | persisted count/order equals fresh exact target ordered ID bundle | `부분 완료` or `차단`; never completion on count-only proof |
| `REPORT` | final verification packet | final status is one of `완료`, `부분 완료`, `검색 완료/0선택`, `차단` | write and lint the full Korean `MathSecr 세션 보고서` as an internal packet; render and lint the closed 0–4 user projection (paper link, `S문제/T문제`, `F문제/T문제` plus failed-number list, crop-report PDF link, normalized source ranking) with `Invoke-MathSecrUserSummaryLint` | internal report with counts, IDs/order, misses, out-of-scope, replacements, browser surface, accidents, `출제하기` status; public projection exposes only the paper/PDF links, required counts/numbers, and up to three source rows | report or user-summary lint failure until corrected |

## Transition Table

| Trigger | Required Decision | Next State Or Output |
| --- | --- | --- |
| Source file/list missing | Stop before browser work | `차단` |
| iab unavailable or live paper unverified | Do not switch to Chrome or Computer Use in the same session | `차단` |
| A prepared live tab has been idle before its first search | Do not reload solely because time elapsed; re-check login plus source/query removal receipts and then apply the ordinary post-submit freshness gate | continue from `ASIDE_REPL_READY`, or reload/reopen recovery only when a receipt/login/freshness check fails |
| Same-URL restart has stale IDs | Clear only with visible official controls and reload count 0, use new blank paper, or stop | `CLEAN_STATE` retry or `차단` |
| Direct DB inference output is pending/unresolved, empty, or forged | Do not trust `scope.verified` or aggregate Booleans as a bypass; validate every nested row and phase payload | `DB_INFERENCE` recovery or block |
| Source scope empty or huge broad result appears unexpectedly | Treat as scope failure; do not select cards, `전체 선택`, or `다음 단계` | `SCOPE_LOCK` recovery |
| DB/source is unspecified | Follow the DB inference SSOT and consume only the resolver's direct verdict and receipts | `inferred` proceeds to `SCOPE_LOCK`; `pending`/`unresolved` remains recovery or blocker |
| Official collection scope is needed | Follow the current route in the DB inference SSOT; dated route wording is not an action | valid receipt proceeds from `SCOPE_LOCK` |
| Candidate is returned for exact verification | Follow the body-exact SSOT and retain its inspected/selected identity with the verdict | exact proceeds to selection; candidate mismatch routes that row to recovery; proven source-paper identity mismatch blocks the paper |
| A search-attempt packet is ready for transition | Call `Test-MathSecrSearchAttemptContract`; consume its `Status`, `Errors`, `ScopeLadders`, and derived IDs without locally reinterpreting provenance, common chips, ladders, backoff, recovery, or coverage | `exact-found` continues selection, `miss-closure-ready` may close the row, `candidate-recovery-pending` remains in recovery/blocker |
| State machine requires metadata rescue | Follow the metadata-rescue SSOT and submit its raw target-bound receipt for canonical recomputation | enter or repeat `METADATA_RESCUE` |
| Metadata rescue receipt is incomplete or invalid | Do not infer completion from budget, visible subset, or a copied Boolean | remain `METADATA_RESCUE`; final miss blocked |
| Metadata rescue yields exact or derived complete coverage | Apply the body verdict when exact; otherwise carry the canonical coverage verdict without restating its procedure | selection or eligible `WHOLE_DB_RETRY` |
| Body-exact verdict reports an unresolved low-confidence glyph conflict | Preserve the canonical body verdict and submit its artifact-bound observation receipt for state-machine recomputation | `METADATA_RESCUE/source-anomaly-pending`; explicit partial-save may advance a separately validated selected subset; anomaly row cannot be selected or closed as missed |
| Two source positions resolve to the same DB problem ID | Keep distinct canonical `occurrenceKey` values with no leading/trailing whitespace, comma, CR/LF, or exact `없음` sentinel; the dated same-card probe selected once and then cleared that selection on second activation, so re-click is not a duplicate mechanism | the state-machine accepts the repeated ID only with per-target keys, a typed visible duplicate/add-control receipt, `OrderedBundleVerified=true`, and selected/edit/persisted occurrence-key arrays equal to selected source order; otherwise block the later occurrence |
| Source-paper identity mismatch proven | Stop the whole paper | `차단` |
| Initial scope miss after candidate recovery has no usable printed source/subject/year, or its required metadata rescue completed without exact | Retry only that missed row in verified `전체 DB` | `WHOLE_DB_RETRY` |
| Whole DB finds exact outside initial range | Select exact and record out-of-scope source | `PRE_NEXT_GATE` when all rows resolved |
| Whole DB closes every source row as `miss-closure-ready` and selected count is 0 | Do not click `다음 단계`; require one target-bound report receipt per row | `검색 완료/0선택` |
| Some exacts selected and some final misses remain | Preserve selected exacts and report misses after persistence | `부분 완료` |
| Explicit partial-save with validated selected rows and unresolved rows | Validate selected evidence first; preserve unresolved rows and raw receipts; compare only the selected subset through edit/reload | `BeforeNext/ready-for-next`, then `AfterReload/부분 완료`; never close unresolved rows as missed |
| `다음 단계` loses fresh IDs or old IDs appear | Treat as selected-bundle collapse, not partial completion | recover edit/search or `차단` |
| Draft/local and persisted ordered IDs match all source rows | All target problems verified | `완료` |
| Prompt or report uses stale zero-selection label | Validator/report linter failure | fix prompt/report before completion |

## Failure Class Mapping

| Failure Class | Detect With | Algorithm Guard |
| --- | --- | --- |
| Search-attempt false closure | canonical function returns `candidate-recovery-pending` or `exact-found`, but a caller claims missed | consume the canonical status and error list; state/report integration may not reconstruct or override the search rules |
| Incomplete lazy-result traversal | canonical metadata receipt is not complete | `METADATA_RESCUE` cannot transition to missed; follow the metadata-rescue SSOT |
| Transcription-conflict overconfidence | body-exact verdict remains unresolved | keep `source_anomaly`/pending with recomputable artifact/target/candidate binding; explicit partial-save excludes that row from the saved subset and preserves its unresolved diagnosis; metadata alone cannot override the verdict |
| Same-source previous candidate map misuse | previous IDs used as a selection verdict | prior IDs remain hints; follow the body-exact SSOT |
| Same-URL state contamination | stale persisted IDs present before or after `다음 단계` | `CLEAN_STATE`, `EDIT_VERIFY`, and `PERSIST_VERIFY` bundle equality |
| Selected-bundle collapse | selected count/order before next differs from draft/edit/persisted IDs | no completion; recover or `차단` |
| 0-selection status ambiguity | selected count 0 after retry budget | `검색 완료/0선택` only when every row independently recomputes to `miss-closure-ready`; any pending/anomaly remains blocked |
| Source selector false evidence | presented scope-lock receipt is rejected by the DB resolver/spec | follow the DB inference SSOT current route; do not substitute dated wording or navigation state |
| DB inference overreach | direct resolver verdict is `pending`/`unresolved` or its receipt validation fails | recover evidence under the DB inference SSOT; never override with aggregate claims |
| Repeated-source occurrence collapse | two printed positions are merged because they share one DB ID, or the same result card is clicked twice | stable canonical occurrence key per source position (no leading/trailing whitespace, comma, CR/LF, or exact `없음` sentinel; internal whitespace/case preserved); selectedCount>0 allows either all three bundles absent/empty or all three exact; journal intent separately; never use re-click as duplicate insertion; require `occurrenceProof.DuplicateAddControlVerified=true`, `DuplicateAddControlKind=duplicate/add`, a nonblank control receipt, `OrderedBundleVerified=true`, and exact selected/edit/persisted occurrence-key bundles |
| Unsafe target/selected ID token | ID has edge whitespace, comma, CR/LF, exact `없음`, or mismatched case/ordinal semantics | reject target `selectedId` and every selected/edit/persisted ID array token; preserve internal TAB/NBSP/case and compare with Ordinal; report parser trims comma formatting but rejects list-item `없음` and embedded CR/LF |
| Idle-time reload overreach | a long-open tab is reloaded without checking its current login/scope/query receipts | elapsed time alone is not a recovery trigger; keep the normal freshness gate and recover only on failed evidence |
| iab unavailable | iab crash/unverified live paper | `차단`, no Chrome/Computer Use fallback |
| Prompt drift | forbidden weakened wording in `.omo/prompts` | PromptDrift validator |
| Misleading final proof | count-only or representative ID only | fresh exact target ordered ID bundle equality |

## Offline Evidence Boundaries

### Repeated Source Occurrence State-Machine Contract

`scripts/state_machine.ps1` keeps the ordinary unique-ID path unchanged but has an explicit, conservative escape hatch for two printed source positions that resolve to one DB `problemId`. An `occurrenceKey` is a report-safe canonical opaque string: it must be nonblank with no leading or trailing whitespace, comma, or CR/LF, and it cannot equal the exact report sentinel `없음`; internal whitespace (including TAB/NBSP) and case are preserved verbatim. For selectedCount>0, target keys and every selected/edit/persisted occurrence-key bundle are either all absent/empty or all strict canonical arrays matching selected target order/count; partial or ghost bundles block. A same-card re-click is never sufficient: the snapshot must carry an `occurrenceProof` object with strict boolean `DuplicateAddControlVerified=true`, exact `DuplicateAddControlKind=duplicate/add`, a nonblank `DuplicateAddControlReceipt`, and strict boolean `OrderedBundleVerified=true`.

At `AfterReload`, the proof is complete only when `selectionBeforeNextOccurrenceKeys`, `edit.draftOccurrenceKeys`, and `persistence.occurrenceKeys` are arrays of distinct canonical keys in exactly the selected source-target order (missed and unresolved rows are not included). `BeforeNext` validates the selected array and typed control receipt without inventing edit or persisted arrays. For zero selection, all three occurrence arrays must be absent/empty; a nonempty ghost blocks at `PRE_NEXT_GATE`. The corresponding selected/edit/persisted ID arrays may contain the repeated DB ID, but their order and count must still match the selected target rows. Missing keys, leading/trailing-whitespace/comma/CR/LF/sentinel keys, malformed receipts, stale/reordered occurrence bundles, or duplicate keys block at `INITIAL_SEARCH`/the relevant verification gate; the state machine never collapses a repeated source occurrence into one ID. Report-text comma lists may trim formatting whitespace around each token before duplicate comparison, while internal whitespace and case remain opaque. ID duplicate detection is ordinal and codepoint-preserving: composed/decomposed or case-distinct tokens remain distinct, while genuinely identical tokens still require occurrence proof. This is an offline snapshot contract and does not claim that the live service exposes such a control without a visible receipt.

### Idle First-Query Characterization

`test-fixtures/search-characterization/idle-first-query-2026-07-31.json` is one dated, frozen observation from three distinct prepared tabs sharing one authenticated IAB session. Each tab submitted its first and only query after its own 15/30/60-minute prepared timestamp. The offline regression validates the stored timestamps, exact source/query removal receipts, two repeated result signatures, zero idle selection actions, and the separate same-card toggle-off probe.

- The regression does not wait 15/30/60 minutes or contact MathSecr.
- Two repeated signatures after setting source/query criteria are not promoted to the standard fresh-search receipt when the ordinary rule calls for a third read.
- The fixture does not prove availability, latency, stable result count, exact/miss correctness, or independent authenticated sessions.
- The reusable rule is only that elapsed idle time is not itself a reason to reload; actual work still requires current login, receipt, and freshness evidence.
- The separate same-card probe observed one selection followed by selection clearing on second activation. It is not a service-wide toggle contract; it proves only that re-click is not a verified duplicate-insertion mechanism.

### Year Range Serializer Guard And Local Adapter

`test-fixtures/year-range-serialization/bundle-observation.json` is a **pinned serializer-guard observation**. It records the observed MathSecr bundle URL, capture timestamp with timezone, byte length, SHA-256, source fragment, and the field names `sourceStartYear` and `sourceEndYear`.

- The product observation is scoped to an assumed already-normalized two-element numeric tuple. Under that assumption, the captured guard checks tuple length 2, both values non-`undefined`, and `start <= end` before assigning the two fields.
- The captured fragment does not pin or prove MathSecr's upstream normalization. It is not evidence that raw strings, blank values, `null`, partial input, `NaN`, or `Infinity` are rejected by MathSecr.
- When the retained observed bundle is supplied with `-BundlePath`, PASS additionally proves that its byte length, SHA-256, and literal guard match the pinned observation. It still does not extend the claim to upstream parsing or current live behavior.
- `year_range_serialization.ps1` is a **conservative local CLI adapter**. Its complete/numeric/finite/non-reversed checks and empty-payload behavior are local tooling policy only, tested by `cases.json`; they are not attributed to MathSecr.

### Body-Exact Corpus Consistency Evaluation

The body-exact corpus contains 23 ordered source records, but only seven records have the committed evidence chain required for scoring. Sixteen records are quarantined and remain useful only for blind-run diagnostics.

- Fresh/stale authority comes directly from the normalized-LF hashed session evidence files `mathsecr_state_contamination_2026-06-05.md` and `mathsecr_search_regression_recovery_policy_2026-06-07.md`, not from the newly derived observations/evidence sheet alone.
- The verifier parses the seven fresh IDs, ordered 18-row prior map, four collapsed persisted IDs, explicit stale line, and `62005` survivor marker. It derives negatives as persisted minus fresh: `221076`, `287145`, and `991190`.
- A scoreable record additionally requires a hashed source fixture row with blind clues and a matching candidate inventory entry with at least two metadata tokens. Six fresh IDs retain prior-map row positions; row 11 explicitly supersedes prior hint `1419412` with fresh ID `1419409`.
- Previous candidate-map IDs are hints, not gold. They remain quarantined until an independent body-only exact preflight is committed.
- Stale or contaminated IDs are explicit negative evidence and cannot appear in scoreable gold.
- `TASK8_SCORE: verdict=CORPUS_MATCH` means all seven evidence-backed records matched the committed corpus. It is a dated characterization, not independent external ground truth: candidate-body snapshots and a separate adjudication receipt are still missing. It does not certify the 16 quarantined records, the full 23-record corpus, or a current live MathSecr result.
- A body-exact evaluation cannot be promoted to `external-ground-truth` from self-declared provenance strings or three unrelated files. Promotion remains disabled until a typed adjudication receipt binds the exact source/candidate artifact hashes and its validator is part of the full runner.
- Live selection remains governed only by the linked Body-Exact Selection Contract; this dated evaluation neither expands nor replaces it.

## Blind-Run Procedure

Run the scorer-side contract first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\mathsecr-paper-builder-kit\scripts\verify_body_exact_benchmark.ps1 -ProjectRoot .
```

Export an empty runner directory. The exporter creates exactly the blinded corpus and a runner manifest; it does not export gold, observations, evidence markers, or scorer hashes.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\mathsecr-paper-builder-kit\scripts\export_body_exact_blind_run.ps1 -ProjectRoot . -OutDir <empty-runner-directory>
```

The runner reads only those two exported files and returns JSON containing `corpus_id`, `blinded_sha256`, `status`, and `records`. Each submitted record contains `record_key`, `selected_ids`, and a nonblank `body_only_preflight_rationale`; `gold_sha256` and all expected-result fields are forbidden.

Score the returned submission only in the scorer workspace:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\mathsecr-paper-builder-kit\scripts\verify_body_exact_benchmark.ps1 -ProjectRoot . -SubmissionPath <submission.json>
```

Quarantined submissions are reported as unscored diagnostics. They cannot increase the exact score or make a `success` claim pass.

## Forbidden Or Blocked Actions

- Do not click `출제하기` unless the user explicitly requests it.
- Do not click `전체 선택`, `문제지에 담기`, `변경하기`, or `선택 삭제` during feature or simulator QA unless the test explicitly simulates a non-live local control.
- Do not use Chrome, Computer Use, raw backend URLs, API routes, or help/docs in the live paper tab as a substitute for iab-owned live work.
- Do not use `번호순 정렬` as proof of arbitrary source order.

## Report Contract

The internal Korean verification packet must include:

- original source count
- selected count
- draft/local count before save
- persisted/reloaded count and order after save
- final edit-screen reached yes/no
- save/confirm clicked yes/no/absent
- reload/fresh-tab verification yes/no
- missed numbers and tried clues
- one distinct workspace-`AGENTS.md`-format search-attempt receipt per missed row, Ordinal-bound to its source problem number and occurrenceKey, whose referenced packet recomputes to `miss-closure-ready` under the canonical executable contract
- out-of-initial-range exact selections
- replacements/similar candidates and approval state
- browser surface and non-Aside-REPL live manipulation flag
- live-tab route/help/docs accident
- `출제하기` click status

The user-facing paper result is a closed 0–4 projection:

```text
0. 제작한 문제지 링크
   - [paper name](https://www.mathsecr.com/mypaper/<paper-id>)
1. 성공한 문제 S문제/T문제
2. 실패한 문제 F문제/T문제
   1. 원본 실패 번호를 쉼표로 묶은 목록 또는 없음
3. 실패한 문제 이미지 크롭 보고서 PDF
   - [crop report](<actual PDF path>) 또는 없음
4. 출처
   1. 출처 family/root — 성공 문제 수문제
```

`S` is the count of persisted/reload-verified exact original problems, `T` is the original problem count, and `F=T-S`; the public notation has no `#` or `@`. A normal per-problem failure requires a real crop-report PDF; when `F=0`, the failed-number and PDF lines are `없음`. A session-wide blocker may use `전체 세션 — 차단` and `없음` for the PDF because no problem-number crop can be produced.

The `4. 출처` rows are computed only from the visible `DB명` of successful cards after final persisted/reload verification. Normalize official DBs to their organization family/root (for example `교육청`, `평가원`); for other DBs, take the root before `>` and remove a leading edition year. Exclude failed problems. Sort by descending frequency, break ties by first appearance in original/edit order, and emit at most three ranked rows. Emit only the one or two rows that exist; if `S=0`, emit `1. 없음`. IDs, filters, internal state, browser/tool notes, checkpoints, and other URLs remain in the internal packet unless the user separately asks for diagnostics.

Completion requires evidence, not tone. If the evidence is missing, the internal status is `차단` or a report-lint failure until fixed.
