# Phase 4 · 지침 축소·구조 정리

## 목표

세션 시작 읽기 분량을 줄인다. 큰 파일을 역할별로 나눈다. 동작은 바뀌지 않는다.

## 맥락

읽을 파일:

- `docs/refactor-plan.md` Phase 4 절.
- `mathsecr-paper-builder-kit/scripts/state_machine.ps1`. 2,173줄 40함수. 함수 목록은 `grep -n "^function"`으로 본다.
- `mathsecr-paper-builder-kit/AGENTS.md`(286줄), `skills/mathsecr-paper-builder/SKILL.md`(251줄). Required Refresh 절이 세션마다 전체 읽기와 SHA 기록을 요구한다.
- `mathsecr-paper-builder-kit/scripts/validate_mathsecr_docs.ps1`(931줄). 문구와 marker 검사.
- `mathsecr-paper-builder-kit/scripts/install.ps1`, `check.ps1`, `test_install_contract.ps1`. evidence bundle 결합.
- `scripts/run_offline_regression.ps1`, `.github/workflows/offline-regression.yaml`.
- Phase 2 PR 본문의 SKILL 변경 제안.

## 작업

1. `state_machine.ps1`를 나눈다. 새 폴더 `mathsecr-paper-builder-kit/scripts/state/`에 `identity.ps1`(토큰·key·ID 검사), `receipts.ps1`(source anomaly, metadata rescue, blank probe, edit append receipt), `transitions.ps1`(row state, resolution, New-StateResult, Invoke-MathSecrStateMachine)를 만든다. `state_machine.ps1`는 세 파일을 dot-source하는 진입점으로 남긴다. 함수 이름, 시그니처, 반환 구조를 유지한다.
2. AGENTS와 SKILL을 두 층으로 나눈다.
   - 핵심 계약: 세션 시작에 읽는다. 각 80줄 이하다. Hard Stops, 브라우저 소유권 핵심, 4게이트, 보고 형식 0–4, 참조 문서 목록만 둔다.
   - 참조 문서: `mathsecr-paper-builder-kit/docs/agents-reference.md`, `docs/skill-reference.md`. 옮긴 절은 문장을 바꾸지 않는다. 삭제하지 않는다.
   - `세션 근거 인덱스`는 `mathsecr-paper-builder-kit/docs/evidence-index.md`로 옮긴다.
   - Required Refresh의 전체 읽기 대상은 핵심 계약 두 파일이다. 참조 문서는 해당 작업에서만 읽는다.
3. `validate_mathsecr_docs.ps1`의 검사를 분류한다. 계약 marker와 SSOT 참조 검사는 유지한다. 참조 문서로 옮긴 절의 marker도 그 파일에서 검사한다. 단순 문구 존재 검사는 `record-only` 목록으로 옮기고 경고만 낸다. 분류 표를 PR 본문에 쓴다.
4. `install.ps1`에서 evidence bundle을 선택 사항으로 바꾼다. 없으면 경고를 내고 계속한다. `-RequireEvidence` 스위치가 있으면 기존대로 실패한다. `test_install_contract.ps1`의 기존 사례는 `-RequireEvidence`로 유지한다. 공개 clone 설치 양성 사례를 추가한다.
5. CI에 PS5.1 실행을 추가한다. `windows-latest`에서 `powershell.exe -File ./scripts/run_offline_regression.ps1`를 한 번 더 돈다. PS5.1에서 실패하는 테스트는 이유를 적고 `pwsh-only` 표시를 한다.
6. Phase 2 PR에서 제안한 SKILL 변경(control map 파일 사용, 조립기 사용)을 반영한다.

## 제약

- 규칙 문장을 삭제하지 않는다. 이동만 한다.
- 함수 이름과 시그니처를 바꾸지 않는다.
- installer의 `-Force` 삭제 동작을 바꾸지 않는다.

## 완료 조건

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./mathsecr-paper-builder-kit/scripts/test_install_contract.ps1
```

- 회귀와 CI가 두 PowerShell에서 녹색이다.
- PR 본문에 세션 시작 읽기 분량(줄 수) 전후가 있다. 목표는 537줄에서 160줄 이하다.
- `validate_mathsecr_docs.ps1 -Scenario All`은 사용자가 비공개 bundle에서 실행하고 결과를 Issue #2에 남긴다.

## PR

브랜치 `codex/phase-4`. 제목 `Phase 4: 지침 축소·구조 정리`. 추론 노력 `high`.
