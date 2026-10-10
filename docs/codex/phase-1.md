# Phase 1 · AfterReload 중복 검증 제거

## 목표

과거 세션 수 H에서 `Invoke-MathSecrStateMachine` 실행이 H+1회다. 모든 artifact는 한 호출에서 한 번만 읽고 한 번만 해시한다. 검증 결과는 변경 전과 같다. 거부 동작도 같다.

## 기준선 · Phase 0 측정값

N=15, 3회 중앙값. 원시 값은 `docs/evidence/perf-baseline.json`에 있다.

| H | 시간(초) | StateMachine | ProductionStep | Get-FileHash | Contract JSON parse |
|---:|---:|---:|---:|---:|---:|
| 1 | 1.430 | 4 | 2 | 194 | 25 |
| 2 | 2.016 | 9 | 3 | 425 | 68 |
| 6 | 8.664 | 49 | 7 | 2,049 | 440 |

StateMachine 호출은 `(H+1)²`다. ProductionStep 호출은 H+1이다. 이 값은 바뀌지 않는다. Get-FileHash 2,049회는 `state_machine.ps1:422-423`의 crop·candidate 해시와 `:1085`, `:1087`, `production_validation.ps1:24`, `:54`의 artifact 해시를 모두 포함한다.

Phase 1 목표값:

| H | StateMachine | ProductionStep | 해시 호출 합계 | JSON parse | 시간(초) |
|---:|---:|---:|---:|---:|---:|
| 1 | 2 | 2 | ≤ artifactCount | ≤ artifactCount | 보고 |
| 2 | 3 | 3 | ≤ artifactCount | ≤ artifactCount | 보고 |
| 6 | 7 | 7 | ≤ artifactCount | ≤ artifactCount | ≤ 2.2 |

`artifactCount`는 생성기가 임시 폴더에 쓴 파일 수다. 작업 1에서 manifest에 넣는다. 해시 호출 합계는 `Get-FileHash`와 새 `Read-MathSecrArtifactBytes`의 합이다. 시간 목표 2.2초는 기준선 8.664초의 1/4이다. 달성하지 못하면 실제 비율과 남은 병목을 PR에 쓴다.

## 맥락

읽을 파일:

- `docs/refactor-plan.md` 3.1절, Phase 1 절.
- `docs/evidence/phase-0.md`, `docs/evidence/regression-inventory.md`. 공개 gate 11개와 SKIP 20개의 목록이다.
- `mathsecr-paper-builder-kit/scripts/production_validation.ps1`
  - `:12-27` `Get-MathSecrProductionArtifact`. 해시 검사 뒤 경로를 돌려준다.
  - `:38-40`, `:100-102`, `:215-217`. 같은 artifact를 두 번 호출한다.
  - `:53-54`. 원본 crop을 매 호출 해시한다.
  - `:200-245` `Invoke-MathSecrProductionStep`. `:225` production 재귀, `:227` state machine 호출, `:237` 최종 append 재검사.
  - `:137`, `:152`. `Where-Object` 중첩.
- `mathsecr-paper-builder-kit/scripts/state_machine.ps1`
  - `:422-423`. 문항별 source crop과 candidate render 해시. state machine 호출마다 반복된다.
  - `:1066-1089` `Read-MathSecrEditAppendArtifact`. `:1085`, `:1087` 해시 두 번.
  - `:1091-1226` `Test-MathSecrEditAppendReceipt`. `:1106` state 재귀. `:1115`, `:1127`, `:1134`, `:1146-1147` 핫스팟.
  - `:1273` 이후 `Invoke-MathSecrStateMachine`. `:1841-1849` append 분기.
- `mathsecr-paper-builder-kit/scripts/read_contract_json.ps1`.
- `mathsecr-paper-builder-kit/scripts/body_comparison_contract.ps1:134`. 후보 render 해시.
- `scripts/perf/append_history_support.ps1`. Phase 0 합성 입력 생성기. `New-MathSecrAppendHistoryFixture`가 manifest를 돌려준다.
- `scripts/perf/measure_after_reload.ps1`. proxy 계측기. `$names` 목록의 함수만 센다.
- `scripts/test_append_history_fixture.ps1`. 공개 변조 거부 시험. 해시 호출 단정이 `:55`에 있다.
- `scripts/offline-regression-gates.json`. 공개 gate manifest. 새 시험은 여기에 등록해야 runner가 실행한다.

현재 상태:

