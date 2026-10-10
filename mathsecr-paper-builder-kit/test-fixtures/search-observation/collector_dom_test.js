/* Real DOM test against the committed local simulator, in an isolated headless
 * browser. No live MathSecr URL, profile, remote API, or live selector is used. */
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const assert = require("node:assert/strict");
const root = path.resolve(__dirname, "../..");
const collect = require(path.join(root, "scripts/search_observation.js"));
const adapter = JSON.parse(fs.readFileSync(path.join(__dirname, "simulator-adapter.json"), "utf8").replace(/^\uFEFF/, ""));
const [modulePath, browserPath, outputPath] = process.argv.slice(2);
if (!modulePath || !browserPath || !outputPath) throw new Error("playwright module, browser executable, and output path required");
const { chromium } = require(modulePath);
async function main() {
  const browser = await chromium.launch({ executablePath: browserPath, headless: true });
  try {
    const context = await browser.newContext();
    await context.route(/^https?:/, route => route.abort());
    const page = await context.newPage();
    await page.goto(pathToFileURL(path.join(root, "test-fixtures/iab-simulator/index.html")).href);
    await page.locator("#educationSourceLabel").click();
    await page.locator("#presetGongcha").click();
    await page.locator("#presetNatural").click();
    let read = 0;
    const observation = (submitId, customAdapter = adapter) => page.evaluate(collect, {
      adapter: customAdapter,
      context: { attemptId: "offline-attempt-1", submitId, readEvidenceId: `offline-dom-read-${++read}` }
    });
    const before = await observation(null);
    assert.equal(before.raw.scopeSelectionConfirmed, true);
    assert.deepEqual(before.raw.criteria.chips, [{ kind: "text", value: "공차" }, { kind: "text", value: "자연수" }]);
    await page.locator("#searchButton").click();
    const submission = {
      submitId: "offline-submit-1", actionEvidenceId: "offline-dom-click-1", action: "검색하기",
      surface: "offline-dom-test", completedAtUtc: new Date().toISOString(), url: page.url(),
      criteria: before.raw.criteria, resultCriteriaKey: null
    };
    const htmlBefore = await page.content();
    const post1 = await observation(submission.submitId);
    const post2 = await observation(submission.submitId);
    assert.equal(await page.content(), htmlBefore, "collector must not modify DOM");
    assert.equal(post1.raw.result.count, 8);
    assert.deepEqual(post1.raw.result.orderedIds, ["7231357", "7231365", "7231367", "7232191", "7232217", "7232220", "7232227", "7232230"]);
    assert.deepEqual(post1.raw.result, post2.raw.result, "stable DOM result content may repeat");
    assert.notEqual(post1.raw.captureId, post2.raw.captureId);
    assert(post2.raw.monotonicMs > post1.raw.monotonicMs);
    const packet = { schemaVersion: 1, attemptId: "offline-attempt-1", submission, beforeSubmit: before, observations: [post1, post2] };

    // These mutations belong to test setup, never to the collector.
    await page.evaluate(() => {
      const hidden = document.querySelector("#cards label.card").cloneNode(true);
      hidden.hidden = true;
      document.querySelector("#cards").prepend(hidden);
    });
    assert.deepEqual((await observation(submission.submitId)).raw.result.orderedIds, post1.raw.result.orderedIds, "hidden templates excluded");
    await page.evaluate(() => {
      const cards = document.querySelector("#cards");
      cards.prepend(cards.lastElementChild);
    });
    assert.equal((await observation(submission.submitId)).raw.result.orderedIds[0], "7232230", "actual DOM order retained");
    await page.evaluate(() => { document.querySelector("#resultCount").textContent = "검색결과 : 8개 / 이전 99개"; });
    await assert.rejects(() => observation(submission.submitId), /result count pattern/);
    await page.evaluate(() => { document.querySelector("#resultCount").textContent = "검색결과 : 8개"; });
    const ambiguous = structuredClone(adapter);
    ambiguous.scopeMode.selector = ".chip";
    await assert.rejects(() => observation(submission.submitId, ambiguous), /exactly one visible node/);
    const missing = structuredClone(adapter);
    missing.resultCount.selector = "#not-an-observed-node";
    await assert.rejects(() => observation(submission.submitId, missing), /exactly one visible node/);
    const overlap = structuredClone(adapter);
    overlap.queryChips.push(structuredClone(overlap.queryChips[0]));
    await assert.rejects(() => observation(submission.submitId, overlap), /overlapping query descriptors/);
    await page.locator("#educationSourceLabel").click();
    assert.equal((await observation(submission.submitId)).raw.scopeSelectionConfirmed, false);
    fs.writeFileSync(outputPath, JSON.stringify(packet, null, 2) + "\n", "utf8");
    process.stdout.write("PASS Search Observation Collector DOM: local simulator; source_mode=offline-dom-test; independent reads, read-only DOM, visibility, order, fail-closed extraction\n");
  } finally {
    await browser.close();
  }
}
main().catch(error => { process.stderr.write(error.stack + "\n"); process.exitCode = 1; });
