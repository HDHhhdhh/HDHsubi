# Search observation contract

`scripts/search_observation.js` exports one read-only function, `collectMathSecrSearchObservation({ adapter, context })`. Its returned object is one browser read. The function queries visible DOM nodes and reads DOM attributes/text, URL, title, and the explicitly supported clock/capture profile. It performs no click, form edit, navigation, network request, or persistent state write.

The primary agent passes that function and its serializable input to the currently documented IAB read-only evaluate operation. Use the function itself as the evaluation callback, not a loop that manufactures multiple records from one returned value. Each tool read supplies a distinct `context.readEvidenceId`; bind it to the actual tool call/result evidence. Set `context.attemptId` for the search attempt, and `context.submitId` to null before search or the action receipt's submit ID after search. A context submit ID is an orchestration association, not an ID discovered from the backend.

There is deliberately no live MathSecr selector map in the collector. Build `adapter` from the current observed control map, with its `id` and `evidenceId`. The committed `test-fixtures/search-observation/simulator-adapter.json` describes only the local simulator. Its `mode=success` text is a simulator scope value, not a current MathSecr mode.

Each adapter descriptor declares a selector, `read: text` or `read: attribute`, and an attribute name when needed. Optional `jsonPath` reads a scalar from an observed JSON attribute; it does not inspect application objects. `trim: false` preserves raw canonical candidate IDs. `stripSuffix` removes only a declared literal suffix. Required singleton controls must resolve to exactly one visible node. Query descriptors declare `kind: text|formula`; overlapping descriptors are rejected and mixed kinds retain DOM order. The result-count pattern must match the entire visible string and capture one integer. `selectedScopeChecks` must name actual selected controls and their exact observed scalar `equals` values; a source-name hint alone is insufficient. Native result-submit/result-criteria and loading descriptors are optional and must only be configured when those DOM controls were actually observed. An absent loading descriptor means no loading signal was collected, not proof that a backend has finished.

## Packet and integration

The PowerShell API is `Test-MathSecrSearchObservation -Packet $receipt [-AttemptId $id] [-Chips $orderedChipValues] [-ResultCount $count]`. Every provided expected binding is mandatory. The packet has exactly these fields:

```text
schemaVersion: 1
attemptId: canonical string
submission:
  submitId, actionEvidenceId: distinct canonical receipt identities
  action: 검색하기
  surface: iab | offline-dom-test
  completedAtUtc: UTC string YYYY-MM-DDTHH:mm:ss.fffZ
  url: observed paper URL
  criteria: { scopeMode, sourceChips: string[], filterChips: string[],
              chips: [{ kind: text|formula, value: string }] }
  resultCriteriaKey: null | actually observed criteria identity
beforeSubmit: one collector output with submitId: null
observations: independent collector outputs after the action receipt
```

Each collector output has `schemaVersion`, `collectorVersion`, `adapterId`, `adapterEvidenceId`, `attemptId`, `submitId`, `readEvidenceId`, and `raw`. Raw fields are `captureId`, `capturedAtUtc`, `timeOriginMs`, `monotonicMs`, `url`, `title`, `criteria`, `scopeSelectionConfirmed`, and `result`. Result fields are strict integer `count`, ordered canonical string array `orderedIds`, Boolean `loading`, and nullable `observedSubmitId`/`observedCriteriaKey`. There is no caller-supplied pass Boolean in the schema.

The default collector output remains schema/version 1, using `crypto.randomUUID()` and `performance.timeOrigin/now()`. For a restricted CUA DOM evaluator without those globals, explicitly set both `context.clockSource: "date-now"` and `context.captureSource: "read-evidence-id"`. This produces collector schema 2 / `mathsecr-search-observation-v2`; the enclosing receipt packet stays schema 1. Version 2 replaces `timeOriginMs`/`monotonicMs` with `clockSource: "date-now"`, `captureSource: "read-evidence-id"`, and integer `wallClockMs`. `capturedAtUtc` is generated from that exact `Date.now()` value, and `captureId` equals the actual call's `readEvidenceId`. It does not claim a UUID, monotonic clock, or document time origin. The caller must bind each distinct read ID to a separate actual tool invocation/result; copying a record and changing its ID is unsupported and cannot be authenticated by this validator.

