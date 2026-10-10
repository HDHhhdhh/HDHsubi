# MathSecr DB Inference Contract

`scripts/db_inference.ps1` turns PDF metadata clusters and read-only body-exact probe evidence into conservative DB/source candidates. It never selects a MathSecr problem. Its output can be placed directly in the state-machine snapshot's `dbInference` property; a separate Boolean-only adapter is not part of the contract.

## Input

Call `Invoke-MathSecrDbInference` with one strict JSON-derived object:

```json
{
  "clusters": [
    {
      "clusterId": "official-source-block-1",
      "collectionComplete": true,
      "scopeMappings": [],
      "printedMetadata": [
        {
          "problemNumber": "1번",
          "sourceType": "education",
          "scope": "교육청, 평가원",
          "scopeKind": "collection",
          "exact": true
        },
        {
          "problemNumber": "문제 2",
          "sourceType": "education",
          "scope": "교육청, 평가원",
          "scopeKind": "collection",
          "exact": true
        }
      ],
      "probeHits": [],
      "receipts": {
        "blankProbe": {
          "readOnly": true,
          "chips": [],
          "submitted": false,
          "freshResultVerified": false,
          "resultSignature": ""
        },
        "scopeLock": {
          "selectorSearchCleared": true,
          "scopeReceiptVerified": true,
          "selectedScope": "교육청, 평가원"
        },
        "scopedSearch": {
          "selectedScope": "교육청, 평가원",
          "chips": ["삼차방정식", "서로 다른 실근"],
          "submitted": true,
          "freshResultVerified": true,
          "resultSignature": "2|225092,1419354"
        }
      }
    }
  ]
}
```

- `collectionComplete=false` yields `pending`.
- `scopeMappings` is optional. Each `{ "evidenceScope": "...", "canonicalScope": "..." }` maps one normalized evidence leaf to the exact full selectable UI scope. Evidence keys must be unique. Omit it or use an empty array when evidence already uses the canonical scope.
- `printedMetadata.sourceType`: `textbook`, `education`, `evaluation`, or `other`.
- `printedMetadata.scopeKind` and `probeHits.scopeKind`: `leaf`, `collection`, `folder`, or `unit`.
- `printedMetadata.exact` means the printed source block was extracted without ambiguity. It is not a body-exact claim.
- `probeHits.bodyExact` follows the MathSecr body-only exact policy.
- Unknown properties, loose Boolean strings, scalar arrays, duplicate cluster IDs, invalid enums, duplicate/blank chips, and inconsistent receipt phases are rejected.
- Problem keys use NFKC, whitespace, and numeric-wrapper normalization. `1`, `01`, `１`, `1번`, and `문제 1` are one problem.

## Phase-Bound Receipts

The three receipt phases are independent. A receipt from one phase cannot satisfy another.

- `blankProbe`: read-only inference probe. A submitted phase requires at least two unique nonblank committed chips, explicit submit, `freshResultVerified=true`, and a nonblank stable `(count, ordered IDs)` signature. Any submitted probe or probe row with `readOnly=false` fails closed, including a non-exact row alongside otherwise sufficient printed metadata.
- `scopeLock`: selector mutation receipt. `selectorSearchCleared=true`, `scopeReceiptVerified=true`, and `selectedScope` must identify the inferred canonical full scope. For the official collection on the current `/mypaper/<id>` route, the receipt must come from the top `내 문제지` search mode's `나만의 DB 선택` dropdown, not `내 문제지 선택` or the `보유 DB` folder-navigation/radio selector.
- `scopedSearch`: post-lock search receipt. It repeats the exact canonical scope identity and has its own committed chips, submit, freshness, and signature.

Scope identity uses NFKC, trim, whitespace normalization, and normalized `>` separators, followed by exact equality. A terminal leaf title does not equal its full UI breadcrumb. Substring matching is forbidden; callers must map evidence to the canonical full selectable scope before claiming readiness.

For the official collection, the canonical selectable identity is exactly `교육청, 평가원`. On the current `/mypaper/<id>` top `내 문제지` search mode, the scope-lock receipt must come from the single visible checkbox/label in the `나만의 DB 선택` dropdown, followed by a selected chip and `교육청, 평가원 제거` removal receipt. `내 문제지 선택` is not this scope-lock path, and the `보유 DB` top tab is a folder-navigation/radio selector rather than the same source mutation. Row text, active styling, or an expanded tree alone is not sufficient. The older `작업공간` wording in the 2026-06-05 selector evidence is a dated observation and does not override this current route rule.

For example, Daejin probe evidence uses the leaf title `2026년(2027학년도) EBS 수능특강 확률과 통계`, while the selected UI identity is `3. 교재 > 수능특강, 수능완성 > 확통 > 2026년(2027학년도) EBS 수능특강 확률과 통계`. That cluster supplies this explicit mapping:

```json
{
  "scopeMappings": [
    {
      "evidenceScope": "2026년(2027학년도) EBS 수능특강 확률과 통계",
      "canonicalScope": "3. 교재 > 수능특강, 수능완성 > 확통 > 2026년(2027학년도) EBS 수능특강 확률과 통계"
    }
  ]
}
```

## Decision

The resolver cross-checks all exact printed and body-exact probe evidence before returning an inference.

- Two normalized-distinct exact printed official rows infer `교육청, 평가원` only when their scope is the selectable `collection`.
- Two normalized-distinct exact printed textbook rows infer one agreeing `leaf`.
- Without printed metadata, three normalized-distinct body-exact, read-only, blank-probe-receipted hits may agree on either one textbook `leaf` or the canonical selectable official `collection` `교육청, 평가원`. Collection inference requires all three hits to have `scopeKind=collection` and the exact normalized scope `교육청, 평가원`; all three must also have complete, phase-bound `blankProbe`, `scopeLock`, and `scopedSearch` receipts. Leaf inference still requires one agreeing normalized leaf.
- Exact `other` evidence, mixed source families, printed/probe disagreement, conflicting leaves or collections, unrecognized collections, folder/unit evidence, mutation, non-exact-only evidence, missing/incomplete receipts, or missing evidence yield `unresolved`.
- Mixed PDFs return per-cluster results; one global leaf is not forced.

## Output And Readiness

- `Status`: `pending`, `inferred`, or `unresolved`.
- `Results`: per-cluster status, canonical candidate, confidence, reason, nested receipt payloads, and row readiness.
- `ScopeLockReady=true` only when every cluster is inferred and every canonical selected-scope identity, selector reset, and scope receipt validates.
- `FreshSearchReceiptReady=true` only when scope lock is ready and every cluster also has a valid, scope-bound `scopedSearch` receipt.
- `Status=inferred` alone is only a candidate decision. Selection-related actions require both readiness gates; the state machine revalidates the nested payload rather than trusting aggregate Booleans alone.

## Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\mathsecr-paper-builder-kit\scripts\test_db_inference.ps1 -ProjectRoot . -Case All
```

The suite covers real Daejin/Juyeop provenance, evidence conflicts, mixed sources, official-folder rejection, canonical breadcrumb identity, probe mutation, phase-receipt shape attacks, normalized duplicate problem wrappers, and aggregate readiness truth tables.
