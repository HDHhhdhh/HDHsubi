# Phase 3b · surface probe와 문서

## 시작 조건

Phase 3a가 `main`에 있다. 연구 과제 R1(Aside REPL 사양)과 R3(Codex 브라우저 표면)의 결과 PR이 `main`에 있다. 둘 중 하나라도 없으면 시작하지 않는다. probe 명령과 identity 필드는 추측으로 채우지 않는다.

## 목표

surface별 probe를 하나의 스크립트로 받는다. 세션 시작 입력에 surface를 적는다. 문서의 hard stop을 surface 기준으로 바꾼다. Aside 경로의 동작은 그대로다.

## 맥락

읽을 파일:

- [Phase 3a 지시서](phase-3.md)와 `docs/evidence/phase-3a.md`. `surface_contract.ps1`의 `Test-MathSecrSurfaceIdentityReceipt`와 선택 필드 `probeArtifact`.
- `docs/research/aside-repl.md`(R1), `docs/research/codex-browser-surfaces.md`(R3). probe 명령, identity 읽는 법, "실행 중 아님" 진단 문구의 근거다.
- `mathsecr-paper-builder-kit/scripts/check_aside_repl.ps1`, `aside_preflight.ps1`, `test_aside_preflight.ps1`. 현재 Aside probe와 receipt 검증이다.
- `mathsecr-paper-builder-kit/AGENTS.md:58`, `:180`. `skills/mathsecr-paper-builder/SKILL.md:20`, `:226`. `prompts/start-prompt.md:7-8`. `prompts/mathsecr_new_paper_prompt.md:24-25`. `ASIDE_REPL_HARD_STOP`과 `ASIDE_OFF_USER_RESPONSE` 위치다.
- `mathsecr-paper-builder-kit/scripts/validate_mathsecr_docs.ps1:264`, `:417`, `:796`. marker 검사다.
- `docs/incidents.md` 사고 16~21(`:107-142`).

## 작업

1. `mathsecr-paper-builder-kit/scripts/check_browser_surface.ps1 -Surface <name>`을 만든다. Aside 분기는 `check_aside_repl.ps1`의 코드를 그대로 옮긴다. `check_aside_repl.ps1`는 `-Surface aside-repl`을 부르는 래퍼로 남긴다. 출력과 종료 코드는 지금과 같다. `codex-iab`·`codex-chrome-ext` 분기는 R1·R3가 확인한 명령만 쓴다. 미확인 항목은 `failureClass='install'`에 사유 문장을 적고 끝낸다. `offline-dom-test` 분기는 Playwright 모듈과 브라우저 실행 파일 존재만 확인한다.
2. probe receipt를 정한다. `{schemaVersion:1, surface, browserFamily, probedAtUtc, failureClass, diagnostic, identity{profileOrSessionId, tabId, url, version}}`. `failureClass`는 `none`, `install`, `connect`, `read`, `input` 중 하나다. `off` 판정은 Aside처럼 실제 "실행 중 아님" 진단 문구가 있을 때만 쓴다. 문구는 R1·R3 결과에서 가져온다.
3. `Test-MathSecrSurfaceIdentityReceipt`의 `probeArtifact`를 `offline-dom-test`를 뺀 surface에 필수로 바꾼다. artifact는 작업 2의 receipt JSON이다. `failureClass`가 `none`이 아니면 session을 거부한다. 토큰은 `surface-probe-failed:<failureClass>`다.
4. 문서를 바꾼다.
   - AGENTS, SKILL, 두 prompt의 `ASIDE_REPL_HARD_STOP`을 `SURFACE_HARD_STOP`으로 바꾼다. 문장은 "세션 입력의 `surface` 밖으로 자동 전환하지 않는다. surface가 unavailable이면 `차단`으로 보고한다"다.
   - `ASIDE_OFF_USER_RESPONSE`는 유지한다. Aside surface에서만 적용한다.
   - `prompts/start-prompt.md`에 `Surface: <aside-repl|codex-iab|codex-chrome-ext>` 입력 줄을 더한다. 비어 있으면 `aside-repl`이다.
   - `validate_mathsecr_docs.ps1`의 marker 검사를 새 이름에 맞춘다. 옛 marker가 남아 있으면 거부한다.
5. 시험을 더한다. probe receipt 양성·음성(`failureClass` 5종, 잘못된 surface, 미확인 명령 분기). `test_aside_preflight.ps1`는 그대로 PASS다. `test_surface_contract.ps1`에 `probeArtifact` 필수 사례를 더한다.

## 제약

- probe 명령과 진단 문구를 추측하지 않는다. R1·R3에 없는 값은 쓰지 않는다.
- 실제 브라우저에 접속하는 테스트를 만들지 않는다.
- 정책 문장은 작업 4의 범위만 바꾼다. 다른 규칙은 건드리지 않는다.
- 기존 함수 이름과 반환 구조를 유지한다. 기존 테스트 단정을 지우거나 약화하지 않는다.

## 완료 조건

```powershell
python ./scripts/validate_publication.py
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1 -PlaywrightModule <module> -BrowserPath <browser>
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/test_surface_contract.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./mathsecr-paper-builder-kit/scripts/test_aside_preflight.ps1
```

- 공개 gate가 모두 PASS다. 동일성 24개 PASS.
- `validate_mathsecr_docs.ps1 -Scenario All`은 비공개 bundle이 필요하다. 사용자가 로컬에서 실행하고 결과를 Issue #2에 남긴다. PR 본문에 이 사실을 쓴다.
- CI가 녹색이다.

## PR

브랜치 `codex/phase-3b`. 제목 `Phase 3b: surface probe와 문서`. 추론 노력 `high`. 모호하면 구현 전에 Issue #2에 질문한다.
