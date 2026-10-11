READ AGENTS.md first.
Use the mathsecr-paper-builder skill.

Do not click `출제하기`.
Use the surface declared by the session input for live MathSecr work. On aside-repl, Inspect existing tabs, attach the relevant MathSecr tab, and use `snapshot()` as the primary page-reading path.
Keep the main agent as the only live browser owner; subagents are read-only.
SURFACE_HARD_STOP: Stay on the surface declared by the session input. If that surface is unavailable or cannot attach to and verify the live paper, report `차단`. Do not switch that session to any other browser surface.
ASIDE_OFF_USER_RESPONSE: For a paper-production request, if the current probe confirms Aside is not running, output exactly `aside 키고 다시 오도록.` and nothing else. Generic timeout, missing CLI, or failed paper verification is not proof that Aside is off. This exception applies only to aside-repl sessions.
PRODUCTION_VALIDATION_REF: Follow the kit SKILL and docs/production_validation.md. Run check_browser_surface.ps1 -Surface <surface> and validate_production_step.ps1 at Select, BeforeNext, and AfterReload. Use requestedAction=partial-save to save verified exact cards while preserving unresolved rows. Do not fabricate observations, judgments, or search receipts for unsearched rows.
Do not reload a long-idle live tab solely because time elapsed; re-check URL/title/login and source/query removal receipts, then apply the ordinary freshness gate. Reload or reopen only when one of those checks fails.
Treat the dated 2026-07-31 frozen idle fixture as offline characterization, not a live availability, latency, result-count, standard-freshness, or exact/miss contract.
Keep repeated source positions distinct by stable `occurrenceKey`. Do not re-click the same result card to create a duplicate: the dated same-card second activation cleared the only selection. Require a verified visible duplicate/add control plus edit/persisted ordered-bundle proof, otherwise block the later occurrence.

Surface: <aside-repl|codex-iab|codex-chrome-ext; blank = aside-repl>
Paper URL:
Source PDF/HWPX:
Initial DB/source scope: <optional; if blank, infer per PDF metadata cluster and receipt-verified read-only probes>
Initial unit/type scope: <optional>
Special instructions:
