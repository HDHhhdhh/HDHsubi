# Phase 1 · AfterReload 중복 검증 제거

Phase 1은 한 번의 최상위 검증에서 이미 확인한 artifact 바이트와 state 결과를 재사용한다. 최상위 호출이 끝나면 캐시를 비운다. 과거 파일의 `Valid` 값을 신뢰하지 않으며, 현재 호출에서 검증을 마친 결과만 저장한다.

## 측정 결과

N=15, H=1/2/6, 각 3회 실행의 중앙값이다. H는 과거 저장 세션 수다. 입력 생성과 정리는 시간에서 제외했다. 모듈을 준비한 뒤 함수 proxy를 포함한 AfterReload만 측정했다. 원래 [기준선 JSON](perf-baseline.json)은 보존했고 새 결과는 [perf-phase1.json](perf-phase1.json)에 저장했다.

| H | 기준선 초 | Phase 1 초 | ProductionStep | StateMachine | 해시 합계 | JSON parse | artifactCount | hashCallsPerArtifact |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1.430 | 0.930 | 2 | 2 | 42 | 12 | 46 | 0.913043 |
| 2 | 2.016 | 1.177 | 3 | 3 | 52 | 22 | 58 | 0.896552 |
| 6 | 8.664 | 2.857 | 7 | 7 | 92 | 62 | 106 | 0.867925 |

H=6은 기준선 시간의 33.0%이며 약 3.03배 빨라졌다. 목표인 2.2초는 달성하지 못했다. 호출 횟수 목표는 달성했다. StateMachine은 49회에서 7회, 해시는 2,049회에서 92회, JSON parse는 440회에서 62회로 줄었다. 모든 반복에서 `maxHashCallsPerPath=1`이다.

해시 합계는 `Get-FileHash`와 `Read-MathSecrArtifactBytes`의 호출을 더한다. 경로별 수는 최상위 호출마다 초기화한다. JSON의 경로별 집계는 반복 간 최대값이며 경로는 합성 입력 루트에 대한 상대 경로다. `artifactCount`는 fixture manifest와 보조 파일까지 포함한 최종 파일 수다. 모든 파일이 검증에 읽히는 것은 아니므로 경로별 최대 1회 단정도 함께 확인한다.

이 결과는 공개 합성 계약의 실행 시간이다. 과거 실제 제작에서 한 번 관측한 113.83초와 입력 및 계측 조건이 다르므로 직접 속도 비율을 계산하지 않는다.

### 남은 병목

H=6에서 주요 함수의 시간을 별도로 한 번 계측했다. production helper의 조기 오류 순서를 보정하기 전 [초기 구현 계측](perf-phase1-initial.json)을 대상으로 했으며, [진단 원시 수치](perf-phase1-profile.json)에 해당 코드의 해시를 남겼다. 추가 proxy 비용을 포함한 총시간은 3.477초다. 위 최종 중앙값과 직접 비교하지 않는다. 표의 시간은 해당 함수의 가장 바깥 호출들을 합한 값이다. 부모·자식 함수의 시간은 중첩되므로 행을 합산하지 않는다.

| 함수 | 호출 수 | 누적 시간 ms |
|---|---:|---:|
| StateMachine | 7 | 1541.490 |
| 실패 PDF 검증 | 6 | 1145.150 |
| EditAppendReceipt | 12 | 1018.682 |
| 구조 비교 | 바깥 138, 재귀 포함 29532 | 820.206 |
| SelectedSearchReceipt | 84 | 730.943 |
| artifact 읽기·해시 | 92 | 24.208 |
| JSON parse | 62 | 17.958 |

과거 부분저장 6단계의 PDF 검증은 각각 Python/pypdf를 실행한다. append receipt는 state 검사와 production 최종검사에 모두 필요하다. 남은 비용은 이 PDF 검사와 receipt·구조 비교에 집중된다. 재귀 비교 proxy 자체도 비용을 더하므로 정확한 비중으로 해석하지 않는다. 이 Phase에서 PDF 검증과 production 경계 검사를 생략하지 않았다.

## 변경과 호환성

