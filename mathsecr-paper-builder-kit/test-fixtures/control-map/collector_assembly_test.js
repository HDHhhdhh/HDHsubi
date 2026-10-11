/* Reusable isolated DOM workflow. The committed control map drives every read.
 * No HTTP(S), authenticated profile, service selector, or receipt relabeling. */
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const assert = require("node:assert/strict");
const root = path.resolve(__dirname, "../..");
const collect = require(path.join(root, "scripts/search_observation.js"));
const readJson = name => JSON.parse(fs.readFileSync(path.join(__dirname, name), "utf8"));
const map = readJson("simulator.json");
const template = readJson("mathsecr-current.json");
const original = JSON.parse(fs.readFileSync(path.join(root, "test-fixtures/search-observation/simulator-adapter.json"), "utf8"));
for (const [key, value] of Object.entries(original)) assert.deepEqual(map[key], value);
const [modulePath, browserPath, outputPath] = process.argv.slice(2);
const { chromium } = require(modulePath);
async function main() {
  const browser = await chromium.launch({ executablePath: browserPath, headless: true });
  try {
    const context = await browser.newContext();
    await context.route(/^https?:/, route => route.abort());
    const page = await context.newPage();
    await page.goto(pathToFileURL(path.join(root, "test-fixtures/iab-simulator/index.html")).href);
    await page.locator("#educationSourceLabel").click();
    for (const text of ["본문", "조건"]) {
      await page.locator("#queryInput").fill(text);
      await page.locator("#addChip").click();
    }
    let read = 0;
    const observe = (submitId, adapter = map) => page.evaluate(collect, {
      adapter, context: { attemptId: "attempt-1", submitId, readEvidenceId: "phase2-dom-read-" + (++read) }
    });
    await assert.rejects(() => observe(null, template), /descriptor.selector: nonblank canonical string required/);
    const before = await observe(null);
    assert.deepEqual(before.raw.criteria.chips, [{kind:"text",value:"본문"},{kind:"text",value:"조건"}]);
    await page.locator("#searchButton").click();
    const submission = {
      submitId:"phase2-dom-submit",actionEvidenceId:"phase2-dom-click",action:"검색하기",
      surface:"offline-dom-test",completedAtUtc:new Date().toISOString(),url:page.url(),
      criteria:before.raw.criteria,resultCriteriaKey:null
    };
    const html = await page.content();
    const first = await observe(submission.submitId);
    const second = await observe(submission.submitId);
    assert.equal(await page.content(), html, "collector must remain read-only");
    assert(first.raw.result.orderedIds.includes("7231357"));
    assert.notEqual(first.raw.captureId, second.raw.captureId);
    fs.writeFileSync(outputPath, JSON.stringify({
      schemaVersion:1,attemptId:"attempt-1",submission,beforeSubmit:before,observations:[first,second]
    },null,2)+"\n","utf8");
    process.stdout.write("ControlMapCollector PASS (null template rejected; original descriptors equal; isolated independent reads).\n");
  } finally { await browser.close(); }
}
main().catch(error => { process.stderr.write(error.stack+"\n");process.exitCode=1; });
