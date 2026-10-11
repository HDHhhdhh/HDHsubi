# Phase 3b · surface probe와 문서

확인 날짜: 2026-10-11. 기준 main은 `0da38ce`다. [PR #13의 지시서](../codex/phase-3b.md)와 Issue #2 답변 3건을 적용했다. D5·D6은 사용자 승인대로 적용했다. 수치는 공개 합성 계약 시험이며 실제 로그인·문제지·입력 성공을 뜻하지 않는다.

Aside는 기존 availability·stdout·OutPath·종료 코드를 유지하고 공통 probe JSON을 선택한 새 파일에 쓴다. Codex는 tool receipt 파일만 읽고, BrowserInfo kind와 identity·탭·URL을 순서대로 대조한다. Chrome의 연결 ID는 extension instance이며 실제 profile 디렉터리라는 주장이 아니다. offline probe는 두 경로의 존재만 검사한다.

선언된 live surface는 JSON probe artifact가 필요하다. 안전 경로·단일 읽기 해시·형식 검사 뒤 surface, failureClass, tabId·URL·확인된 session/instance ID를 대조한다. 선언 없는 기존 session의 경로와 출력은 유지한다. JSON 루트가 배열이면 거부하며, 이 검사는 캐시의 원시 바이트를 사용한다.

## 공개 검증

| 검사 | 결과 |
|---|---|
| Publication / public checks | PASS |
| 공개 gate 전체 | 15 PASS / 0 FAIL / 20 SKIP |
| SurfaceContract | 양성 12 PASS, 음성 19 거부 PASS |
| 기존·지정 음성 | 기존 9 + 지시서 추가 7 |
| 추가 음성 | profile ID·URL 불일치, 단일 원소 JSON 배열 3 |
| SurfaceProbe | 78 PASS: 분류 41, 형식 양성 6·음성 22, CLI 양성 2·음성 7 |
| Phase 0 대비 동일성 | 24 PASS, baseline `961c411` |
| Prompt 순수 검사 | 실제 prompt 2개, 합성 음성 3개 PASS |
| Source snapshot | export 10개 갱신, 원본 sourceSha256 72개 유지 |

새 거부 토큰은 `surface-probe-required`, `surface-probe-failed:<class>`, `surface-probe-identity-mismatch`다. 각 class는 install·connect·read·input을 검사했다. probe는 input을 만들지 않는다. 대문자 surface 입력과 기존 receipt 파일 덮어쓰기도 거부했다.

재현:

```powershell
python ./scripts/validate_publication.py
pwsh -NoProfile -File ./scripts/run_public_checks.ps1
pwsh -NoProfile -File ./scripts/run_offline_regression.ps1 -PlaywrightModule <module> -BrowserPath <browser>
pwsh -NoProfile -File ./scripts/test_surface_contract.ps1
pwsh -NoProfile -File ./scripts/test_browser_surface_probe.ps1
pwsh -NoProfile -File ./scripts/perf/compare_after_reload.ps1 -BaselineRoot <Phase0-checkout> -CandidateRoot <current-checkout>
```

원시 계수와 export·SKIP 목록은 [phase-3b-checks.json](phase-3b-checks.json)에 있다. CI는 구현 PR의 해당 head에서 같은 공개 gate와 동일성 비교를 실행한다.

## 호환성과 남은 검증

지시서의 기능 범위 이탈은 없다. 변경하지 않는 `test_aside_preflight.ps1`은 기존 wrapper에서 순수 argv 함수 2개를 AST로 추출하고 원래 명령을 정확히 비교한다. 이 소비자를 보존하려고 wrapper에 두 정의를 남겼다. 실제 실행은 새 script로 위임한다. 공용 fixture helper의 선택적인 PrepareSession 인자는 기본값 null이며, 합성 probe를 과거 session 파일의 해시를 고정하기 전에 넣는 데만 사용한다.

**비공개 gate는 사용자가 로컬에서 실행한다:** `test_aside_preflight.ps1`, `validate_mathsecr_docs.ps1 -Scenario All`, `test_install_contract.ps1`. 공개 clone에서 private-bundle 20개는 SKIP이며 이 PR의 PASS로 주장하지 않는다. 공식 installer `-Force`로 root AGENTS와 installed SKILL을 동기화한 뒤 All·SyncContract를 실행하는 절차와 실제 Aside probe 1회는 [지시서](../codex/phase-3b.md)를 따른다. 이번 구현 검증에서 설치된 정책 사본이나 사용자 브라우저를 변경하지 않았다.

Phase 4에는 내부 보고서의 비-Aside REPL 필드, `ASIDE_REPL_READY` 이름, `asideRepl.nonAsideReplLiveManipulation`을 남겼다.
