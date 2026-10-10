# Phase 2 · 관측 어댑터·조립 자동화·상주 검증

## 목표

문항 1개의 검색 관측에서 Select 입력까지 스크립트 한 번으로 만든다. 에이전트는 본문 판정만 입력한다. 검증기는 프로세스를 다시 시작하지 않는다.

## 맥락

읽을 파일:

- `docs/refactor-plan.md` 3.2절, Phase 2 절.
- `mathsecr-paper-builder-kit/scripts/search_observation.js`. adapter descriptor와 context를 받아 한 번의 관측을 만든다. 머리말에 "live defaults 없음"이 있다.
- `mathsecr-paper-builder-kit/scripts/search_observation_contract.ps1`. 관측 receipt 검증과 `Projection`.
- `mathsecr-paper-builder-kit/scripts/prepare_selection_evidence.ps1`, `test_prepare_selection_evidence.ps1`. 기존 조립 helper와 그 테스트.
- `mathsecr-paper-builder-kit/scripts/body_comparison_contract.ps1`. `bodyComparisonReceipt`의 필수 필드.
- `mathsecr-paper-builder-kit/scripts/validate_production_step.ps1`. 현재 CLI. 호출마다 `production_validation.ps1`를 dot-source한다.
- `mathsecr-paper-builder-kit/docs/search_preparation_and_selection_evidence.md`, `docs/selection_evidence_preparation.md`, `docs/search_observation_contract.md`.
- `mathsecr-paper-builder-kit/test-fixtures/iab-simulator/index.html`. 로컬 simulator DOM.
- `mathsecr-paper-builder-kit/test-fixtures/search-observation/simulator-adapter.json`. simulator용 adapter 예시.
- `mathsecr-paper-builder-kit/skills/mathsecr-paper-builder/SKILL.md` Browser 안정화 2항. control map을 세션마다 관측해 만든다고 돼 있다.

## 작업

1. control map 파일 schema를 정한다. 경로는 `mathsecr-paper-builder-kit/test-fixtures/control-map/`이다. 파일은 `schema.json`(JSON Schema), `simulator.json`(simulator용 실제 값), `mathsecr-current.json`(실제 서비스용, 이 PR에서는 selector를 비운 템플릿)이다. 내용은 `search_observation.js`의 adapter descriptor 전체와 `controlMapVersion`, `observedAtUtc`, `surface`, `pageKind`다. 실제 selector는 [연구 과제 R2](research-tasks.md)에서 채운다.
2. `mathsecr-paper-builder-kit/scripts/assemble_target.ps1`를 만든다.
   - 입력: `-RosterPath`, `-OccurrenceKey`, `-ObservationPath`(검색 제출 receipt와 독립 판독 배열이 든 JSON), `-BodyJudgmentPath`(에이전트가 쓴 판정 JSON), `-CandidateRenderPath`, `-ProjectRoot`, `-OutPath`.
   - 출력: `session.snapshot.targets[i]`에 넣을 target JSON. `searchAttemptReceipt`, `observationReceipt`, `bodyComparisonReceipt`, `sourceBodyArtifact`, `selectedId`를 채운다. 해시, 파생 필드, `inspectedIds`, `exactMatchIds`는 자동 계산한다.
   - 기존 `prepare_selection_evidence.ps1`의 검증 로직을 재사용한다. 기존 스크립트는 새 스크립트를 호출하는 얇은 래퍼로 남긴다. 기존 테스트는 그대로 PASS해야 한다.
3. 본문 판정 입력 schema를 `docs/body_judgment_input.md`에 정의한다. 필수 필드는 `comparator`, `comparedAtUtc`, `policy='body-only-v1'`, 항목별 판정(본문, 조건, 수식, 도형·그래프·표, 점 이름, 요구값, 본문 내 보기), `zoomFactor`, `unresolvedGlyph`다. 기본값은 없다. 비어 있거나 누락이면 거부한다. 조립기는 `exact`를 추론하지 않는다. 항목 중 하나라도 mismatch이면 target은 선택 불가 상태로 만든다.
4. `mathsecr-paper-builder-kit/scripts/validate_production_session.ps1`를 만든다. 모듈을 한 번 로드한다. 표준 입력에서 JSON 한 줄씩 읽는다. 명령은 `{"step":"Select|BeforeNext|AfterReload","inputPath":"...","outPath":"...","targetOccurrenceKey":"..."}`다. 응답은 `validate_production_step.ps1`와 같은 JSON 한 줄이다. `{"step":"exit"}`로 끝난다. 경로 안전 규칙은 기존 CLI와 같다. 기존 CLI는 바꾸지 않는다.
5. end-to-end 합성 테스트 `test_assemble_pipeline.ps1`를 만든다. simulator DOM에서 `search_observation.js`로 관측을 만든다. 관측과 합성 판정으로 `assemble_target.ps1`를 돌린다. 결과 target을 세션에 넣고 상주 모드로 Select와 BeforeNext를 PASS시킨다. 판정 JSON에서 `comparator`를 빼면 조립이 거부되는 음성 사례를 넣는다.
6. 상주 모드와 CLI의 Select 47회 시간을 비교해 PR에 쓴다.
7. `run_offline_regression.ps1`에 새 테스트를 `public` 등급으로 추가한다.

## 제약

- 판정·관측·클릭·시각을 자동으로 채우지 않는다. 조립과 해시만 자동이다.
- 실제 수학비서에 접속하는 테스트를 만들지 않는다.
- SKILL.md는 이 PR에서 바꾸지 않는다. 변경 제안은 PR 본문에 적는다. Phase 4에서 반영한다.
- 기존 함수 이름과 반환 구조를 유지한다.

## 완료 조건

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./mathsecr-paper-builder-kit/scripts/test_assemble_pipeline.ps1 -ProjectRoot .
pwsh -NoProfile -ExecutionPolicy Bypass -File ./mathsecr-paper-builder-kit/scripts/test_prepare_selection_evidence.ps1 -ProjectRoot .
```

- end-to-end 합성 테스트가 PASS다. 자동 채움 거부 음성 사례가 거부된다.
- 기존 `test_prepare_selection_evidence.ps1`가 PASS다.
- PR 본문에 상주 모드 대 CLI 시간이 있다.
- CI가 녹색이다.

## PR

브랜치 `codex/phase-2`. 제목 `Phase 2: 관측 어댑터·조립 자동화·상주 검증`. 추론 노력 `high`.
