# MathSecr Paper Builder Kit

Portable setup kit for repeating the MathSecr/수학비서 paper-building workflow in another local Codex environment.

## Bundle Contract

The supported installer source is a full MathSecr hub checkout containing both:

- `mathsecr-paper-builder-kit/`
- the sibling `.omo/evidence/` files named in `AGENTS.md`

When the kit is stored separately, pass `-EvidenceRoot` with the directory containing those evidence files. Installation stops when a required package asset is missing. This prevents a copied `AGENTS.md` from pointing at evidence that was never installed.

## Contents

- `AGENTS.md`: project hub rules, installed at the target workspace root.
- `skills/mathsecr-paper-builder/SKILL.md`: reusable Codex skill, installed under the selected Codex home.
- `test-fixtures/`, `docs/`, `prompts/`, and `scripts/`: copied with the support kit to `mathsecr-paper-builder-kit/` under the target workspace. The detailed reusable workflow prompt is versioned at `prompts/mathsecr_new_paper_prompt.md`.
- indexed `.omo/evidence` files: copied to the target workspace.
- `scripts/install.ps1`: installs and validates the complete supported bundle.
- `scripts/check.ps1`: verifies an existing installation without copying files.
- `scripts/db_inference.ps1`: resolves per-cluster `pending`/`inferred`/`unresolved` DB candidates from cross-checked printed metadata or phase-bound, receipt-verified read-only body-exact probes.
- `scripts/test_db_inference.ps1`: runs strict DB-inference shape, evidence-conflict, mixed-source, canonical-scope identity, mutation-safety, and phase-bound receipt fixtures.
- `scripts/test_search_characterization.ps1`: validates SHA-pinned handoff intake, phrase-versus-split live observations, three identical post-submit snapshots, freshness transition evidence, and zero-selection cleanup; observed counts remain dated characterization rather than product contracts.
- `scripts/test_idle_search_characterization.ps1`: replays a frozen dated fixture for the duplicate-card toggle-off observation and three distinct prepared tabs in one authenticated IAB session, each with one first query after 15/30/60 minutes. It checks scope/chip receipts, tab-bound idle timestamps, two repeated signatures, zero idle selections, and IAB-only safety boundaries; it does not rerun the live waits or claim service availability, latency, result-count, standard fresh-search receipt, or exact/miss validity.
- `scripts/selection_journal.ps1`: provides an offline append-only occurrence journal for bounded selection retries, late ACK handling, deterministic crash/resume replay, and idempotent re-emission while keeping source `occurrenceKey` distinct from DB `problemId`.
- `scripts/test_selection_journal.ps1`: exercises occurrence identity, timeout/retry references, exactly-once resolution, corrupt-tail rejection, and deterministic replay red cases.
- `scripts/search_query_plan.ps1`: prepares source-order literal query inputs from supplied transcriptions, with recomputed spans and hashes.
- `scripts/search_observation.js` and `scripts/search_observation_contract.ps1`: collect one compact read-only DOM record and derive freshness/report fields from independent reads; the collector is tested against the local simulator DOM.
- `scripts/body_comparison_contract.ps1` and `scripts/validate_selection_snapshot.ps1`: require artifact-bound body comparisons and a matching observed exact-producing search before selected snapshots can pass. See [the tool workflow](docs/search_preparation_and_selection_evidence.md). These contracts do not establish independent mathematical truth or measured search speed.
- `scripts/create_failed_problem_report.py`: builds a local one-landscape-A4-page-per-miss PDF from a UTF-8 JSON manifest and rendered problem-image crops; it never contacts MathSecr or a browser.
- `scripts/test_failed_problem_report.ps1`: runs the crop-report generator against fixed local PNG bytes, checks the real two-page PDF and manifest red cases, and removes its GUID temp tree.
- `scripts/test_pdf_segmentation.ps1`: verifies the SHA-pinned real-PDF render corpus, printed-number column order, diagram regions, exact page partitioning, and honest coverage gaps. Portable mode validates packaged assets without requiring the user-owned source PDFs; `-RequireSourcePdfs` enables the canonical source-hash gate.
- <!-- SEARCH_ATTEMPT_SSOT_REF --> `scripts/search_attempt_contract.ps1` is the canonical executable owner for search-attempt packet semantics, and `scripts/test_search_attempt_contract.ps1` supplies its pinned regression cases. The sole human procedure is the kit SKILL's [Search Attempt Contract](skills/mathsecr-paper-builder/SKILL.md#search-attempt-contract).
- <!-- DB_INFERENCE_SSOT_REF --> `scripts/db_inference.ps1` and [the DB inference specification](docs/db_inference_contract.md) own executable/schema decisions; the sole human procedure, including the current official-collection selector route, is the kit SKILL's [DB Inference And Official Collection Contract](skills/mathsecr-paper-builder/SKILL.md#db-inference-and-official-collection-contract).
- <!-- METADATA_RESCUE_SSOT_REF --> `scripts/state_machine.ps1` owns metadata-rescue receipt derivation and search packets still use the search-attempt executable; the sole human procedure is the kit SKILL's [Metadata Rescue And Lazy Coverage Contract](skills/mathsecr-paper-builder/SKILL.md#metadata-rescue-and-lazy-coverage-contract).
- <!-- BODY_EXACT_SSOT_REF --> Live candidate selection follows the kit SKILL's [Body-Exact Selection Contract](skills/mathsecr-paper-builder/SKILL.md#body-exact-selection-contract). `scripts/ground_truth_contract.ps1` separately owns evaluation-claim independence and does not replace the live selection procedure.
- `test-fixtures/lessons/re0-memo-registry.json` records generalized session lessons as either `gated` or `record-only`; `scripts/test_re0_memo.ps1` rejects broken evidence, negative-corpus, validator, and full-runner linkage without reimplementing the underlying behavior tests.
- `test-fixtures/evaluation/ground-truth-claims.json` classifies high-risk evaluations as `external-ground-truth`, `dated-characterization`, or `offline-contract`; `scripts/ground_truth_contract.ps1` requires every external claim to have complete independent oracle sides and rejects gold/fixture/evaluator self-oracles. Body-exact external promotion is categorically disabled until a typed adjudication receipt binds exact source/candidate artifact hashes; the current corpus remains a dated characterization.
- `scripts/regression_evidence_contract.ps1` binds a successful regression artifact to the current AGENTS, kit, prompt, and only the evidence inputs declared by the installer, re0-memo registry, or ground-truth registry. `scripts/test_regression_evidence_contract.ps1` rejects referenced-evidence drift, cyclic output evidence, stale PASS reuse, output drift, unsafe paths, and weakly typed sidecars while ignoring unrelated diagnostic reports and without claiming live product truth.
- `scripts/run_validations.ps1`: supported entry point for the complete regression pack in `run_mathsecr_regression.ps1`.
- `scripts/state_machine.ps1`: consumes the resolver output directly when `dbInference` is present, revalidates every nested scope/search receipt, and blocks printed-metadata misses until the metadata-rescue and lazy-result coverage receipt is complete.
- `docs/db_inference_contract.md`: documents the strict input schema, conservative decision rules, and aggregate readiness gates.

