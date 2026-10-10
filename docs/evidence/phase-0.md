# Phase 0 성능 기준선과 재현

Phase 0은 기존 production 코드를 바꾸지 않고 공개 회귀 실행기, Windows CI 및 합성 AfterReload 성능 입력을 추가한다. [회귀 inventory](regression-inventory.md)는 public 11개와 private-bundle 20개를 구분한다. 원래 private suite 전체 PASS를 주장하지 않는다.

로컬 실행 결과는 [phase-0-checks.json](phase-0-checks.json)에 있다. GitHub CI 성공 여부는 해당 PR commit의 Actions 실행에서 따로 확인한다.

첫 Windows CI에서는 날짜 자동 변환과 Python 출력 인코딩 차이로 3개 gate가 실패했다. 연도 테스트 2개를 기존 contract reader에 연결해 관측 시각의 원래 `+09:00` offset을 보존했다. fixture와 단정은 바꾸지 않았다. CI에는 `PYTHONUTF8=1`을 설정해 합성 PDF 검사의 한국어 출력도 UTF-8로 기록한다.

## 측정 결과

문항 수 N=15, 저장 이력 H=1/2/6에서 각각 3회 측정했다. 원시 반복 값, 중앙값, 환경과 계약 SHA-256은 [perf-baseline.json](perf-baseline.json)에 있다.

| H | 중앙값(초) | StateMachine 호출 | ProductionStep 호출 | Get-FileHash 호출 | Contract JSON parse 호출 |
|---:|---:|---:|---:|---:|---:|
| 1 | 1.430 | 4 | 2 | 194 | 25 |
| 2 | 2.016 | 9 | 3 | 425 | 68 |
| 6 | 8.664 | 49 | 7 | 2,049 | 440 |

StateMachine 호출은 모든 반복에서 `(H+1)^2`와 일치했다. [계획](../refactor-plan.md)의 H=6 예측 49회를 확인했다. 이 측정은 중복 호출 구조의 기준선이다. 역사적 live 관측 113.83초와 비교해서 속도 향상을 주장하지 않는다.

측정한 PC의 OS는 Windows build 26200, PowerShell은 7.6.5, CPU는 Intel Core Ultra 9 285K다. 파일 시스템은 NTFS다. 관측한 물리 디스크의 모델·종류는 JSON에 있다. 이는 현재 PC의 측정 환경이며 CI runner의 성능은 아니다.

## 입력과 계측 범위

생성기는 고정 source roster N개와 H+1개 session을 만든다. 첫 session은 N-H개를 선택한다. 각 append는 새 문항 한 개를 추가한다. 최종 선택 수는 N이다. 따라서 `N > H`, `0 <= H <= 63`이어야 한다. 최초 FirstNext bundle은 끝까지 보존한다.

H=0에는 append receipt가 없다. 중간 부분 저장은 미실행 row를 `not-started`로 보존하고 실패 crop PDF를 만든다. 각 append는 prior session hash, 추가·확인 action, 실행 binding, 전후 관측과 새 persisted read identity를 가진다. 최종 session을 unchanged AfterReload로 검증하면 prior production 단계도 재검증된다.

PNG는 서로 다른 색의 합성 16×16 이미지다. 본문 판정, control 이름, 실행 marker, 시각은 합성 시험 값이다. 브라우저를 조작하거나 실제 시험지를 읽지 않는다. 이는 receipt 구조와 artifact identity 검증만 검사한다.

생성 및 최초 비계측 검증으로 모듈을 예열한다. 이후 AfterReload 호출만 측정한다. fixture 생성, 모듈 로드, proxy 설치 및 cleanup 시간은 제외한다. 네 함수의 parameter metadata를 보존하는 proxy가 재귀 호출을 센다. proxy 비용은 경과 시간에 포함한다. 계측 후 원래 함수로 복원하고 임시 폴더를 제거한다.

## 재현 명령

Python 3.12와 Pillow/reportlab/pypdf, Windows PowerShell 7이 필요하다.

```powershell
$env:PYTHONUTF8 = '1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-manual-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File ./scripts/perf/new_append_history_fixture.ps1 -ProblemCount 15 -HistoryDepth 6 -OutRoot $fixture
pwsh -NoProfile -File ./scripts/perf/measure_after_reload.ps1 -ProblemCount 15 -HistoryDepth 6 -Repeat 3
```

`new_append_history_fixture.ps1`는 사용자가 지정한 임시 폴더의 입력을 남긴다. 출력은 absent 또는 empty 폴더에만 쓴다. 저장소, OS temp 밖 경로, reparse point 및 기존 artifact 덮어쓰기는 거부한다. `measure_after_reload.ps1`는 자체 GUID 임시 폴더만 만들고 제거한다.

전체 행렬을 새 파일로 기록하려면 다음을 실행한다. 기존 baseline을 덮어쓰지 않는다.

```powershell
pwsh -NoProfile -File ./scripts/perf/write_perf_baseline.ps1 -Repeat 3 -OutPath <new-json-path>
```

CI는 모든 public gate와 작은 H=0/1/2 양성·변조 거부·proxy 호출 수 시험을 실행한다. N=15 성능 행렬은 PC에서 따로 측정한다. CI에 시간 임계값을 넣지 않는다.