- `test_production_validation.ps1`, `test_partial_save_phases.ps1`, `test_state_machine.ps1`은 `private-bundle` 등급이다. 공개 clone에서 SKIP이다. 이 세 suite는 D4 합성 자료가 있을 때만 돈다.
- 공개 음성 사례는 `scripts/test_append_history_fixture.ps1`에 있다. prior hash 변조, `confirmActionArtifact` 삭제, `rawVisibleDbName` 변조, PNG 바이트 변조를 거부한다.

## 작업

1. 계측 준비를 먼저 한다.
   - `New-MathSecrAppendHistoryFixture`의 manifest에 `artifactCount`를 넣는다. 값은 `OutRoot` 아래 파일 수다. `Get-ChildItem -File -Recurse`로 센다.
   - `measure_after_reload.ps1`의 `$names`에 `Read-MathSecrArtifactBytes`를 넣는다. 출력 JSON에 `artifactCount`, `hashCalls`(두 해시 함수의 합), `hashCallsPerArtifact`를 넣는다.
   - `test_append_history_fixture.ps1:55`의 `Get-FileHash -gt 0`을 `hashCalls -gt 0`으로 바꾼다. 이 단정은 Phase 0에서 만든 것이다. 원래 테스트 단정이 아니다. PR에 이유를 쓴다.
2. `read_contract_json.ps1`에 `Read-MathSecrArtifactBytes -Path -ExpectedSha256`를 추가한다. 파일 바이트를 한 번 읽는다. 바이트로 SHA-256을 계산한다. 기대 해시와 다르면 throw한다. 같으면 바이트를 UTF-8로 파싱한다. 반환은 `{Path, Sha256, Value}`다. 기존 "해시 → 읽기 → 해시" 패턴을 모두 이 함수로 바꾼다. 바이트 기준이므로 변조 감지 보증은 같다. PNG처럼 JSON이 아닌 파일은 `Value`가 `$null`이다.
3. `New-MathSecrValidationContext`를 추가한다. 내용은 두 개의 `Dictionary`다. artifact 캐시 key는 `"<정규화 경로>|<sha256>"`이다. state 캐시 key는 `"<세션 artifact sha256>|<Phase>|<CONTRACT_VERSION>"`이다. `CONTRACT_VERSION` 상수를 `state_machine.ps1` 상단에 둔다. 값은 `'2026-10-11.1'`로 시작한다.
4. `Invoke-MathSecrProductionStep`, `Invoke-MathSecrStateMachine`, `Test-MathSecrEditAppendReceipt`, `Assert-MathSecrProductionRoster`, `Get-MathSecrProductionArtifact`, `Read-MathSecrEditAppendArtifact`에 선택 인자 `-Context`를 추가한다. 인자가 없으면 함수 진입에서 새 컨텍스트를 만든다. 재귀 호출에는 같은 컨텍스트를 넘긴다. 컨텍스트는 반환값에 포함하지 않는다.
5. `:225`의 production 재귀가 만든 `priorValidation.StateResult`를 state 캐시에 넣는다. `:1106`의 state 재귀는 캐시를 먼저 본다. `:237`의 최종 append 재검사는 같은 컨텍스트를 쓴다. 세 경로 모두에서 같은 세션은 한 번만 state machine을 실행한다.
6. `:422-423`과 `:53-54`의 crop·candidate 해시를 artifact 캐시로 한 호출에 1회만 한다. 캐시 key에 sha256이 들어가므로 기대 해시가 다른 receipt는 캐시를 쓰지 못한다.
7. 핫스팟을 고친다.
   - `:137`, `:152`, `:1115`, `:1134`. 번호와 occurrenceKey를 `HashSet[string]` 또는 `Dictionary`로 만든 뒤 조회한다.
   - `:1127`. `ConvertTo-Json -Depth 100` 비교를 재귀 구조 비교 함수 `Test-MathSecrObjectEquals`로 바꾼다. 배열 순서, 속성 이름, 스칼라 값과 형식을 비교한다.
   - `:1146-1147`. `+=`를 `List[string]`으로 바꾼다.
