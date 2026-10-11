# Phase 1b · PDF 검증 프로세스 통합과 append 재검사 공유

## 목표

H=6 AfterReload 중앙값이 2.2초 이하다. Phase 1의 호출 수 결과(StateMachine H+1, 경로별 해시 1회)는 그대로다. 검증 결과와 거부 메시지는 Phase 0과 같다. PDF 검증과 production 경계 검사를 생략하지 않는다.

## 기준선 · Phase 1 측정값

N=15, 3회 중앙값. 원시 값은 `docs/evidence/perf-phase1.json`에 있다. 진단 값은 `docs/evidence/perf-phase1-profile.json`에 있다.

| H | 시간(초) | StateMachine | PDF 검증(Python 프로세스) | `Test-MathSecrEditAppendReceipt` |
|---:|---:|---:|---:|---:|
| 1 | 0.930 | 2 | 1 | 2 |
| 2 | 1.177 | 3 | 2 | 4 |
| 6 | 2.857 | 7 | 6 | 12 |

남은 시간은 두 곳에 있다.

1. `Assert-FailedProblemReportPdf`가 세션마다 Python(pypdf) 프로세스를 한 번 띄운다. H=6에서 6회, 약 1.15초다. 비용의 대부분은 프로세스 시작과 `pypdf` import다.
2. `Test-MathSecrEditAppendReceipt`가 세션마다 2회 실행된다. state machine이 1회, production 최종 재검사가 1회다. H=6에서 12회, 약 1.0초다. 두 호출의 입력은 같다.

Phase 1b 목표값:

| H | 시간(초) | StateMachine | `pdfValidatorStarts` | `pdfChecks` | `appendReceiptValidations` |
|---:|---:|---:|---:|---:|---:|
| 1 | 보고 | 2 | ≤ 1 | 1 | 1 |
| 2 | 보고 | 3 | ≤ 1 | 2 | 2 |
| 6 | ≤ 2.2 | 7 | ≤ 1 | 6 | 6 |

`pdfValidatorStarts`는 최상위 호출 1회당 Python 프로세스 시작 수다. `pdfChecks`는 PDF 검사 수다. 세션마다 1회이므로 바뀌지 않는다. `appendReceiptValidations`는 실제로 실행한 append receipt 검증 수다. 호출 수는 2H로 그대로이고 실행 수가 H가 된다. 예상 시간은 약 1.6~2.0초다.

## 맥락

읽을 파일:

- `docs/codex/phase-1.md`, `docs/evidence/phase-1.md`. Phase 1의 설계와 측정이다.
- `mathsecr-paper-builder-kit/scripts/report_contract.ps1`
  - `:181-233` `Assert-FailedProblemReportPdf`. `:222`에서 `& python -c $pythonCode $Path $expectedNumbers 2>&1`를 실행한다. 종료 코드 2는 `pypdf` 없음, 3은 parse·marker 실패다. 실패 메시지는 `"Failed-problem report PDF validation failed: <stderr 전체>"`다.
  - `:634` `Invoke-MathSecrUserSummaryLint`. `:710`에서 PDF 검사를 부른다. `-Context` 인자가 없다.
- `mathsecr-paper-builder-kit/scripts/production_validation.ps1`
  - `:240` `Invoke-MathSecrProductionStep`. `:269` state machine 호출. `:281` 최종 append 재검사. `:287` summary lint 호출.
  - `:292-296` `Invoke-MathSecrTypedUserSummaryLint`. 독립 호출이다. Context가 없다.
- `mathsecr-paper-builder-kit/scripts/state_machine.ps1`
  - `:6` `$CONTRACT_VERSION`.
  - `:1184` `Test-MathSecrEditAppendReceipt`. `:1971`에서 state machine이 부른다. 성공하면 `SelectedIds`가 `$ExpectedIds`와 순서까지 같고 `SelectedOccurrenceKeys`가 `$ExpectedKeys`와 같다. 그래서 `production_validation.ps1:281`의 재검사는 같은 snapshot 객체에 같은 입력을 넣는다.
- `mathsecr-paper-builder-kit/scripts/read_contract_json.ps1`
  - `:48` `New-MathSecrValidationContext`, `:58` `Enter-MathSecrValidationContext`, `:74` `Exit-MathSecrValidationContext`, `:83` `Get-MathSecrValidationArtifact`.
