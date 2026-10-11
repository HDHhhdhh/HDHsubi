# 검색 관측·attempt 사실 입력

[assemble_target.ps1](../mathsecr-paper-builder-kit/scripts/assemble_target.ps1)의 ObservationPath는 UTF-8 JSON이다. 수집기 관측과 에이전트가 기록한 attempt 사실을 받는다. 조립기는 관측·클릭·판정·시각을 만들지 않는다.

## 필수 구조

| 위치 | 필수 키와 형식 |
|---|---|
| 루트 | schemaVersion: 정수 1; literalEvidence: 객체; candidateRecoveryEvidence: 객체; attempts: 비어 있지 않은 배열 |
| literalEvidence | body, printedMetadata, visibleUiMetadata, formula: 문자열 배열. 해당 종류의 실제 입력 단서를 기록한다. 빈 배열은 허용한다. |
| candidateRecoveryEvidence | routes, coverage를 포함한 기존 검색 계약 객체. initial-scope exact에서는 빈 배열을 사용할 수 있다. |
| attempt | attemptId, scope, phase: 문자열; chips: 비어 있지 않은 배열; resetBefore: bool; clearReceipt: 문자열; removedChips: 배열; submission, beforeSubmit: 객체; observations: 비어 있지 않은 배열 |
| chips 원소 | value, provenance, evidenceReceipt 및 기존 계약이 요구하는 추가 receipt |
| removedChips 원소 | value, removalReceipt: 실제 제거 사실을 나타내는 문자열 |

attemptId는 서로 달라야 한다. phase는 initial, refinement, backoff다. winning attempt는 [본문 판정](body_judgment_input.md)의 searchAttemptId가 가리키는 정확히 한 행이다. Phase 2는 그 행의 scope가 initial-scope인 경우만 지원한다. 다른 winning scope는 `assembly-scope-unsupported:<scope>`로 거부한다. candidate-recovery·whole-db의 이전 miss 사실 입력은 후속 범위다.

chips 객체는 모든 키를 복사한다. formulaCommitReceipt와 indexEvidenceReceipt를 포함한 증거를 삭제하지 않는다. 유효성·단서 출처·검색 단계 순서는 [기존 검색 계약](../mathsecr-paper-builder-kit/scripts/search_attempt_contract.ps1)이 검사한다.

## 관측 packet 결합

submission은 에이전트가 실제 제출 행동에서 기록한 receipt다. submitId, actionEvidenceId, action, surface, completedAtUtc, url, criteria, resultCriteriaKey가 필요하다. beforeSubmit과 observations 원소는 [수집기](../mathsecr-paper-builder-kit/scripts/search_observation.js)의 출력 그대로다. 하나의 수집기 호출은 관측 하나다. 독립 판독 수, capture/read identity, 시각 순서, criteria, ordered IDs와 freshness는 [관측 계약](../mathsecr-paper-builder-kit/scripts/search_observation_contract.ps1)이 검증한다.

조립기는 각 attempt에서 schemaVersion=1, attemptId, submission, beforeSubmit, observations를 묶어 observationReceipt를 만든다. 내부 raw 값과 identity를 수정하지 않는다. 실제 운영 제출은 aside-repl과 실제 paper URL을 유지한다. simulator 제출은 offline-dom-test와 file URL을 유지하며 현재 선택 계약에서 거부된다.

[control map schema](../mathsecr-paper-builder-kit/test-fixtures/control-map/schema.json)는 draft 2020-12다. simulator map은 기존 adapter descriptor와 동일하다. mathsecr-current.json은 관측하지 않은 템플릿이며 selector와 observedAtUtc가 null이다. collector가 이 템플릿으로 판독하는 것을 거부한다. 실제 selector는 연구 R2가 채운다.

## 입력과 계산 값

| 값 | 공급·계산 방식 |
|---|---|
| attempt scope/phase, chips provenance/receipt, reset/clear/removal 사실 | 입력 그대로 |
| 제출·판독 receipt, capture/read identity, 시각, URL | 입력 그대로 |
| target number, occurrenceKey, sourceBodyArtifact | 고정 roster 행에서 결합. 원본 해시와 바이트 재검사 |
| targetBinding | 고정 roster에서 계산 |
| submitted | 실제 submission 존재 여부 |
| resultCount, inspectedIds | 마지막 observation의 raw.result.count와 orderedIds |
| freshResultVerified | Test-MathSecrSearchObservation 반환 |
| winning exactFound | 명시된 exact 본문 판정이 귀속된 attempt만 true |
| 나머지 exactFound/exactMatchIds | false/빈 배열. 다른 attempt로 판정을 복제하지 않음 |
| winning exactMatchIds | 판정의 candidateId가 해당 inspectedIds에 있을 때만 원소 1개 |
| outcome, initial, selectedId | 입력 판정의 verdict와 candidateId |
| 파생 필드 6개 | Test-MathSecrSearchAttemptContract 반환으로 계산 후 재검증 |
| render 해시, preparation 입력 해시 | 실제 파일 바이트 |

입력의 선택적 resultCount 캐시는 authoritative 값이 아니다. 루트에서는 winning attempt의 마지막 관측 수, attempt에서는 해당 마지막 관측 수와 비교한다. 다른 값이나 잘못된 형식이면 `observation-rejected:<attemptId>`로 거부한다. 같아도 출력은 관측에서 다시 계산한다.

파생 필드 6개는 commonChips, exactMatchIds, literalOnlyLadderCompleted, resetBackoffPerformed, candidateRecoveryCompleted, completeCoverageVerified다. 최초 계약 호출의 SchemaValid를 확인한 뒤 값을 채우고 두 번째 호출에서 exact-found와 오류 없음까지 확인한다. 결과 수나 ID의 일치만으로 exact 판정을 만들지 않는다.

## 출력과 파일 규칙

RosterPath, ObservationPath, BodyJudgmentPath, OutPath는 ProjectRoot 내부 JSON 파일이다. CandidateRenderPath는 내부 PNG 파일이다. roster의 sourceBodyArtifact는 기존 계약이 허용하는 상대 이미지 경로다. 경로의 alternate data stream과 reparse point를 거부한다. OutPath의 부모가 있어야 하며 기존 파일은 덮어쓰지 않는다.

성공은 종료 코드 0, assembled=true와 path, resolution을 포함한 JSON 한 줄이다. 거부는 종료 코드 1, assembled=false와 reason을 포함한 JSON 한 줄이며 target 파일을 만들지 않는다. 최종 선택·본문 계약도 통과해야 쓴다.

preparation.helperVersion은 assemble-target-v1이다. inputs의 roster, observation, judgment, candidateRender는 파일 바이트의 소문자 SHA-256이다. inputSha256은 순서가 고정된 아래 네 줄과 마지막 LF의 UTF-8 SHA-256이다. 경로 이름을 해시에 넣지 않는다.

    roster:<sha>
    observation:<sha>
    judgment:<sha>
    candidateRender:<sha>

truthScope는 receipt-structure-and-artifact-identity-only다. searchObservation은 기존 검증기의 Projection이다. 이것은 수학적·시각적 판정의 독립 증거가 아니다.

재현용 완전한 합성 입력은 [AssemblePipeline 시험](../mathsecr-paper-builder-kit/scripts/test_assemble_pipeline.ps1)이 OS 임시 폴더에 만든다. 이전 비공개 fixture를 대체했다고 주장하지 않는다.