8. 캐시 격리 시험 `scripts/test_validation_context.ps1`을 만든다. Phase 0 생성기로 N=4, H=2 입력을 임시 폴더에 만든다. 같은 프로세스에서 다음을 순서대로 검사한다.
   - 정상 입력 검증 PASS.
   - artifact 바이트 변조 뒤 재검증 → 거부.
   - 변조 뒤 receipt의 sha256을 새 해시로 갱신한 입력 → 내용 규칙에 따라 거부.
   - 정상 입력 재검증 PASS. 앞의 거부가 뒤의 결과를 바꾸지 않는다.
   - `-Context`를 넘기지 않은 두 호출 사이에 캐시가 남지 않는다. 첫 호출 뒤 artifact를 바꾸면 둘째 호출은 거부한다.
   - 마지막 줄에 `ValidationContext PASS`를 출력한다.
   - `scripts/offline-regression-gates.json`에 `public` gate `ValidationContext`로 등록한다. `regression-inventory.md` 표에 한 줄을 추가한다.
9. 동일성 비교 스크립트 `scripts/perf/compare_after_reload.ps1 -BaselineRoot <경로> -CandidateRoot <경로>`를 만든다. 같은 임시 fixture를 두 checkout의 `Invoke-MathSecrProductionStep -Step AfterReload`에 넣는다. 결과를 `ConvertTo-Json -Depth 100`으로 만든다. 시각 필드만 제거한다. 두 문자열이 같으면 `AfterReloadIdentity PASS`를 출력한다. 다르면 첫 차이 경로를 출력하고 종료 코드 1이다. Baseline checkout은 `git worktree add <임시 폴더> codex/phase-0`으로 만든다. N=15, H=1/2/6을 비교한다.
10. `write_perf_baseline.ps1 -Repeat 3 -OutPath ./docs/evidence/perf-phase1.json`을 실행한다. 기존 `perf-baseline.json`은 덮어쓰지 않는다. 결과 표를 `docs/evidence/phase-1.md`에 쓴다. 열은 기준선 표와 같다. `artifactCount`와 `hashCallsPerArtifact` 열을 더한다.

## 제약

- 기존 함수 이름과 반환 구조를 바꾸지 않는다. `-Context`만 추가한다.
- 과거 결과 파일의 `Valid` 값을 읽어 재사용하지 않는다.
- 해시 검사를 생략하지 않는다. 횟수만 줄인다.
- 기존 테스트 단정을 지우거나 약화하지 않는다. 작업 1의 단정 변경만 예외다.
- `state_machine.ps1`의 다른 계약 로직을 이 PR에서 바꾸지 않는다.
- `private-bundle` suite를 공개 자료로 대체하지 않는다.
- 생성 결과와 worktree는 임시 폴더에만 둔다. 저장소에 커밋하지 않는다.

## 완료 조건

```powershell
python ./scripts/validate_publication.py
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_public_checks.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/test_validation_context.ps1
pwsh -NoProfile -File ./scripts/perf/compare_after_reload.ps1 -BaselineRoot <codex/phase-0 worktree> -CandidateRoot .
pwsh -NoProfile -File ./scripts/perf/measure_after_reload.ps1 -ProblemCount 15 -HistoryDepth 6 -Repeat 3
```

- 공개 gate가 모두 PASS다. 등록된 gate 수는 Phase 0의 31개보다 1개 많다. SKIP 20개는 그대로다.
- D4 합성 자료를 사용자가 제공한 경우에만 `test_production_validation.ps1`, `test_partial_save_phases.ps1`, `test_state_machine.ps1 -Case All`도 PASS다. 제공하지 않았으면 PR에 "미실행"으로 쓴다.
- 동일성: N=15, H=1/2/6에서 `AfterReloadIdentity PASS`다. 출력을 PR에 첨부한다.
- 계측: StateMachine 호출이 H+1이다. 해시 호출 합계와 JSON parse 호출이 `artifactCount` 이하다. 초과하면 실제 값과 이유를 PR에 쓴다.
- H=6 중앙값이 2.2초 이하다. 달성하지 못하면 실제 비율과 남은 병목을 PR에 쓴다.
- `docs/evidence/perf-phase1.json`의 contract SHA-256이 기준선과 다르다. 바뀐 파일 목록을 PR에 쓴다.
- CI가 녹색이다.

## 선택 작업 · 같은 PR의 별도 commit

- `.github/workflows/offline-regression.yaml`의 `push`를 `branches: [main]`으로 제한한다. PR commit이 두 번 실행되지 않는다.
- `pip install Pillow reportlab pypdf`에 버전을 고정한다. 현재 CI 로그의 설치 버전을 쓴다.

## PR

브랜치 `codex/phase-1`. base는 `main`이다. Phase 0가 `main`에 없으면 `codex/phase-0`에서 시작한다. 제목 `Phase 1: AfterReload 중복 검증 제거`. 추론 노력 `extra high`.