- `scripts/perf/measure_after_reload.ps1:14`. proxy 대상 `$names`.
- `scripts/perf/compare_after_reload.ps1:64`. 동일성 사례 6종.
- `scripts/test_validation_context.ps1`. Phase 1 캐시 격리 시험.
- `scripts/perf/append_history_support.ps1:184-193`. 합성 세션의 실패 PDF를 만든다. 마지막 세션을 포함해 `selectedCount < ProblemCount`인 세션마다 `failure-<stage>.pdf`가 있다.

현재 상태:

- Context는 artifact 캐시와 state 캐시만 가진다. 프로세스 같은 자원을 넣을 자리가 없다.
- `Invoke-MathSecrUserSummaryLint`와 `Assert-FailedProblemReportPdf`는 Context를 모른다.
- 같은 snapshot 객체는 한 최상위 호출 안에서 참조가 같다. production 재귀와 state machine이 같은 artifact 캐시 항목의 `Value`를 쓰기 때문이다.

## 작업

1. 계측 준비를 먼저 한다.
   - `measure_after_reload.ps1:14`의 `$names`에 `Start-MathSecrPdfValidator`, `Invoke-MathSecrPdfValidatorOnce`, `Assert-FailedProblemReportPdf`, `Invoke-MathSecrEditAppendReceiptValidation`, `Test-MathSecrEditAppendReceipt`를 넣는다. 함수는 작업 2·3에서 만든다.
   - 출력 JSON에 `pdfValidatorStarts`, `pdfValidatorOneShots`, `pdfChecks`, `appendReceiptCalls`, `appendReceiptValidations`, `appendReceiptReuses`(= calls − validations)를 넣는다. 값은 반복별 샘플과 중앙값 둘 다 쓴다.
   - `test_append_history_fixture.ps1`의 H=2 계측 단정에 `pdfValidatorStarts -le 1`, `pdfValidatorOneShots -eq 0`, `appendReceiptValidations -eq 2`를 더한다. 기존 단정은 그대로 둔다.
2. PDF 검증 프로세스를 최상위 호출당 1개로 줄인다.
   - `report_contract.ps1`의 Python 코드를 한 프로그램 문자열로 합친다. 검증 함수 1개를 두 방식이 같이 쓴다. 인자가 `<path> <numbers>`면 지금처럼 한 번 검사하고 끝난다. 인자가 `--serve`면 표준 입력에서 JSON 한 줄 `{"path":"...","expected":[6,8,9]}`을 읽고 표준 출력에 JSON 한 줄 `{"ok":true,"message":"validated pages=... markers=..."}` 또는 `{"ok":false,"code":3,"message":"PDF parse/marker validation failed: ..."}`을 쓴다. EOF면 종료 코드 0으로 끝난다. `pypdf` import 실패는 두 방식 모두 지금과 같은 문장을 stderr에 쓰고 종료 코드 2로 끝난다. `strict=True`, marker 정규식, 메시지 문장은 바꾸지 않는다.
   - 표준 입출력은 UTF-8이다. Python은 `sys.stdin.reconfigure(encoding='utf-8')`, `sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)`를 쓴다. PowerShell은 `ProcessStartInfo`의 `StandardInputEncoding`, `StandardOutputEncoding`, `StandardErrorEncoding`을 `UTF8Encoding($false)`로 둔다. 경로에 한글이 있어도 같아야 한다. stderr는 `BeginErrorReadLine`으로 모은다. 동기 읽기 두 개를 섞지 않는다.
   - `Start-MathSecrPdfValidator -Context`를 만든다. `python -c <프로그램> --serve`를 시작한다. 프로세스 객체와 stderr 버퍼를 `$Context.Resources['pdf-validator']`에 넣는다. 정리 scriptblock을 `$Context.Disposers`에 넣는다. 정리는 표준 입력을 닫고 5초까지 기다린 뒤 남아 있으면 `Kill()`한다.
   - `Invoke-MathSecrPdfValidatorOnce -Path -FailedProblems`를 만든다. 지금의 `:217-232` 동작을 그대로 옮긴다. Context가 없거나 `ActiveDepth`가 0이면 이 함수를 쓴다. `Invoke-MathSecrTypedUserSummaryLint` 같은 독립 호출이 여기에 해당한다.
   - `Assert-FailedProblemReportPdf -Path -FailedProblems [-Context]`로 바꾼다. Context가 활성이면 worker가 없을 때 한 번 시작한다. 요청 한 줄을 쓰고 응답 한 줄을 읽는다. 읽기 제한은 120초다. `ok`가 `$false`면 `"Failed-problem report PDF validation failed: <message>"`를 throw한다. 한 번 실행 방식의 `$detail`과 같은 문자열이어야 한다. 프로세스가 끝났거나 응답이 비었거나 시간을 넘기면 `"Failed-problem report PDF validation failed: Python PDF validator exited with code <code>"`를 throw한다. 자동 재시작은 하지 않는다. 다음 최상위 호출이 새 worker를 만든다.
   - `read_contract_json.ps1`의 Context에 `Resources`(`Dictionary[string,object]`)와 `Disposers`(`List[scriptblock]`)를 더한다. `Exit`에서 `ActiveDepth`가 0이 되면 `Disposers`를 역순으로 실행한다. 각 실행은 `try/catch`로 감싼다. 실패해도 나머지를 실행한다. 그 뒤 `Resources`, `Disposers`, 캐시를 비운다. `Enter`도 `ActiveDepth`가 0이면 같은 정리를 먼저 한다. 정리 코드는 PDF를 모른다. `Register-MathSecrValidationResource -Context -Name -Value -Dispose {scriptblock}` 하나만 둔다.
   - 전달 경로: `Invoke-MathSecrProductionStep:287` → `Invoke-MathSecrUserSummaryLint -Context $Context` → `:710 Assert-FailedProblemReportPdf ... -Context $Context`. 다른 호출자는 바꾸지 않는다.
