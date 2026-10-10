# Phase 0 · 공개본 회귀 실행 가능화·CI·성능 기준선

## 목표

클린 clone에서 오프라인 회귀가 실행된다. GitHub Actions CI가 녹색이다. AfterReload 성능 기준선이 `docs/evidence/perf-baseline.json`에 기록된다.

## 맥락

읽을 파일:

- `docs/refactor-plan.md` 2절, 3.4절, Phase 0 절.
- `mathsecr-paper-builder-kit/scripts/run_mathsecr_regression.ps1` 전체. 특히 `:276-358`의 gate 목록.
- `scripts/run_public_checks.ps1`, `scripts/validate_publication.py`. 허용 확장자와 루트 파일 규칙이 여기 있다.
- `mathsecr-paper-builder-kit/scripts/production_validation.ps1` `:200-245`. 벤치 대상 함수 `Invoke-MathSecrProductionStep`.
- `mathsecr-paper-builder-kit/scripts/state_machine.ps1` `:1066-1226`. `editAppendReceipt` 입력 schema. 벤치 입력 생성기가 이 schema를 만족해야 한다.
- `mathsecr-paper-builder-kit/docs/production_validation.md`. 세션·capture·append receipt JSON 예시.
- `mathsecr-paper-builder-kit/scripts/test_production_validation.ps1`. 합성 세션을 만드는 기존 helper가 있으면 재사용한다.

현재 상태:

- 공개본에는 `test-fixtures/body-comparison/synthetic_selection_test_support.ps1`, `test-fixtures/lessons/`, `test-fixtures/evaluation/`, `test-fixtures/docs/` 등 참조 fixture가 없다. 따라서 `run_mathsecr_regression.ps1`의 대부분 gate가 실패한다.
- 사용자가 로컬 비공개 bundle에서 합성 파일을 제공할 수 있다. 개인 자료는 받지 않는다.

## 작업

1. 각 테스트 스크립트가 필요로 하는 fixture 경로를 표로 만든다. 열은 `테스트`, `필요 경로`, `공개 가능 여부`, `등급(public|private-bundle)`이다. 표를 `docs/evidence/regression-inventory.md`에 저장한다. 공개 가능 여부가 불명확하면 Issue #1에 질문한다.
2. 사용자가 제공한 합성 파일을 추가한다. 추가한 파일은 `SOURCE_SNAPSHOT.json`의 규칙에 맞게 처리한다. 해시 기록이 필요하면 `validate_publication.py`가 PASS하도록 갱신한다.
3. `scripts/run_offline_regression.ps1`를 만든다. `public` 등급만 실행한다. 각 gate의 PASS/FAIL과 시간을 JSON 한 줄로 출력한다. 하나라도 FAIL이면 종료 코드 1이다. 기존 `run_mathsecr_regression.ps1`는 수정하지 않는다.
4. `.github/workflows/offline-regression.yaml`을 만든다. runner는 `windows-latest`다. 단계는 Python 설치, `pip install Pillow reportlab pypdf`, `validate_publication.py`, `run_public_checks.ps1`, `run_offline_regression.ps1`이다. 확장자는 반드시 `.yaml`이다. `.yml`은 publication 검사가 거부한다. `validate_publication.py`의 `FORBIDDEN_PARTS`나 루트 규칙이 `.github` 폴더를 막으면 그 규칙에 `.github`을 허용하는 최소 변경을 한다.
5. `scripts/perf/new_append_history_fixture.ps1`를 만든다. 인자는 `-ProblemCount N`, `-HistoryDepth H`, `-OutRoot <임시 폴더>`다. 출력은 session JSON 묶음, roster, 원본 crop PNG(합성 바이트), persisted capture, append receipt 체인, action/execution artifact다. H=0이면 append receipt가 없다. 생성 결과는 `Invoke-MathSecrProductionStep -Step AfterReload`를 PASS해야 한다.
6. `scripts/perf/measure_after_reload.ps1`를 만든다. 인자는 `-ProblemCount`, `-HistoryDepth`, `-Repeat`다. 측정은 총 경과 시간과 함수 호출 수다. 호출 수는 `Invoke-MathSecrStateMachine`, `Get-FileHash`, `ConvertFrom-MathSecrContractJson`, `Invoke-MathSecrProductionStep`이다. 호출 수 계측은 함수를 감싸는 프록시 함수로 한다. 계약 코드 본문은 바꾸지 않는다.
7. N=15, H=1/2/6을 각 3회 측정한다. 중앙값을 `docs/evidence/perf-baseline.json`에 기록한다. 환경(OS, PS 버전, CPU, 저장 장치)을 함께 쓴다.

## 제약

- 기존 테스트 단정을 지우지 않는다. 실패하는 private-bundle 테스트는 skip 표시를 하고 이유를 남긴다.
- 개인 시험지, 실제 문제지 URL, 계정, 원시 세션을 커밋하지 않는다.
- 벤치 입력은 임시 폴더에만 만든다. 저장소에 생성 결과를 커밋하지 않는다.
- 새 파일 확장자는 `.ps1 .py .js .md .yaml .json .html`만 쓴다.

## 완료 조건

```powershell
python ./scripts/validate_publication.py          # PASS
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_public_checks.ps1   # PASS
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1   # 모든 public gate PASS
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/perf/measure_after_reload.ps1 -ProblemCount 15 -HistoryDepth 6 -Repeat 3
```

- CI가 녹색이다.
- `docs/evidence/perf-baseline.json`에 H=1/2/6의 시간과 호출 수가 있다. H=6의 state machine 호출 수가 `docs/refactor-plan.md` 3.1절의 공식과 일치하는지 PR에 쓴다. 다르면 실제 값과 이유를 쓴다.
- PR 본문에 `regression-inventory.md`의 등급별 개수를 쓴다.

## PR

브랜치 `codex/phase-0`. 제목 `Phase 0: 공개본 회귀·CI·성능 기준선`.
