# Source query preparation

`scripts/search_query_plan.ps1` prepares supplied transcriptions and proposed
literal words before UI input. It neither performs OCR nor chooses words. Its
`ready` status means the proposed input is consistent with the supplied text;
it does not establish source-PDF truth, a selected DB scope, a submitted search,
fresh results, inspected coverage, or body-exactness.

```powershell
& ./mathsecr-paper-builder-kit/scripts/search_query_plan.ps1 `
  -InputPath ./mathsecr-paper-builder-kit/test-fixtures/search-query-plan/source-order-input.json `
  -OutPath ./new-query-plan.json
```

The example input is an offline structural fixture, not an adjudicated paper.
The CLI writes UTF-8 JSON to stdout and optionally a new file; existing output
files are never overwritten. Exit 0 means every target is ready; exit 2 means
input/preparation is blocked. In a partial plan, ready target rows remain
individually usable after their own validation while blocked rows have no UI
chips. Source order comes from the input array, not numerical problem sorting.
Repeated printed numbers remain separate when their occurrence keys differ.

Input schema version 1:

```json
{
  "schemaVersion": 1,
  "targets": [{
    "sourceProblemNumber": "7",
    "occurrenceKey": "paper:page1:q7",
    "sourceBodyText": "직선과 곡선이 만나는 두 점을 A, B라 하자.",
    "proposedChips": [
      {"value": "직선", "provenance": "literal-body"},
      {"value": "곡선", "provenance": "literal-body"}
    ],
    "recoveryHints": {
      "printedMetadata": [{"value": "교육청", "sourceText": "2023년 교육청 고3공통 10월"}],
      "candidateIds": [],
      "sourcePaperSelectors": []
    }
  }]
}
```

Initial word legality and normalized distinction reuse the canonical search
contract helpers. A proposed word must occur contiguously, with case preserved,
in the NFKC-normalized supplied transcription. Korean particle-attached literal
stems are allowed (`직선` in `직선과`); no whitespace deletion, stemming, symbol
translation, or semantic generation occurs. The receipt records the first
matching NFKC span with zero-based UTF-16 code-unit offsets. The transcription
hash covers the exact supplied string encoded as UTF-8 without BOM, including
its original whitespace and line endings. It is not a hash of the source PDF.

Each target output carries `sourceOrder`, `targetBinding`, `inputTarget`,
`transcriptionSha256`, `initialChips`, `recoveryHints`,
`requiresLiveScopeAndFreshness`, `status`, and `errors`. Each prepared chip
carries `value`, `provenance`, `evidenceReceipt`, and `sourceSpan`. Printed
metadata hints require their own supplied text and literal span; candidate IDs
and selector labels are checked for shape/uniqueness and remain `hint-only`.
No confidence score or live-completion Boolean is fabricated.

For integration, dot-source the script and use:

```powershell
$plan = New-MathSecrSearchQueryPlan -InputDocument $sourceInput
$wholeCheck = Test-MathSecrSearchQueryPlan -Plan $plan
$rowCheck = Test-MathSecrSearchQueryTargetPlan `
  -PlanRow $plan.targets[0] `
  -ExpectedTargetBinding ([pscustomobject]@{sourceProblemNumber='7'; occurrenceKey='paper:page1:q7'}) `
  -ExpectedSourceOrder 1
```

Both validators recompute receipts from the embedded input and compare the
derived structure, spans, hashes, ordered arrays, and exact identity strings.
Object property order does not affect validation. A modified transcription can
only become a new plan by preparing it again; callers must retain the planned
source receipt when binding subsequent observation and selection evidence.

The canonical SKILL Search Attempt Contract still governs the literal two-word
start, 100-result refinement threshold, reset/backoff, and candidate recovery.
Its explicit live scope/submit/freshness checks and required-refresh checkpoints
remain mandatory after preparation. A prepared chip receipt is a transcription
reference, not a chip-commit receipt. Complete miss coverage and final
edit/persistence verification are unchanged.

Run `scripts/test_search_query_plan.ps1` on both PowerShell 5.1 and 7. Tests cover
source order, repeated occurrences, literal spans/hashes, semantic and sentence
rejection, malformed hints, tampered prepared receipts, and the real CLI JSON
round-trip. Their truth scope is transcription-query-preparation only.