Both profile fields are required together. There is no automatic fallback when a required global is absent. A packet cannot mix v1 and v2 observations. Version 2 requires matching UTC/millisecond values, rejects clock regression and reused read/capture identities, and allows equal wall-clock milliseconds for independently identified reads because `Date` has finite resolution. Its projection adds `ClockSource`, `CaptureSource`, `MonotonicClockVerified: false`, and `DocumentClockContinuityVerified: false`. It cannot detect a document reload using a performance origin. The existing URL/title/adapter checks and scope/result freshness checks still apply.

Capture the baseline after query chips have been committed. For a scope/filter transition, retain the baseline from before that transition; its committed query chips must still match the submitted query. The scope/filter difference then derives three-read risk. Discarding that baseline and supplying only a later matching scope read hides the transition and is not supported usage. If a query changes, take a new baseline for the new attempt. The action receipt records the completed visible search action and the intended final criteria; post-action readings must corroborate those criteria.

Ordinary freshness requires two consecutive stable independent post-action readings. Scope/filter changes, any post-action zero, or a count/card mismatch require three. Earlier transient result readings may precede the stable tail. All post-action criteria must agree with the submission. The validator rejects duplicate capture/read/raw identities, reused performance clocks, decreasing clocks, pre-action timestamps, URL/title/adapter/attempt drift, unconfirmed scope controls, malformed tokens, duplicate candidate IDs, unstable tail ordering/count, and contradictory native result identity when supplied. Empty source chips are allowed only with exact observed scope mode `전체 DB`. Repeated identical DOM content is expected and allowed with independently identified reads and the selected profile's clock rules.

Use the validated `Projection` or `ConvertTo-MathSecrSearchObservationReportProjection` for report fields, including `OrderedVisibleIds`, `OrderedChips`, `ResultCount`, and read/capture receipts. The conversion throws for an invalid/pending packet. A projection is derived from the same stable tail, so callers should not separately hand-copy counts or IDs.

PowerShell 7.6 may deserialize ISO dates as DateTime by default. JSON readers must use `ConvertFrom-Json -DateKind String` when supported; Windows PowerShell 5.1 already leaves them strings. The schema intentionally does not coerce DateTime objects, numeric strings, Boolean strings, or scalar values into typed arrays.

## Validation and claim limits

Run `scripts/test_search_observation.ps1 -ProjectRoot <workspace> -Case All`. `Contract` runs synthetic adversarial packets; `Collector` executes this exact JS function in a fresh headless browser against the committed local simulator and validates the resulting packet through PowerShell. It verifies unchanged DOM, selected-control evidence, query order, independent clocks/capture IDs with stable contents, hidden-template exclusion, changed card order, and fail-closed missing/ambiguous extraction. The local test aborts HTTP(S) requests and uses no live MathSecr tab or profile. `-NodePath`, `-PlaywrightModule`, and `-BrowserPath` allow explicit dependency selection. Missing dependencies fail rather than skipping the collector test.

`CuaRestricted` additionally runs the production collector in isolated synthetic DOM contexts where `globalThis`, `crypto`, `performance`, `window.crypto`, `window.performance`, element `compareDocumentPosition`, and element `isSameNode` are unavailable. Mixed chip descriptors deliberately arrive in reverse order; one combined-selector `document.querySelectorAll` traversal supplies actual DOM order and supported `element.matches` assigns each node to its descriptor. Overlapping descriptors still fail closed. The collector requires DOM text/attribute reads, `getComputedStyle`, `getClientRects`, `closest`, `matches`, and combined selector traversal, plus `Date`, document title and location. It uses actual `Date` readings and distinct simulated tool-call IDs, verifies the explicit v2 profile, and validates its packet through PowerShell. `Contract` covers v2 replay, malformed profiles, manufactured performance fields, timestamp disagreement, backward wall clocks, and mixed-profile rejection. This reproduces the reported runtime capability boundary; it does not verify live CUA availability. Runtime failure and repair/testing time belong in the current session record separately from search latency.

This is an offline contract and a UI freshness heuristic. Unique identity fields prevent detectable replay inside a packet; they do not authenticate an externally forged packet or prove that an external tool read happened. No artifact-hash or backend causality claim is made. A stable partial result list may pass freshness after three reads while `CompleteCoverageVerified` remains false. All projections keep `BodyExactVerified`, `CompleteCoverageVerified`, and `BackendCausalityVerified` false. A native ready/submit token is never invented. The selected-path owner additionally checks live IAB/paper route bindings; the offline simulator packet cannot establish live selection eligibility. Body exactness, lazy traversal coverage, miss closure, and persisted selection remain their own contracts.
