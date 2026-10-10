# 선택 증거 조립

`scripts/prepare_selection_evidence.ps1`는 실제 검색·본문 비교를 마친 뒤 기존 target JSON을 한 번에 조립·검증한다. 특정 PDF 번호, 문제지 URL, 세션 디렉터리를 내장하지 않는다. 브라우저 조작과 시각 판정 기능은 없다.

```powershell
& ./mathsecr-paper-builder-kit/scripts/prepare_selection_evidence.ps1 `
  -ProjectRoot $projectRoot `
  -InputPath '.omo/evidence/current-run/target-input.json' `
  -OutPath '.omo/evidence/current-run/target-prepared.json'
```

입력은 기존 계약 형식의 target 객체다. `number`, `occurrenceKey`, `selectedId`, `searchAttemptReceipt`, `bodyComparisonReceipt`가 필요하다. `number`도 문자열이다. 원본/후보 렌더는 ProjectRoot 내부의 실제 파일을 가리키는 상대 경로여야 한다.

`bodyComparisonReceipt`에는 기존 계약의 원본 번호·occurrence·후보 ID·attempt ID, `policyVersion`, 명시적 `verdict`, 7개 실제 비교값, 실제 비교자/UTC, `unresolvedGlyphs`, 양쪽 렌더 경로/배율을 모두 제공한다. `sourceRenderSha256`, `candidateRenderSha256`, target의 `sourceBodyArtifact`만 생략할 수 있다. helper가 실제 파일에서 계산하며, 이미 주어진 값이 다르면 거부한다. 비교값이 같아 보여도 verdict나 비교 시각을 자동 생성하지 않는다.

`searchAttemptReceipt`는 기존 완전한 packet 형식을 사용한다. raw capture, 실제 제출·제거 이벤트, literal 단서, `exactFound`, `inspectedIds`, attempt별 `exactMatchIds`를 직접 제공해야 한다. helper는 검증기로 산출할 수 있는 `freshResultVerified`와 packet의 집계 필드 6개만 메모리에서 다시 계산한다. exact/inspection 판정이나 원시 관측은 바꾸지 않는다. 입력 파일은 보존된다.

기존 `Test-MathSecrSearchAttemptContract`, `Test-MathSecrSelectedSearchReceipt`, `Test-MathSecrBodyComparisonReceipt`를 통과한 target만 출력한다. `preparation.searchObservation`은 기존 검증기의 Projection이며 별도로 만든 freshness/본문 판정이 아니다. mismatch, 잘못된 binding, 없는 파일, 해시 충돌 등은 출력 전에 실패한다. 출력 디렉터리는 먼저 존재해야 하며 기존 파일 덮어쓰기를 지원하지 않는다. JSON 경로도 ProjectRoot 내부로 제한하고 경로 중 reparse point를 거부한다.

ordinary initial/candidate-recovery/whole-db 검색만 지원한다. metadata-rescue와 전체 문제지 상태·저장·재로드 검증은 기존 경로를 사용한다. 완성된 snapshot은 계속 `validate_selection_snapshot.ps1`로 검증해야 한다. 이 helper의 PASS는 receipt 구조와 파일 identity만 확인하며, 수학적 정답·독립 시각 oracle·live 선택 완료를 증명하지 않는다.

Focused test: `scripts/test_prepare_selection_evidence.ps1`. 합성 관측과 실제 PNG 파일을 사용하는 offline-contract 테스트이며 live 브라우저를 열지 않는다.