- `read_contract_json.ps1`: 바이트를 한 번 읽어 SHA-256을 계산한다. BOM은 해시에 포함하고 JSON decode 전에만 제거한다. 기존 contract JSON reader로 숫자와 날짜 문자열의 표현을 보존한다.
- `production_validation.ps1`: 같은 Context를 하위 검증에 전달하고, 현재 검증이 만든 과거 StateResult를 캐시에 넣는다. 대상 조회에 번호별 인덱스를 사용한다.
- `state_machine.ps1`: 세션 해시·phase·계약 버전 키로 state 결과를 재사용한다. 캐시 결과의 이력 높이를 확인하여 최대 깊이 거부를 유지한다. 전체 객체의 JSON 직렬화 비교를 구조 비교로 바꾼다.
- `body_comparison_contract.ps1`: 같은 이미지의 해시를 Context에서 재사용한다. ProjectRoot를 생략하거나 빈 값으로 준 독립 호출의 조기 거부도 유지한다.

구조 비교는 정수 값이 같으면 내부 Int32/Int64 차이를 허용하되, boolean과 string, 속성 이름과 순서, 배열 순서, null과 빈 객체를 구분한다. 외부 반환의 숫자 형식은 아래 별도 비교로 확인한다. `$script:` 또는 `$global:`에 검증 Context를 저장하지 않는다.

`edit-append-artifact-changed` 오류 상수는 남겨 둔다. 이 오류는 원래 두 읽기 사이의 변경을 감지했다. 새 구현은 한 번 읽은 바이트를 해시하고 parse하므로 같은 읽기에서 이 오류는 발생하지 않는다. 다음 최상위 호출은 파일을 다시 읽고 검증한다.

## 검증 범위

공개 회귀는 12 PASS, 0 FAIL, 20 SKIP이다. D4 자료가 없으므로 기존 ProductionValidation, PartialSavePhases, StateMachine 전체 suite를 포함한 20개 private-bundle gate는 미실행이다. 새 시험은 원래 비공개 fixture를 복원하거나 대체한 것으로 주장하지 않는다.

`ValidationContext`는 호출 간 캐시 격리, 명시 Context 재사용, 파일 변조, 해시를 갱신한 잘못된 내용, 원복 후 성공, 같은 경로의 다른 기대 해시, 깊이 제한, BOM, 형식·순서를 검사한다. ProjectRoot를 생략하거나 빈 값으로 준 독립 호출 20개도 기존 조기 거부값과 오류 문자열을 유지한다.

`AfterReloadIdentity`는 Phase 0 commit `961c41105e96f368c48f6a39303e15520e0b3213`과 후보 checkout을 각각 새 `pwsh` 프로세스로 실행한다. 두 프로세스는 같은 실제 fixture 경로를 읽는다. N=15, H=1/2/6에서 다음 18개 비교가 모두 PASS다.

- 정상 결과 3개: 전체 JSON 문자열 및 CLR scalar 형식 목록 723/721/713개가 각각 같다. fixture 시각이 고정되어 있으므로 시각 필드도 제거하지 않고 비교한다.
- 거부 결과 15개: prior hash, confirm receipt 누락, rawVisibleDbName, PNG 바이트, 해시를 갱신한 잘못된 schema의 거부 메시지가 각각 같다.

Windows CI도 고정된 Phase 0 commit을 임시 worktree로 받아 동일성 비교를 실행한다. 실제 CI 성공은 PR의 해당 commit에 연결된 Actions 결과를 확인한다.

## 재현

Python 3.12, PowerShell 7 및 [공개 회귀 의존성](regression-inventory.md)을 준비한다. 아래 baseline 경로는 OS 임시 폴더의 별도 checkout을 사용한다.

```powershell
python ./scripts/validate_publication.py
pwsh -NoProfile -File ./scripts/run_public_checks.ps1
pwsh -NoProfile -File ./scripts/run_offline_regression.ps1
pwsh -NoProfile -File ./scripts/perf/compare_after_reload.ps1 -BaselineRoot <temporary-baseline-checkout> -CandidateRoot .
pwsh -NoProfile -File ./scripts/perf/write_perf_baseline.ps1 -Repeat 3 -OutPath <new-measurement.json>
```

기존 측정 파일을 덮어쓰지 않는다. 생성한 PNG/PDF/세션과 비교용 checkout은 임시 폴더에 두고 정리한다. SOURCE_SNAPSHOT의 원본 sourceSha256 72개는 보존하고 변경한 검증 모듈 4개의 export 해시·크기·transformation만 갱신했다. 새 공개 시험은 원본 export 목록에 넣지 않는다.
