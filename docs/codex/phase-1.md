# Phase 1 · AfterReload 중복 검증 제거

## 목표

과거 세션 수 H에서 `Invoke-MathSecrStateMachine` 실행이 H+1회다. 모든 artifact는 한 호출에서 한 번만 읽고 한 번만 해시한다. 검증 결과는 변경 전과 같다. 거부 동작도 같다.

## 맥락

읽을 파일:

- `docs/refactor-plan.md` 3.1절, Phase 1 절.
- `mathsecr-paper-builder-kit/scripts/production_validation.ps1`
  - `:12-27` `Get-MathSecrProductionArtifact`. 해시 검사 뒤 경로를 돌려준다.
  - `:38-40`, `:100-102`, `:215-217`. 같은 artifact를 두 번 호출한다.
  - `:53-54`. 원본 crop 47개를 매 호출 해시한다.
  - `:200-245` `Invoke-MathSecrProductionStep`. `:225` production 재귀, `:227` state machine 호출, `:237` 최종 append 재검사.
  - `:137`, `:152`. `Where-Object` 중첩.
- `mathsecr-paper-builder-kit/scripts/state_machine.ps1`
  - `:1066-1089` `Read-MathSecrEditAppendArtifact`. 해시 두 번.
  - `:1091-1226` `Test-MathSecrEditAppendReceipt`. `:1106` state 재귀. `:1115`, `:1127`, `:1134`, `:1146-1147` 핫스팟.
  - `:1273` 이후 `Invoke-MathSecrStateMachine`. `:1841-1849` append 분기.
- `mathsecr-paper-builder-kit/scripts/read_contract_json.ps1`.
- `mathsecr-paper-builder-kit/scripts/body_comparison_contract.ps1:134`. 후보 render 해시.
- `mathsecr-paper-builder-kit/scripts/test_production_validation.ps1`, `test_partial_save_phases.ps1`, `test_state_machine.ps1`. 음성 사례가 여기 있다.
- `docs/evidence/perf-baseline.json`. Phase 0의 기준선.

## 작업

1. `read_contract_json.ps1`에 `Read-MathSecrArtifactBytes -Path -ExpectedSha256`를 추가한다. 파일 바이트를 한 번 읽는다. 바이트로 SHA-256을 계산한다. 기대 해시와 다르면 throw한다. 같으면 바이트를 UTF-8로 파싱한다. 반환은 `{Path, Sha256, Value}`다. 기존 "해시 → 읽기 → 해시" 패턴을 모두 이 함수로 바꾼다. 바이트 기준이므로 변조 감지 보증은 같다.
2. `New-MathSecrValidationContext`를 추가한다. 내용은 두 개의 `Dictionary`다. artifact 캐시 key는 `"<정규화 경로>|<sha256>"`이다. state 캐시 key는 `"<세션 artifact sha256>|<Phase>|<CONTRACT_VERSION>"`이다. `CONTRACT_VERSION` 상수를 `state_machine.ps1` 상단에 둔다. 값은 `'2026-10-11.1'`로 시작한다.
3. `Invoke-MathSecrProductionStep`, `Invoke-MathSecrStateMachine`, `Test-MathSecrEditAppendReceipt`, `Assert-MathSecrProductionRoster`, `Get-MathSecrProductionArtifact`, `Read-MathSecrEditAppendArtifact`에 선택 인자 `-Context`를 추가한다. 인자가 없으면 함수 진입에서 새 컨텍스트를 만든다. 재귀 호출에는 같은 컨텍스트를 넘긴다. 컨텍스트는 반환값에 포함하지 않는다.
4. `:225`의 production 재귀가 만든 `priorValidation.StateResult`를 state 캐시에 넣는다. `:1106`의 state 재귀는 캐시를 먼저 본다. `:237`의 최종 append 재검사는 같은 컨텍스트를 쓴다. 세 경로 모두에서 같은 세션은 한 번만 state machine을 실행한다.
5. 핫스팟을 고친다.
   - `:137`, `:152`, `:1115`, `:1134`. 번호와 occurrenceKey를 `HashSet[string]` 또는 `Dictionary`로 만든 뒤 조회한다.
   - `:1127`. `ConvertTo-Json -Depth 100` 비교를 재귀 구조 비교 함수 `Test-MathSecrObjectEquals`로 바꾼다. 배열 순서, 속성 이름, 스칼라 값과 형식을 비교한다.
   - `:1146-1147`. `+=`를 `List[string]`으로 바꾼다.
6. 캐시 격리 테스트를 `test_production_validation.ps1`에 추가한다. 같은 프로세스에서 정상 입력을 검증한 뒤, artifact 바이트를 변조하고 다시 검증한다. 두 번째는 거부돼야 한다. 변조 뒤 해시를 갱신한 입력도 내용 규칙에 따라 거부돼야 한다.
7. `scripts/perf/measure_after_reload.ps1`로 N=15, H=1/2/6을 3회 측정한다. 결과를 `docs/evidence/perf-phase1.json`에 기록한다.

## 제약

- 기존 함수 이름과 반환 구조를 바꾸지 않는다. `-Context`만 추가한다.
- 과거 결과 파일의 `Valid` 값을 읽어 재사용하지 않는다.
- 해시 검사를 생략하지 않는다. 횟수만 줄인다.
- 기존 테스트 단정을 지우거나 약화하지 않는다.
- `state_machine.ps1`의 다른 계약 로직을 이 PR에서 바꾸지 않는다.

## 완료 조건

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./mathsecr-paper-builder-kit/scripts/test_production_validation.ps1 -ProjectRoot .
pwsh -NoProfile -ExecutionPolicy Bypass -File ./mathsecr-paper-builder-kit/scripts/test_partial_save_phases.ps1 -ProjectRoot .
pwsh -NoProfile -ExecutionPolicy Bypass -File ./mathsecr-paper-builder-kit/scripts/test_state_machine.ps1 -ProjectRoot . -Case All
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/perf/measure_after_reload.ps1 -ProblemCount 15 -HistoryDepth 6 -Repeat 3
```

- 위 테스트가 모두 PASS다. 음성 사례 수가 변경 전과 같거나 많다.
- 동일성 검사: Phase 0 생성기의 N=15, H=1/2/6 입력에서 변경 전·후 출력 JSON이 같다. 시각 필드만 제외한다. 비교 스크립트와 결과를 PR에 첨부한다.
- 계측: state machine 호출 수가 H+1이다. `Get-FileHash` 또는 바이트 해시 횟수가 서로 다른 artifact 수 이하다.
- H=6 시간이 기준선의 1/5 이하다. 달성하지 못하면 실제 비율과 남은 병목을 PR에 쓴다.
- CI가 녹색이다.

## PR

브랜치 `codex/phase-1`. 제목 `Phase 1: AfterReload 중복 검증 제거`. 추론 노력 `extra high`.