## Current Reusable Guardrails

- A prepared live tab is not reloaded or reopened because idle time alone elapsed. Re-check the current URL/title/login, source/query removal receipts, and ordinary freshness gate; recover only when one of those checks fails.
- The dated 2026-07-31 frozen fixture does not prove current service availability, latency, result count, standard fresh-search receipt, or exact/miss correctness. Offline regression replays the stored observation and does not perform the 15/30/60-minute live waits.
- Every printed source position keeps its own stable `occurrenceKey`, even when two positions resolve to one DB `problemId`. The dated same-card second activation cleared the only selection; never use a re-click as duplicate insertion. A later occurrence requires a verified visible duplicate/add control plus edit/persisted ordered-bundle proof, otherwise it remains blocked.
- Printed-metadata recovery and lazy-result miss coverage intentionally are not restated here. Workers follow the linked metadata-rescue section and state integrations consume the state machine's derived receipt verdict.
- Live match components and low-confidence glyph handling intentionally are not restated here. Workers follow the linked body-exact section; evaluation claim grades remain a separate ground-truth concern.
- Search-attempt behavior is intentionally not restated here. State and report integrations source the canonical executable contract and consume only its derived status; operational workers follow the linked SKILL section.
- A validator hash proves that the checked bytes did not drift, not that those bytes describe reality. Ground-truth PASS is reserved for complete independent oracles; otherwise output must expose its dated-characterization or offline-contract scope.

