# 검색 준비와 선택 증거 도구

행동 기준은 kit SKILL의 Search Attempt Contract / Body-Exact Selection Contract다. 이 문서는 실행 인터페이스를 설명한다. 실제 웹 검색의 속도나 정확도 향상 수치는 별도 비교 실험으로 측정한다.

## 원문 검색어 준비

`scripts/search_query_plan.ps1 -InputPath source-query-input.json -OutPath query-plan.json`을 실행한다. JSON의 targets 배열을 원본 순서로 유지하고 각 행에 sourceProblemNumber, occurrenceKey, sourceBodyText, proposedChips를 제공한다. proposedChips는 `{value, provenance:"literal-body"}` 두 개다. recoveryHints에는 printedMetadata, candidateIds, sourcePaperSelectors 배열을 둔다. 자세한 예제는 `docs/search_query_plan.md`를 따른다.

도구가 입력 전사를 기준으로 단어 위치와 정규화를 재검산한 뒤 `ready`/`blocked`를 반환한다. OCR을 수행하거나 원문에 없는 의미 단어를 만들어 넣지 않는다. `inputTarget`과 전사 해시는 계획의 재검산용이지 PDF 원본의 정확한 전사를 보증하는 자료가 아니다.

## 화면 정보 수집

`scripts/search_observation.js`의 collector 함수와 실제 판독으로 확인한 selector adapter를 IAB의 read-only evaluate에 전달한다. JS 파일이 별도 Chrome을 열거나 MathSecr API를 호출하지 않는다. 제출 전 한 번과 `검색하기` 동작 후 실제 독립 판독들을 수집한다. 각 readEvidenceId는 해당 도구 판독을 가리킨다. control map 또는 route가 바뀌면 adapter를 재확인한다.

`Test-MathSecrSearchObservation -Packet $receipt -AttemptId $attempt.attemptId -Chips $chipValues -ResultCount $attempt.resultCount`가 raw 판독을 검증한다. 정상 판독 2회/위험 판독 3회와 기존 final-miss coverage 규칙은 유지된다. `ConvertTo-MathSecrSearchObservationReportProjection`의 출력은 같은 검증 결과에서 파생되므로 보고서 작성을 위해 화면을 다시 읽을 필요가 없다. Selector adapter와 정확한 observation schema는 `docs/search_observation_contract.md`를 따른다. JSON을 직접 읽을 때는 `scripts/read_contract_json.ps1`의 `ConvertFrom-MathSecrContractJson`을 사용해 PowerShell 버전에 관계없이 UTC timestamp를 문자열로 보존한다.

원시 receipt를 search attempt의 `observationReceipt`에 저장한다. exact-producing attempt에는 `inspectedIds`와 그 부분집합인 `exactMatchIds`도 기록한다. 전체 후보를 다 보지 않아도 유효한 literal ladder와 실제 비교 후보가 있으면 early exact를 선택할 수 있다. 기존 frozen packets는 읽을 수 있지만 일반 선택 경로에 observation receipt 없이 사용할 수 없다.

## 본문 비교와 선택

실제 비교가 끝난 target JSON은 `scripts/prepare_selection_evidence.ps1 -InputPath raw-target.json -OutPath prepared-target.json`으로 한 번에 조립·검증한다. 실제 이미지 SHA와 검증 결과를 재계산하고 보고용 Projection을 함께 만든다. 원시 관측·비교 판정·ID·시각은 입력에 있어야 하며 자동으로 생성하지 않는다. 일반 text-search 선택에 사용하는 도구이고 metadata-rescue와 전체 저장 검증은 기존 경로를 유지한다. 입력 형식과 제한은 `docs/selection_evidence_preparation.md`를 따른다.

원본을 읽을 때 target에 `sourceBodyArtifact: {path, sha256}`를 기록한다. path는 ProjectRoot 상대 경로다. 비교 뒤 같은 target에 다음 `bodyComparisonReceipt`를 추가한다.

```json
{
  "sourceProblemNumber": "1", "occurrenceKey": "source-a:page1:q1",
  "candidateId": "실제로 관측하고 비교한 ID", "searchAttemptId": "실제 검색 attempt ID",
  "policyVersion": "body-only-v1", "verdict": "exact",
  "sourceRenderArtifact": "원본 crop 상대 경로", "sourceRenderSha256": "실제 SHA-256",
  "candidateRenderArtifact": "후보 crop 상대 경로", "candidateRenderSha256": "실제 SHA-256",
  "sourceRenderScale": 2, "candidateRenderScale": 2,
  "comparison": {
    "bodyText": "match", "conditions": "match", "formulas": "match",
    "figures": "not-present", "pointLabels": "not-present",
    "requiredValue": "match", "internalStatements": "not-present"
  },
  "comparedBy": "실제 비교자 또는 작업자 식별자",
  "comparedAtUtc": "2026-09-05T11:00:00.000Z", "unresolvedGlyphs": false
}
```

위 예시는 입력 모양일 뿐 유효한 증거가 아니다. 실제 비교에 따라 match/not-present를 기록한다. 본문/요구값은 match가 필수다. 한 요소라도 mismatch 또는 unresolved이면 exact로 제출하지 않는다. 객관식 선지는 비교 요소에서 제외한다. 같은 원본/후보 파일 경로 재사용, 잘못된 해시, 다른 원본 위치/후보/검색 ID 결합은 거부된다.

일반 선택은 target의 `searchAttemptReceipt`를 재검산하고 해당 attempt의 관측·검토·exact 후보 ID와 `selectedId`를 결합한다. Metadata early exact는 기존 metadata rescue validator를 먼저 통과하고 선택 후보를 포함한 bucket의 관측 receipt와 `searchAttemptId:"metadata-rescue"`를 사용한다. 미발견 전체 coverage를 early exact의 선행 조건으로 요구하지 않는다.

`scripts/validate_selection_snapshot.ps1 -InputPath snapshot.json -OutPath validated-state.json`으로 전체 선택/편집/저장 snapshot을 검증한다. 실패 시 exit 1과 상태/오류를 반환한다. REPORT 결과의 `SelectionEvidence`는 검증한 본문 binding과 동일 검색 관측 Projection을 담으므로 내부 보고서에 재사용한다. 기존 최종 persisted count/order 확인과 사용자용 0–4 출력 검사는 계속 적용한다.

이 도구들은 기록의 구조와 파일 identity를 검증한다. 해시는 본문 일치의 수학적 증명이 아니며 독립 ground-truth 평가로 승격하지 않는다. 실제 비교 정확도·검색 recall·속도는 별도 실측이 필요하다.