3. append receipt 재검사를 공유한다.
   - `Test-MathSecrEditAppendReceipt:1184`의 본문을 `Invoke-MathSecrEditAppendReceiptValidation`으로 옮긴다. 인자와 반환은 같다. 새 `Test-MathSecrEditAppendReceipt`는 얇은 wrapper다.
   - wrapper 규칙: Context가 활성이면 `$Context.AppendReceiptCache`를 본다. key는 `$Snapshot` 객체 참조다. `Dictionary[object,object]`를 `[Collections.Generic.ReferenceEqualityComparer]::Instance`로 만든다. 값은 항목 목록이다. 항목은 `{ProjectRoot, Depth, ExpectedIds, ExpectedKeys, Result}`다. `ProjectRoot`가 같고 `Depth`가 같고 `ExpectedIds`·`ExpectedKeys`가 `Test-OrderedIdsEqual`로 같으면 `Result`를 돌려준다. 아니면 검증을 실행한다. `Result.Valid`가 `$true`일 때만 저장한다. 거부 결과는 저장하지 않는다. 매번 다시 실행해서 오류 전파를 지킨다.
   - Context가 없으면 wrapper는 검증을 바로 실행한다.
   - `$CONTRACT_VERSION`을 `'2026-10-11.2'`로 올린다.
4. 메모리를 줄인다. 선택 작업이다.
   - `Get-MathSecrValidationArtifact`에서 `-Parse`가 없고 확장자가 `.json`이 아니면 해시 뒤 `Bytes`를 `$null`로 둔다. 뒤에 같은 key로 `-Parse` 요청이 오면 `Read-MathSecrArtifactBytes`로 다시 읽는다. 이 재읽기는 해시 1회로 센다. `maxHashCallsPerPath`가 1을 넘으면 그 경로의 바이트를 보관하는 쪽으로 되돌리고 PR에 쓴다.
5. 시험을 더한다.
   - `scripts/test_validation_context.ps1`에 다음을 추가한다. 마지막 줄 `ValidationContext PASS`는 그대로다.
     - 최상위 호출이 끝나면 worker가 없다. 호출 중에 `$Context.Resources['pdf-validator']`의 PID를 기록하고, 끝난 뒤 5초 안에 `Get-Process -Id`가 실패한다. 명시 Context를 재사용한 두 번째 호출은 새 PID다.
     - 실패 PDF 1개를 절반 길이로 자른다. Context가 있는 `Invoke-MathSecrProductionStep`과 Context가 없는 `Invoke-MathSecrUserSummaryLint`가 같은 `Exception.Message`로 거부한다. 원복 뒤 PASS다.
     - 명시 Context 안에서 worker를 `Kill()`한 뒤 PDF 검사를 부른다. 120초를 기다리지 않고 `"Failed-problem report PDF validation failed: "`로 시작하는 메시지로 실패한다. `Exit` 뒤 새 최상위 호출은 PASS다.
     - 명시 Context 안에서 같은 snapshot 객체와 같은 입력으로 `Test-MathSecrEditAppendReceipt`를 두 번 부른다. 두 결과가 같은 객체다. `Copy-MathSecrBenchmarkObject`로 복사한 snapshot은 캐시를 쓰지 않는다. 기대 ID 순서를 바꾼 호출도 캐시를 쓰지 않는다.
   - `scripts/perf/compare_after_reload.ps1:64`의 사례에 `pdf-truncated-latest`와 `pdf-truncated-earliest`를 더한다. `failureReportPdf`가 `없음`이 아닌 세션 중 마지막과 첫 세션의 PDF를 절반 길이로 자른다. 두 checkout이 모두 거부하고 메시지가 같아야 한다. 사례마다 원복한다. H=1/2/6에서 비교는 18개에서 24개가 된다.
