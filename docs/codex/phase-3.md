# Phase 3 · surface 추상화

## 시작 조건

사용자가 Issue #1에서 결정 D1을 승인한 뒤에만 시작한다. 승인이 없으면 이 Phase를 시작하지 않는다.

## 목표

브라우저 surface를 typed 값으로 받는다. 허용값은 `aside-repl`, `codex-iab`, `codex-chrome-ext`, `offline-dom-test`다. 다른 surface의 근거를 섞어 기록하면 거부한다. Aside 경로는 기본값으로 그대로 동작한다.

## 맥락

읽을 파일:

- `docs/refactor-plan.md` 3.3절, Phase 3 절.
- 하드코딩 위치:
  - `mathsecr-paper-builder-kit/scripts/state_machine.ps1:1098`, `:1162`, `:1196`, `:1210`.
  - `mathsecr-paper-builder-kit/scripts/production_validation.ps1:104`.
  - `mathsecr-paper-builder-kit/scripts/body_comparison_contract.ps1:60`.
  - `mathsecr-paper-builder-kit/scripts/search_observation_contract.ps1:131`.
  - `mathsecr-paper-builder-kit/scripts/validate_mathsecr_docs.ps1:416` 부근. `aside-repl-unavailable block`과 `ASIDE_REPL_HARD_STOP` marker 검사.
- `mathsecr-paper-builder-kit/scripts/check_aside_repl.ps1`, `aside_preflight.ps1`, `test_aside_preflight.ps1`. 현재 probe와 receipt 검증.
- `mathsecr-paper-builder-kit/AGENTS.md` 브라우저 소유권 절. `skills/mathsecr-paper-builder/SKILL.md` Hard Stops 절. `prompts/start-prompt.md`, `prompts/mathsecr_new_paper_prompt.md`.
- `docs/incidents.md` 사고 16~21. surface 오분류와 probe 오판의 이력이다.
- `docs/codex/research-tasks.md` R1·R3 결과. probe 명령과 identity 필드의 근거다.

## 작업

1. `mathsecr-paper-builder-kit/scripts/surface_contract.ps1`를 만든다.
   - `$MathSecrSupportedSurfaces = @('aside-repl','codex-iab','codex-chrome-ext','offline-dom-test')`.
   - `Test-MathSecrSupportedSurface -Surface`.
   - `Test-MathSecrSurfaceIdentityReceipt -Receipt`. 필수 필드는 `surface`, `browserFamily`, `profileOrSessionId`, `tabId`, `url`, `observedAtUtc`, `probeArtifact{path,sha256}`다. `browserFamily`와 `surface`의 허용 조합을 표로 둔다. 예: `codex-chrome-ext`는 `browserFamily=chrome`만 허용한다. `aside-repl`은 `browserFamily=aside`만 허용한다.
2. 하드코딩 6곳을 `Test-MathSecrSupportedSurface` 호출로 바꾼다. 한 세션의 모든 receipt는 같은 surface여야 한다. `Invoke-MathSecrStateMachine`에서 세션 surface를 한 번 정하고 모든 receipt와 비교한다. 다르면 `surface-mismatch`로 거부한다.
3. `check_aside_repl.ps1`를 `check_browser_surface.ps1 -Surface <name>`로 일반화한다. Aside 분기는 기존 코드를 그대로 옮긴다. `check_aside_repl.ps1`는 `-Surface aside-repl`을 호출하는 래퍼로 남긴다. IAB와 Chrome 분기는 R1·R3 결과의 probe 명령을 쓴다. 결과 receipt의 `failureClass`는 `install`, `connect`, `read`, `input`, `none` 중 하나다. `off` 판정은 Aside와 같이 실제 "실행 중 아님" 진단이 있을 때만 쓴다.
4. 문서를 바꾼다.
   - AGENTS, SKILL, 두 prompt의 `ASIDE_REPL_HARD_STOP`을 `SURFACE_HARD_STOP`으로 바꾼다. 문장은 "세션 입력의 `surface` 밖으로 자동 전환하지 않는다. surface가 unavailable이면 `차단`으로 보고한다"다.
   - `ASIDE_OFF_USER_RESPONSE`는 유지한다. Aside surface에서만 적용한다.
   - `prompts/start-prompt.md`에 `Surface: <aside-repl|codex-iab|codex-chrome-ext>` 입력 줄을 추가한다. 비어 있으면 `aside-repl`이다.
   - `validate_mathsecr_docs.ps1`의 marker 검사를 새 이름에 맞춘다. 옛 marker가 남아 있으면 거부한다.
5. 음성 테스트를 추가한다.
   - IAB identity receipt에 `surface=aside-repl`. 거부.
   - 세션 안에서 search receipt는 `codex-iab`, persisted capture는 `aside-repl`. 거부.
   - 알 수 없는 surface 문자열. 거부.
6. 양성 테스트를 추가한다. 네 surface 각각의 합성 세션이 Select·BeforeNext·AfterReload를 PASS한다.

## 제약

- Aside 경로의 기존 테스트는 모두 그대로 PASS해야 한다.
- 실제 브라우저에 접속하는 테스트를 만들지 않는다.
- 정책 문장은 위 4번의 범위만 바꾼다. 다른 규칙은 건드리지 않는다.
- 기존 함수 이름과 반환 구조를 유지한다.

## 완료 조건

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./mathsecr-paper-builder-kit/scripts/test_production_validation.ps1 -ProjectRoot .
pwsh -NoProfile -ExecutionPolicy Bypass -File ./mathsecr-paper-builder-kit/scripts/test_aside_preflight.ps1
```

- 네 surface 양성, 세 가지 음성이 모두 기대대로다.
- `validate_mathsecr_docs.ps1 -Scenario All`은 비공개 bundle이 필요하다. 사용자가 로컬에서 실행하고 결과를 Issue #1에 남긴다. PR 본문에 이 사실을 쓴다.
- CI가 녹색이다.

## PR

브랜치 `codex/phase-3`. 제목 `Phase 3: surface 추상화`. 추론 노력 `high`.