## Quick Start

Open PowerShell in this kit folder. These commands work even when the machine's script execution policy blocks direct `.ps1` invocation.

Install the complete bundle:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -ProjectRoot "C:\path\to\mathsecr-workspace"
```

Use `-Force` to overwrite existing installed documents and support assets:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -ProjectRoot "C:\path\to\mathsecr-workspace" -Force
```

`-Force` permanently deletes target-only obsolete files from the exact `ProjectRoot\mathsecr-paper-builder-kit` directory before copying. It also permanently deletes target-only custom references, scripts, and other files under the exact Codex-home `skills\mathsecr-paper-builder` directory. Every deleted file's absolute path is printed. Cleanup refuses filesystem-root targets, paths outside their declared roots, and reparse points. Empty directories are ignored.

The installer runs a Python runtime preflight before it creates or changes any target files. The `python` interpreter resolved from `PATH` must successfully import `PIL` (from Pillow), `reportlab`, and `pypdf`; these capabilities are required to generate and validate the mandatory failed-problem PDF report. The installed skill validator and report tests also resolve `python` from `PATH` when they run.

For a separately stored kit, provide its evidence directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -ProjectRoot "C:\path\to\mathsecr-workspace" -EvidenceRoot "C:\path\to\mathsecr-evidence"
```

Verify an existing installation and document sync:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1 -ProjectRoot "C:\path\to\mathsecr-workspace"
```

Run this command from an unchanged canonical source kit and point `-ProjectRoot` at the separate installation you want to audit. Content-drift detection compares that source kit with the target. If the command is run in place against the same hub that contains the source kit, support-kit files compare with themselves; that remains useful for semantic validation, installed-skill validation, evidence existence, and root/installed-document checks, but it is not independent proof of portability or source-to-target content sync.

Run the isolated installer contract regression. It creates a unique system-temp directory and removes it after the test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_install_contract.ps1
```

Run the complete validation/regression pack, including the search-attempt provenance fixture and local HTTP simulator smoke:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_validations.ps1 -ProjectRoot "C:\path\to\mathsecr-workspace"
```

A successful run writes the text artifact and its `.manifest.json` sidecar. The sidecar is an offline current-input attestation; it does not establish external ground truth or current MathSecr behavior.

`-CodexHome` overrides `CODEX_HOME`. When neither is supplied, the scripts use `%USERPROFILE%\.codex`.

## Validation Contract

Installation and `check.ps1` fail with a nonzero exit code when:

- the supported source bundle is missing a required fixture, prompt, validator, or indexed evidence file;
- a high-impact or repeated memo lesson is not linked to existing evidence, negative corpus, a validator assertion, and the complete regression runner;
- `-CheckOnly` targets a missing project root or Codex home;
- installed `AGENTS.md`, the copied kit, or the installed skill is missing or out of sync;
- a required evidence path is absent;
- a live reusable prompt omits the canonical `SURFACE_HARD_STOP` sentence or permits a off-surface live-browser fallback;
- a report uses card/visual identity fallback evidence without `artifact=<path>; sha256=<64 hex>; identity=<concrete description>`, or the artifact is not an existing trusted `ProjectRoot`-relative file whose SHA-256 matches the receipt;
- the project-specific document validator fails.

Browser cache, Node.js, `rg`, and PDF helpers are reported separately. Python is a required runtime capability: installation fails before target mutation when Python is unavailable or cannot import `PIL`/Pillow, `reportlab`, or `pypdf`. Missing Browser availability still blocks live MathSecr work even though it does not prevent installing documentation.

## Recipient Start Prompt

After installation, open the target workspace in Codex and start with:

`mathsecr-paper-builder-kit\prompts\start-prompt.md`

For the detailed reusable workflow, use `mathsecr-paper-builder-kit\prompts\mathsecr_new_paper_prompt.md`.

## Notes

- MathSecr login, DB access, and the user's own source PDFs are not included.
- The kit does not install Codex Desktop, Browser plugin, or external PDF tools.
- Crop-report generation and PDF validation require local Python imports `PIL` (from `Pillow`), `reportlab`, and `pypdf`; the regression test uses only local fixture bytes and Windows TrueType fonts.
- `출제하기` remains forbidden unless the user explicitly requests it.
