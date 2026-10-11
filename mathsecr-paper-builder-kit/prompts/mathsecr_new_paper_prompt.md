# 새 MathSecr 문제지 생성 프롬프트

<!-- SEARCH_ATTEMPT_SSOT_REF -->
<!-- DB_INFERENCE_SSOT_REF -->
<!-- METADATA_RESCUE_SSOT_REF -->
<!-- BODY_EXACT_SSOT_REF -->

```text
TASK: 새 MathSecr/수학비서 문제지를 원본 PDF/HWPX 기준으로 생성한다.

입력:
- 문제지 URL: <새 빈 MathSecr 문제지 URL>
- 원본 파일: <PDF/HWPX 경로>
- 최초 세팅 스크린샷: <사용자가 첨부한 DB/출처/단원/유형 화면 또는 없음>
- 목표: 원본 문제를 MathSecr에서 exact match로 찾아 원본 순서대로 담고, 저장/재로드 검증까지 완료한다.

반드시 먼저 읽기:
- 현재 workspace root의 `AGENTS.md`
- Codex home 아래 `skills/mathsecr-paper-builder/SKILL.md`
- 참고 근거: .omo/evidence/mathsecr_new_paper_adaptive_search_policy_2026-06-05.md

브라우저/안전:
- live MathSecr 조작은 세션 입력의 surface로 한다. surface가 aside-repl이면 열린 탭을 먼저 조회하고 관련 MathSecr 탭에 attach한 뒤 `snapshot()`을 기본 판독 경로로 사용한다.
- SURFACE_HARD_STOP: Stay on the surface declared by the session input. If that surface is unavailable or cannot attach to and verify the live paper, report `차단`. Do not switch that session to any other browser surface.
- ASIDE_OFF_USER_RESPONSE: 제작 요청에서 현재 probe가 Aside 종료를 확인하면 `aside 키고 다시 오도록.` 한 줄만 출력한다. 일반 timeout·CLI 부재·paper 검증 실패는 종료로 단정하지 않는다. 이 예외는 surface가 aside-repl인 세션에만 적용한다.
- PRODUCTION_VALIDATION_REF: kit SKILL과 `docs/production_validation.md`의 절차에 따라 `check_browser_surface.ps1 -Surface <surface>`, `validate_production_step.ps1`의 Select·BeforeNext·AfterReload를 호출한다. 실제 관측·판단·시각·동작을 만들어 채우지 않는다.
- 절대 `출제하기`를 클릭하지 않는다.
- API/raw route/help/docs를 live paper tab에서 열지 않는다.
- 시작 시 /mypaper/<id> URL, 로그인 상태, visible paper title을 확인한다.
- 오래 열린 tab도 경과 시간만으로 reload하지 않는다. 현재 login과 source/query `제거` receipt를 다시 확인하고 기존 freshness gate를 통과하면 계속하며, receipt/login/freshness가 깨진 경우에만 reload/reopen recovery를 한다.
- 기존 작업물/이전 target ID를 mental model로 삼지 말고, 새 문제지 생성처럼 원본 PDF와 최초 세팅 스크린샷에서 출발한다.

최초 세팅:
- 사용자가 준 스크린샷이 최초 DB/출처/단원/유형 범위의 기준이다.
- 스크린샷/DB 지정이 없으면 Codex home `skills/mathsecr-paper-builder/SKILL.md`의 `DB Inference And Official Collection Contract`와 `mathsecr-paper-builder-kit/docs/db_inference_contract.md`만 따라 cluster evidence를 수집한다.
- 범위 칩/체크 상태를 `검색하기` 전마다 확인한다.
- DB 미지정 cluster packet은 `scripts/db_inference.ps1`로 판정하고 direct output을 state snapshot의 `dbInference`에 그대로 둔다. Canonical verdict가 `pending`/`unresolved`이면 scope selection을 막고 evidence/receipt만 복구한다.

검색 순서:
1. PDF/HWPX를 읽고 원본 문제번호 순 target table을 만든다.
2. 최초 세팅 DB 내부에서 문제번호 순서대로 exact 검색한다.
3. 각 source row의 검색 chip, provenance, submit/freshness, refinement, backoff, candidate recovery, whole-DB 재시도와 miss closure는 Codex home `skills/mathsecr-paper-builder/SKILL.md`의 `Search Attempt Contract` 절만 따른다. 판정은 `mathsecr-paper-builder-kit/scripts/search_attempt_contract.ps1`의 derived status를 그대로 사용하고 prompt에서 별도 규칙을 만들지 않는다.
4. `exact-found` candidate의 live 선택은 Codex home SKILL의 `Body-Exact Selection Contract` verdict만 따른다.
5. Rescue 대상 pending row는 whole DB 전에 Codex home SKILL의 `Metadata Rescue And Lazy Coverage Contract`를 수행하고 `scripts/state_machine.ps1`이 raw receipt를 재계산하게 한다.
6. Body verdict가 exact이면 선택한다. Metadata receipt가 incomplete이면 pending/blocked로 유지하고, exact 없이 complete coverage인 row만 다음 whole-DB 전이 대상으로 둔다.
7. Body contract가 unresolved glyph conflict를 반환하면 `source_anomaly`/pending으로 기록하고 자동 선택하지 않는다. Source/candidate render artifact와 실제 hash, target/occurrence, inspected candidate binding은 Codex home SKILL의 Body-Exact 절을 따르고 state machine이 재검산하게 한다. 이 row를 final missed나 0-selection 완료로 우회하지 않는다. 검증된 다른 exact의 부분 저장은 아래 승인된 경로를 따른다.
8. 최초 세팅 DB에서 찾은 exact들과 pending/missed/`source_anomaly` 상태를 체크포인트로 기록한다. 가능하면 initial search + candidate-recovery + metadata rescue + whole-DB retry가 끝나기 전에는 `다음 단계`로 가지 않는다.
9. Metadata rescue가 complete coverage로 끝난 row만 verified `전체 DB`에서 새 contract packet으로 재시도한다. 최종 상태는 실행 contract의 `exact-found`, `miss-closure-ready`, `candidate-recovery-pending` 중 재계산된 값만 사용한다.

선택/저장/검증:
- exact가 아닌 유사/대체 문제는 기본 금지다. 사용자 명시 승인 없이는 선택하지 말고 미발견으로 보고한다.
- 찾은 exact는 원본 순서대로 유지한다. 늦게 추가되어 순서가 흐트러지면 final edit에서 복구한다.
- 안정 지점마다 저장한다: 5~8문항 단위, 최초 범위 pass 종료 전후, 전체 DB 전환 전, 전체 DB 추가 후, 최종 정렬 후.
- `requestedAction=partial-save`에서는 실제 선택 증거와 `BeforeNext` 판정을 먼저 확인한다. 검증된 exact가 있으면 나머지 pending·`source_anomaly`·미실행 row를 미해결로 남기고 선택 묶음만 편집·저장한다. 미해결 후보는 넣지 않는다. 부분 저장 동작이 아니면 검색 완료 후 편집 경로를 따른다. 추가 검색 경로는 실제 UI에서 별도로 검증한다.
- 저장/확인 컨트롤은 visible+enabled일 때만 클릭한다. 없으면 없다고 기록하고 reload/fresh-tab 검증으로 persisted count/order를 확인한다.
- `다음 단계` 이후 선택 수가 줄거나 낯선 기존 ID가 섞이면 completion이 아니다. 복구를 시도하고, 복구 불가 시 collapse/blocker와 preserved count를 보고한다.
- 원본의 각 인쇄 위치에는 stable `occurrenceKey`를 주고 DB `problemId`와 분리한다. 같은 ID가 반복되어도 원본 row를 합치지 않는다.
- 동일 result card를 재클릭해 duplicate를 만들지 않는다. 2026-07-31 dated same-card second activation은 관찰된 경로에서 기존 선택을 해제했다. 이를 service-wide toggle 계약으로 일반화하지 말고, 별도 visible 복제/추가 control과 edit/persisted ordered-bundle 증거가 검증된 경우에만 반복 occurrence를 완료 처리한다. 그렇지 않으면 뒤 occurrence를 `차단`으로 남긴다.

참고할 성공 사례:
- 019e82cc-9f18-7601-a9fd-8d6b0403ea76: 26문제 성공. 원본 순서 ID 검증, edit-screen count/order 확인, `출제하기` 미클릭을 참고.
- 019e827f-e3a3-7023-b665-c68af99c61b6: 39문제 성공. final order repair와 reload/API verification만 참고. replacement는 현재 기본 금지이므로 따라 하지 말 것.
- 019e8215-409b-7ce1-a531-34c63c808ca3: 30문제 partial 성공. 못 찾은 번호를 정확히 남기는 방식 참고.
- 019e916c-dc66-7322-8bec-37d361351ff3: 8/8 성공. exact selection, 편집 화면 reorder, reload persisted verification 참고.

주의할 실패 사례:
- 019e916c-0189-7183-a6d8-0f0a4f5f2c4f: 검색 UI에서 18개를 찾았지만 persisted는 1개였다. 검색 화면 count를 저장 성공으로 보지 말고, 저장/재로드 검증을 반드시 할 것.
- 019e9618-5449-74f2-85f3-ce9b56fe78a9: `공차 자연수 곱` 같은 공백 포함 한 칩은 실패 원인이다. 단서어는 `공차`/`자연수`/`곱` 개별 칩으로 만든다. `다음 단계` collapse와 stale ID contamination도 경계.
- 019ea06a-03ef-7b43-a38a-837206a33bdd: 고국2 프린트2에서 새 규칙이 11/18만 찾은 회귀. 과거 18개 search-UI IDs는 direct target이 아니라 same-source previous candidate map이며, text search miss 후 반드시 body-only exact 재검증 후보로 회수해야 한다.
- 019e9174-a654-7470-8cc1-499bd25f9d14: official collection scope-lock의 과거 route 표현을 재사용하지 말고 current DB inference SSOT를 다시 읽는다.
- 019e916f-b3d7-7d91-ba55-c117158a62c9, 019e971c-02fb-7ff0-9a89-badc33cb7a1c: exact가 없으면 0선택도 가능하다. 이때 최종 상태는 `완료`가 아니라 `검색 완료/0선택`으로만 쓰고, 유사문제 선택보다 정확한 미발견 번호 보고를 우선한다.
- 019e9167-71a8-7222-845a-0944eb3cb50c: body verdict의 row/whole-paper 전이는 body-exact SSOT를 따른다.

원본 문제 수, 선택 수, 저장 전 초안 수, 저장 후 reload/fresh-tab 확인 수, 미발견 번호, 전체 DB에서 찾은 exact, 대체/유사 승인 여부, 저장/확인 클릭 여부, live tab route 사고 여부, `출제하기` 미클릭 여부는 상세 한국어 `MathSecr 세션 보고서` 내부 검증 패킷에 모두 남기고 lint한다. 사용자 최종 출력은 아래 0–4 항목만 사용한다: `0. 제작한 문제지 링크`와 공개 paper link, `1. 성공한 문제 S문제/T문제`, `2. 실패한 문제 F문제/T문제`와 원본 실패 번호 쉼표 목록, `3. 실패한 문제 이미지 크롭 보고서 PDF`와 실제 PDF link, `4. 출처`와 최대 3개 정규화 출처 순위. 공개 형식에는 `#`와 `@`를 쓰지 않는다. 출처는 최종 persisted/reload 검증된 성공 카드의 visible `DB명`만 대상으로 official DB 조직 family/root 또는 비-official `>` 앞 root(leading edition year 제거)로 정규화하고, 빈도 내림차순·동률 원본/편집 첫 등장 순으로 집계한다. 성공 0이면 `1. 없음`, 서로 다른 출처가 1–2개면 그만큼만 쓴다. 실패가 0이면 실패 번호와 PDF를 `없음`으로 쓰며, 일반 실패가 있으면 대응하는 실제 PDF를 반드시 제공한다. 문제 번호가 없는 전체 세션 blocker만 PDF `없음`을 허용한다. ID, 검색어, 필터, 범위, 내부 상태, 설명은 출력하지 않는다. 사용자 초안은 `Invoke-MathSecrUserSummaryLint`를 통과해야 한다. 내부 패킷은 문제지 제작 결과 응답에 결합하지 않고, 사용자가 내부 진단 패킷 자체를 요청한 별도 질의에만 별도 응답 또는 artifact로 제공한다.
```