6. 측정과 기록.
   - `write_perf_baseline.ps1 -Repeat 3 -OutPath ./docs/evidence/perf-phase1b.json`을 실행한다. `perf-baseline.json`, `perf-phase1.json`은 덮어쓰지 않는다.
   - `docs/evidence/phase-1b.md`와 `phase-1b-checks.json`을 만든다. 표의 열은 위 목표값 표와 같다. 기준선 열로 Phase 1 값을 둔다.
   - `SOURCE_SNAPSHOT.json`에서 바뀐 export 4개(`report_contract.ps1`, `read_contract_json.ps1`, `state_machine.ps1`, `production_validation.ps1`)의 해시·크기·transformation을 갱신한다. 원본 `sourceSha256`은 유지한다.
   - `docs/evidence/regression-inventory.md` 마지막 단락에 Phase 1b 한 줄을 더한다.

## 제약

- PDF 검증을 생략하거나 세션 사이에 결과를 재사용하지 않는다. 프로세스만 공유한다.
- worker는 Context 수명 안에서만 산다. `$script:`, `$global:` 변수에 두지 않는다. 최상위 호출이 끝나면 반드시 끝낸다.
- Context가 없는 호출은 지금과 같이 한 번 실행 방식으로 검사한다.
- Python 검증 함수, `strict=True`, 정규식, 오류 문장을 바꾸지 않는다. `create_failed_problem_report.py`를 바꾸지 않는다.
- append receipt 캐시는 `Valid=$true`만 저장한다. 거부는 매번 다시 실행한다.
- 기존 함수 이름과 반환 구조를 바꾸지 않는다. `-Context` 인자만 더한다. 작업 3의 본문 이동은 wrapper가 기존 이름을 유지하므로 허용한다.
- 기존 테스트 단정을 지우거나 약화하지 않는다.
- `state_machine.ps1`의 다른 계약 로직을 바꾸지 않는다.
- 생성 결과와 worktree는 임시 폴더에만 둔다.

## 완료 조건

```powershell
python ./scripts/validate_publication.py
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_public_checks.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/test_validation_context.ps1
pwsh -NoProfile -File ./scripts/perf/compare_after_reload.ps1 -BaselineRoot <961c411 worktree> -CandidateRoot .
pwsh -NoProfile -File ./scripts/perf/measure_after_reload.ps1 -ProblemCount 15 -HistoryDepth 6 -Repeat 3
```

- 공개 gate가 모두 PASS다. gate 수는 Phase 1과 같다. SKIP 20개는 그대로다.
- 동일성: 기준 commit은 Phase 0의 `961c41105e96f368c48f6a39303e15520e0b3213` 그대로다. N=15, H=1/2/6에서 24개 비교가 `AfterReloadIdentity PASS`다. 출력을 PR에 첨부한다.
- 계측: StateMachine이 H+1이다. 해시 합계와 JSON parse가 `artifactCount` 이하다. `maxHashCallsPerPath`가 1이다. `pdfValidatorStarts`가 1 이하다. `pdfValidatorOneShots`가 0이다. `pdfChecks`가 PDF 있는 세션 수와 같다. `appendReceiptValidations`가 H다.
- H=6 중앙값이 2.2초 이하다. 달성하지 못하면 PR을 draft로 두고 Issue #2에 실제 값과 남은 병목을 쓴다. 병합 여부는 사용자가 정한다.
- `test_validation_context.ps1`의 새 검사가 모두 PASS다. CI 실행 뒤 runner에 Python worker가 남지 않는다.
- `docs/evidence/perf-phase1b.json`의 contract SHA-256이 Phase 1과 다르다. 바뀐 파일 목록을 PR에 쓴다.
- CI가 녹색이다.

## PR

브랜치 `codex/phase-1b`. base는 `main`이다. Phase 1(PR #4)은 `main`에 있다. 제목 `Phase 1b: PDF 검증 프로세스 통합과 append 재검사 공유`. 추론 노력 `high`. 모호하면 구현 전에 Issue #2에 질문한다.
