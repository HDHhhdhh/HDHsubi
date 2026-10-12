/* A single read-only DOM observation. Pass this function to the browser's
 * documented evaluate API with { adapter, context }. There are no live defaults.
 * Selectors and extraction rules must come from the current observed control map.
 */
function collectMathSecrSearchObservation(input) {
  "use strict";
  const object = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
  const text = (v, name) => {
    if (typeof v !== "string" || !v.trim() || v !== v.trim()) throw new Error(`${name}: nonblank canonical string required`);
    return v;
  };
  if (!object(input) || !object(input.adapter) || !object(input.context)) throw new Error("adapter and context required");
  const a = input.adapter;
  const c = input.context;
  ["id", "evidenceId"].forEach((k) => text(a[k], `adapter.${k}`));
  ["attemptId", "readEvidenceId"].forEach((k) => text(c[k], `context.${k}`));
  if (c.submitId !== null) text(c.submitId, "context.submitId");
  const dateProfile = c.clockSource === "date-now" && c.captureSource === "read-evidence-id";
  if (!dateProfile && (c.clockSource !== undefined || c.captureSource !== undefined)) throw new Error("unsupported explicit clock/capture profile");
  if (!dateProfile && (typeof crypto === "undefined" || !crypto || typeof crypto.randomUUID !== "function")) throw new Error("capture UUID unavailable");
  if (!dateProfile && (typeof performance === "undefined" || !performance || typeof performance.now !== "function")) throw new Error("performance clock unavailable");
  const visible = (el) => {
    const style = getComputedStyle(el);
    return el.isConnected && style.display !== "none" && style.visibility !== "hidden" &&
      style.visibility !== "collapse" && el.getClientRects().length > 0 && !el.closest('[hidden], [aria-hidden="true"]');
  };
  const nodes = (d) => {
    if (!object(d)) throw new Error("observed descriptor required");
    text(d.selector, "descriptor.selector");
    return Array.from(document.querySelectorAll(d.selector)).filter(visible);
  };
  const extract = (el, d) => {
    let value;
    if (d.read === "text") value = el.textContent;
    else if (d.read === "attribute") value = el.getAttribute(text(d.attribute, "descriptor.attribute"));
    else throw new Error("descriptor.read must be text or attribute");
    if (d.jsonPath !== undefined) {
      if (!Array.isArray(d.jsonPath) || d.jsonPath.some((p) => typeof p !== "string" || !p)) throw new Error("jsonPath must be string array");
      value = JSON.parse(value);
      for (const part of d.jsonPath) value = value !== null && typeof value === "object" ? value[part] : undefined;
    }
    if (value === undefined || value === null) return null;
    if (typeof value !== "string" && typeof value !== "boolean" && typeof value !== "number") throw new Error("descriptor result must be scalar");
    if (typeof value === "string" && d.trim !== false) value = value.trim();
    if (d.stripSuffix !== undefined) {
      text(d.stripSuffix, "descriptor.stripSuffix");
      if (typeof value !== "string" || !value.endsWith(d.stripSuffix)) throw new Error("observed suffix is missing");
      value = value.slice(0, -d.stripSuffix.length).trimEnd();
    }
    return value;
  };
  const one = (d, optional = false) => {
    if (optional && (d === undefined || d === null)) return null;
    const found = nodes(d);
    if (optional && found.length === 0) return null;
    if (found.length !== 1) throw new Error(`expected exactly one visible node: ${d.selector}`);
    return extract(found[0], d);
  };
  const many = (d) => {
    if (d === null) return [];
    return nodes(d).map((el) => text(extract(el, d), "observed list value"));
  };
  // Preserve the existing string[] packet while binding each observed filter
  // group to its adapter key and DOM order. Selectors are never inferred here.
  const filters = (descriptors) => {
    if (!Array.isArray(descriptors)) return many(descriptors);
    const keys = [];
    return descriptors.map((d) => {
      if (!object(d)) throw new Error("observed filter descriptor required");
      text(d.key, "filter descriptor.key");
      if (keys.includes(d.key)) throw new Error("duplicate filter descriptor key");
      keys.push(d.key);
      const minimum = d.minCount === undefined ? 0 : d.minCount;
      const maximum = d.maxCount === undefined ? Number.MAX_SAFE_INTEGER : d.maxCount;
      if (!Number.isSafeInteger(minimum) || !Number.isSafeInteger(maximum) ||
          minimum < 0 || maximum < minimum) throw new Error("invalid filter descriptor cardinality");
      const found = nodes(d);
      if (found.length < minimum || found.length > maximum) throw new Error(`filter descriptor cardinality mismatch: ${d.key}`);
      const values = found.map((el) => {
        const value = extract(el, d);
        if (value === null) throw new Error(`missing observed filter value: ${d.key}`);
        if (typeof value === "string") text(value, "observed filter value");
        if (typeof value === "number" && !Number.isFinite(value)) throw new Error(`nonfinite observed filter value: ${d.key}`);
        return value;
      });
      return JSON.stringify([d.key, values]);
    });
  };
  if (!Array.isArray(a.selectedScopeChecks) || a.selectedScopeChecks.length === 0) throw new Error("selectedScopeChecks required");
  const scopeSelectionConfirmed = a.selectedScopeChecks.every((check) =>
    object(check) && Object.prototype.hasOwnProperty.call(check, "equals") && one(check) === check.equals);
  if (!Array.isArray(a.queryChips)) throw new Error("queryChips descriptors required");
  for (const d of a.queryChips) {
    if (!object(d)) throw new Error("observed descriptor required");
    text(d.selector, "descriptor.selector");
    if (!["text", "formula"].includes(d.kind)) throw new Error("query kind must be text or formula");
  }
  // querySelectorAll returns document order. Restricted DOM wrappers need not
  // expose compareDocumentPosition; do not substitute descriptor/input order.
  const chipOrder = a.queryChips.length === 0 ? [] :
    Array.from(document.querySelectorAll(a.queryChips.map((d) => d.selector).join(","))).filter(visible);
  const chipNodes = chipOrder.map((el) => {
    const descriptors = a.queryChips.filter((d) => el.matches(d.selector));
    if (descriptors.length !== 1) throw new Error("overlapping query descriptors");
    const d = descriptors[0];
    return { kind: d.kind, value: text(extract(el, d), "chip value") };
  });
  const countText = one(a.resultCount);
  if (typeof countText !== "string") throw new Error("result count must be visible text");
  text(a.resultCount.pattern, "resultCount.pattern");
  const match = new RegExp(a.resultCount.pattern, "u").exec(countText);
  if (!match || match[0] !== countText || !match[1] || !/^(?:0|[1-9][0-9]*|[1-9][0-9]{0,2}(?:,[0-9]{3})+)$/.test(match[1])) throw new Error("result count pattern did not match exactly one integer");
  const count = Number(match[1].replaceAll(",", ""));
  if (!Number.isSafeInteger(count)) throw new Error("result count is not a safe integer");
  if (a.loading !== null && a.loading !== undefined &&
      (!object(a.loading) || !Object.prototype.hasOwnProperty.call(a.loading, "equals"))) throw new Error("loading.equals required when a loading control is observed");
  const loading = a.loading === null || a.loading === undefined ? false : one(a.loading) === a.loading.equals;
  // The restricted DOM evaluator has Date but no crypto/performance global.
  // A caller receipt is explicitly a receipt, never a manufactured UUID/clock.
  const wallClockMs = dateProfile ? Date.now() : null;
  const capture = dateProfile ? {
    captureId: c.readEvidenceId,
    capturedAtUtc: new Date(wallClockMs).toISOString(),
    clockSource: "date-now",
    captureSource: "read-evidence-id",
    wallClockMs
  } : {
    captureId: crypto.randomUUID(),
    capturedAtUtc: new Date().toISOString(),
    timeOriginMs: performance.timeOrigin,
    monotonicMs: performance.now()
  };
  const raw = {
    ...capture,
    url: location.href,
    title: document.title,
    criteria: {
      scopeMode: text(one(a.scopeMode), "scope mode"),
      sourceChips: many(a.sourceChips),
      filterChips: filters(a.filterChips),
      chips: chipNodes.map(({ kind, value }) => ({ kind, value }))
    },
    scopeSelectionConfirmed,
    result: {
      count,
      orderedIds: many(a.resultIds),
      loading,
      observedSubmitId: one(a.resultSubmitId, true),
      observedCriteriaKey: one(a.resultCriteriaKey, true)
    }
  };
  return {
    schemaVersion: dateProfile ? 2 : 1,
    collectorVersion: dateProfile ? "mathsecr-search-observation-v2" : "mathsecr-search-observation-v1",
    adapterId: a.id,
    adapterEvidenceId: a.evidenceId,
    attemptId: c.attemptId,
    submitId: c.submitId,
    readEvidenceId: c.readEvidenceId,
    raw
  };
}
if (typeof module !== "undefined" && module.exports) module.exports = collectMathSecrSearchObservation;
