# 본문 판정 입력

[assemble_target.ps1](../mathsecr-paper-builder-kit/scripts/assemble_target.ps1)의 BodyJudgmentPath는 UTF-8 JSON이다. 에이전트가 비교한 결과를 입력한다. [draft 2020-12 schema](../mathsecr-paper-builder-kit/test-fixtures/body-judgment/schema.json)에 기본값은 없다. 기존 본문 계약이 최종 수락 여부를 결정한다.

| 입력 키 | 형식·조건 | bodyComparisonReceipt |
|---|---|---|
| comparator | 앞뒤 공백·CR/LF 없는 비어 있지 않은 문자열 | comparedBy |
| comparedAtUtc | 유효한 UTC 시각 문자열. Z로 끝남 | comparedAtUtc |
| policy | body-only-v1 | policyVersion |
| verdict | exact 또는 mismatch | verdict |
| candidateId | canonical problem ID | candidateId 및 target.selectedId |
| searchAttemptId | canonical attempt ID | searchAttemptId |
| comparison | 아래 7개 항목을 모두 포함한 객체 | comparison |
| sourceRenderScale | 양의 정수 | sourceRenderScale |
| candidateRenderScale | 양의 정수 | candidateRenderScale |
| unresolvedGlyphs | bool | unresolvedGlyphs |

comparison 항목은 bodyText, conditions, formulas, figures, pointLabels, requiredValue, internalStatements다. 각 값은 match, not-present, mismatch 중 하나다. 최종 선택 계약은 bodyText와 requiredValue가 match인 경우만 허용한다.

필수 키 누락은 `judgment-missing:<key>`, 비어 있거나 잘못된 형식은 `judgment-invalid:<key>`다. comparison 하위 키는 `comparison.<key>`로 표시한다. verdict=mismatch, 비교 항목의 mismatch 또는 unresolvedGlyphs=true는 body-not-exact다. 이 경우 target을 쓰지 않는다. mismatch 행의 session 기록은 이 Phase 범위 밖이다.

조립기는 comparator, comparedAtUtc, policy, verdict, comparison, 배율, unresolvedGlyphs를 그대로 전달한다. 현재 시각·비교자·판정으로 보충하지 않는다. roster의 원본 identity와 렌더 경로, CandidateRenderPath의 파일 identity는 별도로 결합하고 해시를 계산한다. 명시된 winning attempt 1개에만 판정을 귀속한다.

다음은 공개 합성 시험에서 사용하는 판정이며 실제 문제의 판정이 아니다.

    {
      "comparator": "phase2-synthetic-contract-test",
      "comparedAtUtc": "2026-10-11T00:00:05.000Z",
      "policy": "body-only-v1",
      "verdict": "exact",
      "candidateId": "7231357",
      "searchAttemptId": "attempt-1",
      "comparison": {
        "bodyText": "match", "conditions": "match", "formulas": "match",
        "figures": "not-present", "pointLabels": "not-present",
        "requiredValue": "match", "internalStatements": "not-present"
      },
      "sourceRenderScale": 2,
      "candidateRenderScale": 1,
      "unresolvedGlyphs": false
    }

관측 입력과 자동 계산 필드는 [검색 입력 문서](search_attempt_input.md)에 있다. schema 통과만으로 실제 본문 일치를 증명하지 않는다. 최종 [본문 계약](../mathsecr-paper-builder-kit/scripts/body_comparison_contract.ps1)은 identity, 관측 결합, 파일 해시, strict scalar 형식까지 검사한다.
